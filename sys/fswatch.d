/**
 * ae.sys.fswatch
 *
 * Minimal path-based file system change notification facade.
 *
 * Watches a path (file or directory) and invokes a handler whenever
 * the file system entry at that path, or an entry inside it if it is
 * a directory, may have changed. The handler carries no payload; the
 * caller is expected to re-examine the path.
 *
 * Atomic-rename safe: replacing a file via the standard
 * "write temp + rename onto target" pattern fires the handler, because
 * the implementation watches the parent directory rather than the inode.
 *
 * Tolerates a non-existent path: if the path does not exist when
 * `watch` is called but its parent directory does, the handler fires
 * when the path later appears. If the parent directory does not exist,
 * `watch` throws.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.fswatch;

import std.path : dirName, baseName;
import std.file : exists, isDir;
import std.exception : enforce;

import ae.net.asockets : socketManager;

version (linux)
{
	import ae.sys.inotify;
	import core.sys.linux.sys.inotify :
		IN_MODIFY, IN_ATTRIB, IN_CREATE, IN_DELETE,
		IN_MOVED_FROM, IN_MOVED_TO,
		IN_DELETE_SELF, IN_MOVE_SELF;
}
else version (Windows)
{
	import ae.net.asockets : IocpParticipant, IocpOp, IocpOpKind, isIocpEventLoop;
	static if (isIocpEventLoop)
	{
		import core.sys.windows.windows;
		import ae.sys.windows.text : fromWString;
	}
	else
		static assert(0, "ae.sys.fswatch on Windows requires the IOCP event loop (version=IOCP, the default).");
}
else
	static assert(0, "ae.sys.fswatch is not yet supported on this platform. Add a backend here (kqueue / FSEvents / FEN / polling).");

// ---- Windows IocpParticipant --------------------------------------------
// (Defined before ParentWatch so the field declaration resolves without a forward reference.)

version (Windows) static if (isIocpEventLoop)
{
	private final class DirWatch : IocpParticipant
	{
		private ParentWatch _parent;
		private HANDLE _dirHandle;
		private IocpOp _op;
		private ubyte[4096] _buf;
		private bool _cancelling;

		this(ParentWatch parent, string path)
		{
			import std.utf : toUTF16z;
			_parent = parent;
			_dirHandle = CreateFileW(
				path.toUTF16z(),
				FILE_LIST_DIRECTORY,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
				null,
				OPEN_EXISTING,
				FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED,
				null);
			enforce(_dirHandle != INVALID_HANDLE_VALUE, "CreateFileW failed for directory: " ~ path);

			_op.owner = this;
			_op.kind = IocpOpKind.dirChange;

			auto port = socketManager.getIocpPort();
			auto rc = CreateIoCompletionPort(_dirHandle, port, cast(ULONG_PTR)cast(void*)this, 0);
			assert(rc == port, "CreateIoCompletionPort failed for directory watch");

			socketManager.addParticipant(this);
			if (!_armRead())
			{
				_doTeardown();
				throw new Exception("ReadDirectoryChangesW failed for directory: " ~ path);
			}
		}

		// Initiates cancellation. The ABORTED completion will arrive asynchronously
		// via iocpOnComplete, which closes the handle and removes the participant.
		// The participant stays in the list until then so the loop stays alive.
		void cancel()
		{
			_cancelling = true;
			CancelIoEx(_dirHandle, &_op.overlapped);
		}

		override bool iocpHasNonDaemonWork()
		{
			// Keep the loop alive until the ABORTED completion is processed.
			return _parent !is null;
		}

		override void iocpOnComplete(IocpOp* op, DWORD bytes, uint status)
		{
			if (status == ERROR_OPERATION_ABORTED || _cancelling)
			{
				// Normal teardown after cancel(): close handle, leave registry.
				_doTeardown();
				return;
			}

			if (status != 0)
			{
				// Implicit watch death: directory removed, volume unmounted, etc.
				_handleWatchDeath();
				return;
			}

			if (_parent is null)
				return;

			if (bytes == 0)
			{
				// Kernel buffer overflow: fire all handlers, then re-arm.
				_fireAllHandlers();
				if (!_armRead())
					_handleWatchDeath();
				return;
			}

			// Walk FILE_NOTIFY_INFORMATION records.
			size_t offset = 0;
			while (true)
			{
				auto info = cast(FILE_NOTIFY_INFORMATION*)&_buf[offset];
				auto leafW = info.FileName()[0 .. info.FileNameLength / wchar.sizeof];
				auto leaf = fromWString(leafW);
				_fireLeafHandlers(leaf);

				if (info.NextEntryOffset == 0)
					break;
				offset += info.NextEntryOffset;
			}
			if (!_armRead())
				_handleWatchDeath();
		}

		override void iocpUserPost(DWORD bytes) { assert(false); }

		// Returns true if the read was successfully posted (or cancel is in progress),
		// false if ReadDirectoryChangesW failed synchronously (caller must handle error).
		private bool _armRead()
		{
			if (_cancelling)
			{
				// cancel() was called while a completion was being dispatched,
				// so CancelIoEx had no in-flight op to abort. Tear down now.
				_doTeardown();
				return true;
			}

			enum DWORD filter =
				FILE_NOTIFY_CHANGE_FILE_NAME
				| FILE_NOTIFY_CHANGE_DIR_NAME
				| FILE_NOTIFY_CHANGE_ATTRIBUTES
				| FILE_NOTIFY_CHANGE_SIZE
				| FILE_NOTIFY_CHANGE_LAST_WRITE
				| FILE_NOTIFY_CHANGE_CREATION
				| FILE_NOTIFY_CHANGE_SECURITY;

			_op.overlapped = OVERLAPPED.init;
			DWORD got = 0;
			BOOL ok = ReadDirectoryChangesW(
				_dirHandle, _buf.ptr, cast(DWORD)_buf.length,
				FALSE, filter, &got, &_op.overlapped, null);

			return ok || GetLastError() == ERROR_IO_PENDING;
		}

		private void _doTeardown()
		{
			if (_dirHandle) { CloseHandle(_dirHandle); _dirHandle = null; }
			_parent = null;
			socketManager.removeParticipant(this);
		}

		private void _fireAllHandlers()
		{
			if (_parent is null) return;
			foreach (ids; _parent.idsByLeaf.values)
				foreach (id; ids.dup)
					if (auto pe = id in fsWatcher.entries)
						pe.handler();
		}

		private void _fireLeafHandlers(string leaf)
		{
			if (_parent is null) return;
			foreach (id; _parent.idsByLeaf.get(leaf, []).dup)
				if (auto pe = id in fsWatcher.entries)
					pe.handler();
			foreach (id; _parent.idsByLeaf.get("", []).dup)
				if (auto pe = id in fsWatcher.entries)
					pe.handler();
		}

		private void _handleWatchDeath()
		{
			auto parent = _parent;
			if (parent is null) return;

			// Collect handlers before removing entries.
			void delegate()[] allHandlers;
			foreach (ids; parent.idsByLeaf)
				foreach (id; ids)
					if (auto pe = id in fsWatcher.entries)
						allHandlers ~= pe.handler;

			// Remove from registry.
			foreach (ids; parent.idsByLeaf)
				foreach (id; ids)
					fsWatcher.entries.remove(id);
			parent.idsByLeaf = null;
			fsWatcher.parents.remove(parent.parentPath);
			_parent = null;

			if (_dirHandle)
			{
				CloseHandle(_dirHandle);
				_dirHandle = null;
			}
			socketManager.removeParticipant(this);

			foreach (h; allHandlers)
				h();
		}
	}
}

// ---- Internal data model ------------------------------------------------

private final class ParentWatch
{
	string parentPath;

	// Maps leaf name to registered descriptor IDs.
	// Empty-string key = directory-mode (match any event on this watch).
	size_t[][string] idsByLeaf;

	version (linux)
		INotify.WatchDescriptor inotifyWd;
	else version (Windows)
	{
		static if (isIocpEventLoop)
			DirWatch dirWatch;
	}
}

private struct WatchEntry
{
	ParentWatch parent;
	string leaf;
	void delegate() handler;
}

// ---- Public API ---------------------------------------------------------

/// Watches file system paths and fires `void delegate()` handlers on change.
struct FsWatcher
{
	/// Opaque watch handle returned by `watch`. Treat as opaque.
	static struct WatchDescriptor { private size_t id; }

	/// Begin watching `path`. The handler fires whenever the file system
	/// entry at `path` — or any entry inside it if `path` is a directory —
	/// may have changed. The handler is responsible for re-examining the path.
	///
	/// Atomic-rename safe: replacing the file at `path` via the standard
	/// "write temp + rename onto target" pattern fires the handler, because
	/// the implementation watches the parent directory.
	///
	/// Tolerates a non-existent `path`: if `path` does not exist when this
	/// is called but its parent directory does, the handler fires when `path`
	/// later appears. If the parent directory does not exist, this throws.
	///
	/// The handler may call `unwatch(wd)` re-entrantly.
	WatchDescriptor watch(string path, void delegate() handler)
	{
		assert(handler !is null);

		// Determine parent directory and leaf name.
		string parentPath, leaf;
		bool pathIsDir;
		try
			pathIsDir = path.exists && path.isDir;
		catch (Exception)
			pathIsDir = false;

		if (pathIsDir)
		{
			parentPath = path;
			leaf = "";  // directory-mode: match any event
		}
		else
		{
			parentPath = dirName(path);
			leaf = baseName(path);
			enforce(parentPath.exists && parentPath.isDir,
				"Parent directory does not exist: " ~ parentPath);
		}

		// Get or create the ParentWatch for this directory.
		auto pparent = parentPath in parents;
		ParentWatch parent;
		if (pparent)
			parent = *pparent;
		else
		{
			parent = new ParentWatch;
			parent.parentPath = parentPath;
			_installOsWatch(parent, parentPath);
			parents[parentPath] = parent;
		}

		// Allocate a new descriptor.
		auto id = nextId++;
		entries[id] = WatchEntry(parent, leaf, handler);
		parent.idsByLeaf[leaf] ~= id;
		return WatchDescriptor(id);
	}

	/// Stop watching. Idempotent: calling `unwatch` on a descriptor that has
	/// already been removed (e.g. because the watched directory was deleted and
	/// the watch-death teardown already cleared it before firing the handler)
	/// is a no-op. The handler may call `unwatch(wd)` re-entrantly.
	void unwatch(WatchDescriptor wd)
	{
		auto pe = wd.id in entries;
		if (pe is null) return;  // already removed (watch-death path, double-unwatch)

		auto parent = pe.parent;
		auto leaf   = pe.leaf;

		// Remove id from idsByLeaf.
		import std.algorithm : remove, SwapStrategy;
		auto ids = leaf in parent.idsByLeaf;
		assert(ids !is null);
		*ids = (*ids).remove!(x => x == wd.id, SwapStrategy.unstable);
		if (ids.length == 0)
			parent.idsByLeaf.remove(leaf);

		entries.remove(wd.id);

		// If this was the last watcher on the parent, tear down the OS watch.
		if (parent.idsByLeaf.length == 0)
		{
			_teardownOsWatch(parent);
			parents.remove(parent.parentPath);
		}
	}

private:
	WatchEntry[size_t] entries;   // descriptor id -> entry
	ParentWatch[string] parents;  // parentPath -> shared watch
	size_t nextId = 1;            // 0 is reserved (invalid)

	// ---- Linux backend --------------------------------------------------

	version (linux)
	void _installOsWatch(ParentWatch parent, string parentPath)
	{
		auto mask = cast(INotify.Mask)(
			IN_MODIFY | IN_ATTRIB | IN_CREATE | IN_DELETE
			| IN_MOVED_FROM | IN_MOVED_TO
			| IN_DELETE_SELF | IN_MOVE_SELF);

		parent.inotifyWd = iNotify.add(parentPath, mask,
			(in char[] name, INotify.Mask evMask, uint cookie)
			{
				_inotifyCallback(parent, name, evMask);
			});
	}

	version (linux)
	void _teardownOsWatch(ParentWatch parent)
	{
		iNotify.remove(parent.inotifyWd);
	}

	version (linux)
	void _inotifyCallback(ParentWatch parent, in char[] name, INotify.Mask mask)
	{
		// Self-event: the watched directory itself is going away.
		if (mask & (INotify.Mask.removeSelf | INotify.Mask.moveSelf
		            | INotify.Mask.unmount   | INotify.Mask.ignored))
		{
			// Guard against double-entry (e.g. IN_DELETE_SELF then IN_IGNORED).
			if (!(parent.parentPath in parents))
				return;

			// Collect handlers before mutating the registry.
			void delegate()[] allHandlers;
			foreach (ids; parent.idsByLeaf)
				foreach (id; ids)
					if (auto pe = id in entries)
						allHandlers ~= pe.handler;

			// Tear down registry entries.
			foreach (ids; parent.idsByLeaf)
				foreach (id; ids)
					entries.remove(id);
			parent.idsByLeaf = null;
			parents.remove(parent.parentPath);

			// Remove from inotify (tolerates EINVAL if kernel already dropped it).
			iNotify.remove(parent.inotifyWd);

			foreach (h; allHandlers)
				h();
			return;
		}

		// Overflow: fire all handlers for this parent.
		if (mask & INotify.Mask.qOverflow)
		{
			foreach (ids; parent.idsByLeaf.values)
				foreach (id; ids.dup)
					if (auto pe = id in entries)
						pe.handler();
			return;
		}

		// Normal event: fire handlers for the specific leaf and directory-mode.
		auto leafStr = name.idup;
		foreach (id; parent.idsByLeaf.get(leafStr, []).dup)
			if (auto pe = id in entries)
				pe.handler();
		foreach (id; parent.idsByLeaf.get("", []).dup)
			if (auto pe = id in entries)
				pe.handler();
	}

	// ---- Windows backend ------------------------------------------------

	version (Windows) static if (isIocpEventLoop)
	{
		void _installOsWatch(ParentWatch parent, string parentPath)
		{
			parent.dirWatch = new DirWatch(parent, parentPath);
		}

		void _teardownOsWatch(ParentWatch parent)
		{
			parent.dirWatch.cancel();
		}
	}
}

/// The global facade. Mirrors `iNotify` in `ae.sys.inotify`.
FsWatcher fsWatcher;

// ---- Tests --------------------------------------------------------------

debug(ae_unittest) unittest
{
	// 1. In-place modification fires the handler.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	write("tmp/target.txt", "initial");

	int fired;
	FsWatcher.WatchDescriptor wd;
	wd = fsWatcher.watch("tmp/target.txt", () {
		fired++;
		fsWatcher.unwatch(wd);
	});

	write("tmp/target.txt", "modified");
	socketManager.loop();
	assert(fired >= 1, "handler should have fired at least once");
}

debug(ae_unittest) unittest
{
	// 2. Atomic-rename replacement fires the handler (load-bearing test).
	// An inode-based implementation would miss this.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	write("tmp/target.txt", "initial");

	int fired;
	FsWatcher.WatchDescriptor wd;
	wd = fsWatcher.watch("tmp/target.txt", () {
		fired++;
		fsWatcher.unwatch(wd);
	});

	write("tmp/target.txt.tmp", "replaced");
	std.file.rename("tmp/target.txt.tmp", "tmp/target.txt");
	socketManager.loop();
	assert(fired >= 1, "handler should fire on atomic rename");
}

debug(ae_unittest) unittest
{
	// 3. Watching a non-existent path tolerates absence; fires when path appears.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	int fired;
	FsWatcher.WatchDescriptor wd;
	wd = fsWatcher.watch("tmp/newfile.txt", () {
		fired++;
		fsWatcher.unwatch(wd);
	});

	touch("tmp/newfile.txt");
	socketManager.loop();
	assert(fired >= 1, "handler should fire when watched path appears");
}

debug(ae_unittest) unittest
{
	// 4. Watching a path whose parent does not exist throws.
	import std.exception : assertThrown;
	assertThrown!Exception(
		fsWatcher.watch("/no/such/parent/directory/leaf.txt", () {}));
}

debug(ae_unittest) unittest
{
	// 5. Watching a directory fires when entries inside change.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	int fired;
	FsWatcher.WatchDescriptor wd;
	wd = fsWatcher.watch("tmp", () {
		fired++;
		fsWatcher.unwatch(wd);
	});

	touch("tmp/x");
	socketManager.loop();
	assert(fired >= 1, "directory-mode handler should fire on new entry");
}

debug(ae_unittest) unittest
{
	// 6. Coalesced parent watches: two watches in the same directory share one
	//    OS watch; selective dispatch; unwatch of one leaves the other functional.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	touch("tmp/a");
	touch("tmp/b");

	int firedA;
	FsWatcher.WatchDescriptor wdA, wdB;

	wdA = fsWatcher.watch("tmp/a", () { firedA++; });
	wdB = fsWatcher.watch("tmp/b", () {});

	// Two file watches on the same directory share one OS watch.
	assert(fsWatcher.parents.length == 1, "should coalesce into one parent watch");

	// Phase A: verify wdA fires when tmp/a changes.
	// The exit trigger removes ALL watches so the loop can exit.
	FsWatcher.WatchDescriptor exitWd;
	exitWd = fsWatcher.watch("tmp/a", () {
		// wdA's handler fires before exitWd's because wdA was registered first.
		fsWatcher.unwatch(exitWd);
		fsWatcher.unwatch(wdA);
		fsWatcher.unwatch(wdB);  // unwatch all so the loop can exit
	});
	write("tmp/a", "changed");
	socketManager.loop();
	assert(firedA >= 1, "h1 should have fired for tmp/a");
	assert(fsWatcher.parents.length == 0, "all watches torn down");

	// Phase B: structural verification — unwatch of one leaf leaves parent alive.
	wdA = fsWatcher.watch("tmp/a", () {});
	wdB = fsWatcher.watch("tmp/b", () {});
	assert(fsWatcher.parents.length == 1, "re-registered; should coalesce again");

	fsWatcher.unwatch(wdA);
	assert(fsWatcher.parents.length == 1, "parent should survive after unwatching one child");

	fsWatcher.unwatch(wdB);
	assert(fsWatcher.parents.length == 0, "parent should be torn down after both unwatched");
}

debug(ae_unittest) unittest
{
	// 7. unwatch is callable re-entrantly from inside the handler.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	int fired;
	FsWatcher.WatchDescriptor wd;
	wd = fsWatcher.watch("tmp/f", () {
		fired++;
		fsWatcher.unwatch(wd);  // re-entrant unwatch
	});

	touch("tmp/f");
	socketManager.loop();
	assert(fired == 1, "handler should fire exactly once after re-entrant unwatch");
}

debug(ae_unittest) unittest
{
	// 8. Loop exits promptly when there are no live watches.
	import std.file, ae.sys.file;
	if ("tmp".exists) "tmp".removeRecurse();
	mkdir("tmp");
	scope(exit) "tmp".removeRecurse();

	auto wd = fsWatcher.watch("tmp/gone", () {});
	fsWatcher.unwatch(wd);
	// With no live watches, loop() must return without hanging.
	socketManager.loop();
	// If we get here, the test passed.
}
