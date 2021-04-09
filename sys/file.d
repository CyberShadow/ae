/**
 * File stuff
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

module ae.sys.file;

import core.stdc.wchar_;
import core.thread;

import std.array;
import std.conv;
import std.file;
import std.path;
import std.range.primitives;
import std.stdio : File;
import std.string;
import std.typecons;
import std.utf;

import ae.sys.cmd : getCurrentThreadID;
import ae.utils.path;

public import std.typecons : No, Yes;

deprecated alias wcscmp = core.stdc.wchar_.wcscmp;
deprecated alias wcslen = core.stdc.wchar_.wcslen;

version(Windows) import ae.sys.windows.imports;

// ************************************************************************

version (Windows)
{
	// Work around std.file overload
	mixin(importWin32!(q{winnt}, null, q{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT}));
}
version (Posix)
{
	private import core.stdc.errno;
	private import core.sys.posix.dirent;
	private import core.stdc.string;
}

// ************************************************************************

deprecated string[] fastListDir(bool recursive = false, bool symlinks=false)(string pathname, string pattern = null)
{
	string[] result;

	listDir!((e) {
		static if (!symlinks)
		{
			// Note: shouldn't this just skip recursion?
			if (e.isSymlink)
				return;
		}

		if (pattern && !globMatch(e.baseName, pattern))
			return;

		static if (recursive)
		{
			if (e.entryIsDir)
			{
				// Note: why exclude directories from results?
				e.recurse();
				return;
			}
		}

		result ~= e.fullName;
	})(pathname);
	return result;
}

// ************************************************************************

version (Windows)
{
	mixin(importWin32!(q{winnt}, null, q{WCHAR}));
	mixin(importWin32!(q{winbase}, null, q{WIN32_FIND_DATAW}));
}

/// The OS's "native" filesystem character type (private in Phobos).
version (Windows)
	alias FSChar = WCHAR;
else version (Posix)
	alias FSChar = char;
else
	static assert(0);

/// Reads a time field from a stat_t with full precision (private in Phobos).
SysTime statTimeToStdTime(string which)(ref const stat_t statbuf)
{
	auto unixTime = mixin(`statbuf.st_` ~ which ~ `time`);
	auto stdTime = unixTimeToStdTime(unixTime);

	static if (is(typeof(mixin(`statbuf.st_` ~ which ~ `tim`))))
		stdTime += mixin(`statbuf.st_` ~ which ~ `tim.tv_nsec`) / 100;
	else
	static if (is(typeof(mixin(`statbuf.st_` ~ which ~ `timensec`))))
		stdTime += mixin(`statbuf.st_` ~ which ~ `timensec`) / 100;
	else
	static if (is(typeof(mixin(`statbuf.st_` ~ which ~ `time_nsec`))))
		stdTime += mixin(`statbuf.st_` ~ which ~ `time_nsec`) / 100;
	else
	static if (is(typeof(mixin(`statbuf.__st_` ~ which ~ `timensec`))))
		stdTime += mixin(`statbuf.__st_` ~ which ~ `timensec`) / 100;

	return SysTime(stdTime);
}

version (OSX)
    version = Darwin;
else version (iOS)
    version = Darwin;
else version (TVOS)
    version = Darwin;
else version (WatchOS)
    version = Darwin;

private
version (Posix)
{
	// TODO: upstream into Druntime
	extern (C)
	{
		int dirfd(DIR *dirp) pure nothrow @nogc;
		int openat(int fd, const char *path, int oflag, ...) nothrow @nogc;

		version (Darwin)
		{
			pragma(mangle, "fstatat$INODE64")
			int fstatat(int fd, const char *path, stat_t *buf, int flag) nothrow @nogc;

			pragma(mangle, "fdopendir$INODE64")
			DIR *fdopendir(int fd) nothrow @nogc;
		}
		else
		{
			int fstatat(int fd, const(char)* path, stat_t* buf, int flag) nothrow @nogc;
			DIR *fdopendir(int fd) nothrow @nogc;
		}
	}
	version (linux)
	{
		enum AT_SYMLINK_NOFOLLOW = 0x100;
		enum O_DIRECTORY = 0x10000;
	}
	version (Darwin)
	{
		enum AT_SYMLINK_NOFOLLOW = 0x20;
		enum O_DIRECTORY = 0x100000;
	}
	version (FreeBSD)
	{
		enum AT_SYMLINK_NOFOLLOW = 0x200;
		enum O_DIRECTORY = 0x20000;
	}
}

import ae.utils.range : nullTerminated;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version (Windows) static import ae.sys.windows.misc;

/**
   Fast templated directory iterator

   Example:
   ---
   string[] entries;
   listDir!((e) {
	   entries ~= e.fullName.relPath(tmpDir);
	   if (e.entryIsDir)
		   e.recurse();
   })(tmpDir);
   ---
*/
template listDir(alias handler)
{
private: // (This is an eponymous template, so this is to aid documentation generators.)
	/*non-static*/ struct Context
	{
		// Tether to handler alias context
		void callHandler(Entry* e) { handler(e); }

		bool timeToStop = false;

		FSChar[] pathBuf;
	}

	/// A pointer to this type will be passed to the `listDir` predicate.
	public static struct Entry
	{
		version (Posix)
		{
			dirent* ent; /// POSIX `dirent`.

			private stat_t[enumLength!StatTarget] statBuf;

			/// Result of `stat` call.
			/// Other values are the same as `errno`.
			enum StatResult : int
			{
				noInfo       =       0, /// Not called yet.
				statOK       = int.max, /// All OK
				unknownError = int.min, /// `errno` returned 0 or `int.max`
			}

			int dirFD; /// POSIX directory file descriptor.
		}
		version (Windows)
		{
			WIN32_FIND_DATAW findData; /// Windows `WIN32_FIND_DATAW`.
		}

		// Cached values.
		// Cleared (memset to 0) for every directory entry.
		struct Data
		{
			FSChar[] baseNameFS;
			string baseName;
			string fullName;
			size_t pathTailPos;

			version (Posix)
			{
				StatResult[enumLength!StatTarget] statResult;
			}
		}
		Data data;

		// Recursion

		Entry* parent; ///
		private Context* context;

		/// Request recursion on the current `entry`.
		version (Posix)
		{
			void recurse()
			{
				import core.sys.posix.fcntl;
				int flags = O_RDONLY;
				static if (is(typeof(O_DIRECTORY)))
					flags |= O_DIRECTORY;
				auto fd = openat(dirFD, this.ent.d_name.ptr, flags);
				errnoEnforce(fd >= 0,
					"Failed to open %s as subdirectory of directory %s"
					.format(this.baseNameFS, this.parent.fullName));
				auto subdir = fdopendir(fd);
				errnoEnforce(subdir,
					"Failed to open subdirectory %s of directory %s as directory"
					.format(this.baseNameFS, this.parent.fullName));
				scan(subdir, fd, &this);
			}
		}
		else
		version (Windows)
		{
			void recurse()
			{
				needFullPath();
				appendString(context.pathBuf,
					data.pathTailPos, "\\*.*\0"w);
				scan(&this);
			}
		}

		/// Stop iteration.
		void stop() { context.timeToStop = true; }

		// Name

		/// Returns a pointer to the base file name, as a
		/// null-terminated string, in the operating system's
		/// character type.  Fastest.
		const(FSChar)* baseNameFSPtr() pure nothrow @nogc
		{
			version (Posix) return ent.d_name.ptr;
			version (Windows) return findData.cFileName.ptr;
		}

		// Bounded variant of std.string.fromStringz for static arrays.
		private static T[] fromStringz(T, size_t n)(ref T[n] buf)
		{
			foreach (i, c; buf)
				if (!c)
					return buf[0 .. i];
			// This should only happen in case of an OS / libc bug.
			assert(false, "File name buffer is not null-terminated");
		}

		/// Returns the base file name, as a D character array, in the
		/// operating system's character type.  Fast.
		const(FSChar)[] baseNameFS() pure nothrow @nogc
		{
			if (!data.baseNameFS)
			{
				version (Posix) data.baseNameFS = fromStringz(ent.d_name);
				version (Windows) data.baseNameFS = fromStringz(findData.cFileName);
			}
			return data.baseNameFS;
		}

		/// Returns the base file name as a D string.  Allocates.
		string baseName() // allocates
		{
			if (!data.baseName)
				data.baseName = baseNameFS.to!string;
			return data.baseName;
		}

		private void needFullPath() nothrow @nogc
		{
			if (!data.pathTailPos)
			{
				version (Posix)
					parent.needFullPath();
				version (Windows)
				{
					// directory separator was added during recursion
					auto startPos = parent.data.pathTailPos + 1;
				}
				version (Posix)
				{
					immutable FSChar[] separator = "/";
					auto startPos = appendString(context.pathBuf,
						parent.data.pathTailPos, separator);
				}
				data.pathTailPos = appendString(context.pathBuf,
					startPos,
					baseNameFSPtr.nullTerminated
				);
			}
		}

		/// Returns the full file name, as a D character array, in the
		/// operating system's character type.  Fast.
		const(FSChar)[] fullNameFS() nothrow @nogc // fast
		{
			needFullPath();
			return context.pathBuf[0 .. data.pathTailPos];
		}

		/// Returns the full file name as a D string.  Allocates.
		string fullName() // allocates
		{
			if (!data.fullName)
				data.fullName = fullNameFS.to!string;
			return data.fullName;
		}

		// Attributes

		version (Posix)
		{
			/// We can stat two different things on POSIX: the directory entry itself,
			/// or the link target (if the directory entry is a symbolic link).
			enum StatTarget
			{
				dirEntry,   /// do not dereference (lstat)
				linkTarget, /// dereference
			}

			private bool tryStat(StatTarget target)() nothrow @nogc
			{
				if (data.statResult[target] == StatResult.noInfo)
				{
					// If we already did the other kind of stat, can we reuse its result?
					if (data.statResult[1 - target] != StatResult.noInfo)
					{
						// Yes, if we know this isn't a link from the directory entry.
						static if (__traits(compiles, ent.d_type))
							if (ent.d_type != DT_UNKNOWN && ent.d_type != DT_LNK)
								goto reuse;
						// Yes, if we already found out this isn't a link from an lstat call.
						static if (target == StatTarget.linkTarget)
							if (data.statResult[StatTarget.dirEntry] == StatResult.statOK
								&& (statBuf[StatTarget.dirEntry].st_mode & S_IFMT) != S_IFLNK)
								goto reuse;
					}

					if (false)
					{
					reuse:
						statBuf[target] = statBuf[1 - target];
						data.statResult[target] = data.statResult[1 - target];
					}
					else
					{
						int flags = target == StatTarget.dirEntry ? AT_SYMLINK_NOFOLLOW : 0;
						auto res = fstatat(dirFD, ent.d_name.ptr, &statBuf[target], flags);
						if (res)
						{
							auto error = errno;
							data.statResult[target] = cast(StatResult)error;
							if (error == StatResult.noInfo || error == StatResult.statOK)
								data.statResult[target] = StatResult.unknownError; // unknown error?
						}
						else
							data.statResult[target] = StatResult.statOK; // no error
					}
				}
				return data.statResult[target] == StatResult.statOK;
			}

			private ErrnoException statError(StatTarget target)()
			{
				errno = data.statResult[target];
				return new ErrnoException("Failed to stat " ~
					(target == StatTarget.linkTarget ? "link target" : "directory entry") ~
					": " ~ fullName);
			}

			/// Return the result of `stat` / `lstat` (depending on `target`)
			/// for this `Entry`, performing it first if necessary.
			stat_t* needStat(StatTarget target)()
			{
				if (!tryStat!target)
					throw statError!target();
				return &statBuf[target];
			}

			// Check if this is an object of the given type.
			private bool deIsType(typeof(DT_REG) dType, typeof(S_IFREG) statType)
			{
				static if (__traits(compiles, ent.d_type))
					if (ent.d_type != DT_UNKNOWN)
						return ent.d_type == dType;

				return (needStat!(StatTarget.dirEntry)().st_mode & S_IFMT) == statType;
			}

			/// Returns true if this is a symlink.
			@property bool isSymlink()
			{
				return deIsType(DT_LNK, S_IFLNK);
			}

			/// Returns true if this is a directory.
			/// You probably want to use this one to decide whether to recurse.
			@property bool entryIsDir()
			{
				return deIsType(DT_DIR, S_IFDIR);
			}

			// Check if this is an object of the given type, or a link pointing to one.
			private bool ltIsType(typeof(DT_REG) dType, typeof(S_IFREG) statType)
			{
				static if (__traits(compiles, ent.d_type))
					if (ent.d_type != DT_UNKNOWN && ent.d_type != DT_LNK)
						return ent.d_type == dType;

				if (tryStat!(StatTarget.linkTarget)())
					return (statBuf[StatTarget.linkTarget].st_mode & S_IFMT) == statType;

				if (isSymlink()) // broken symlink?
					return false; // a broken symlink does not point at anything.

				throw statError!(StatTarget.linkTarget)();
			}

			/// Returns true if this is a file, or a link pointing to one.
			@property bool isFile()
			{
				return ltIsType(DT_REG, S_IFREG);
			}

			/// Returns true if this is a directory, or a link pointing to one.
			@property bool isDir()
			{
				return ltIsType(DT_DIR, S_IFDIR);
			}

			/// Returns the raw POSIX attributes of this directory entry.
			@property uint attributes()
			{
				return needStat!(StatTarget.linkTarget)().st_mode;
			}

			/// Returns the raw POSIX attributes of this directory entry,
			/// or the link target if this directory entry is a symlink.
			@property uint linkAttributes()
			{
				return needStat!(StatTarget.dirEntry)().st_mode;
			}

			// Other attributes

			/// Returns the "c" time of this directory entry,
			/// or the link target if this directory entry is a symlink.
			@property SysTime timeStatusChanged()
			{
				return statTimeToStdTime!"c"(*needStat!(StatTarget.linkTarget)());
			}

			/// Returns the "a" time of this directory entry,
			/// or the link target if this directory entry is a symlink.
			@property SysTime timeLastAccessed()
			{
				return statTimeToStdTime!"a"(*needStat!(StatTarget.linkTarget)());
			}

			/// Returns the "m" time of this directory entry,
			/// or the link target if this directory entry is a symlink.
			@property SysTime timeLastModified()
			{
				return statTimeToStdTime!"m"(*needStat!(StatTarget.linkTarget)());
			}

			/// Returns the "birth" time of this directory entry,
			/// or the link target if this directory entry is a symlink.
			static if (is(typeof(&statTimeToStdTime!"birth")))
			@property SysTime timeCreated()
			{
				return statTimeToStdTime!"birth"(*needStat!(StatTarget.linkTarget)());
			}

			/// Returns the size in bytes of this directory entry,
			/// or the link target if this directory entry is a symlink.
			@property ulong size()
			{
				return needStat!(StatTarget.linkTarget)().st_size;
			}

			/// Returns the inode number of this directory entry,
			/// or the link target if this directory entry is a symlink.
			@property ulong fileID()
			{
				static if (__traits(compiles, ent.d_ino))
					return ent.d_ino;
				else
					return needStat!(StatTarget.linkTarget)().st_ino;
			}
		}

		version (Windows)
		{
			/// Returns true if this is a directory, or a reparse point pointing to one.
			@property bool isDir() const pure nothrow
			{
				return (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
			}

			/// Returns true if this is a file, or a reparse point pointing to one.
			@property bool isFile() const pure nothrow
			{
				return !isDir;
			}

			/// Returns true if this is a reparse point.
			@property bool isSymlink() const pure nothrow
			{
				return (findData.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
			}

			/// Returns true if this is a directory.
			/// You probably want to use this one to decide whether to recurse.
			@property bool entryIsDir() const pure nothrow
			{
				return isDir && !isSymlink;
			}

			/// Returns the raw Windows attributes of this directory entry.
			@property uint attributes() const pure nothrow
			{
				return findData.dwFileAttributes;
			}

			/// Returns the size in bytes of this directory entry.
			@property ulong size() const pure nothrow
			{
				return makeUlong(findData.nFileSizeLow, findData.nFileSizeHigh);
			}

			/// Returns the creation time of this directory entry.
			@property SysTime timeCreated() const
			{
				return FILETIMEToSysTime(&findData.ftCreationTime);
			}

			/// Returns the last access time of this directory entry.
			@property SysTime timeLastAccessed() const
			{
				return FILETIMEToSysTime(&findData.ftLastAccessTime);
			}

			/// Returns the last modification time of this directory entry.
			@property SysTime timeLastModified() const
			{
				return FILETIMEToSysTime(&findData.ftLastWriteTime);
			}

			/// Returns the 64-bit unique file index of this file.
			@property ulong fileID()
			{
				return getFileID(fullName);
			}
		}
	}

	version (Posix)
	{
		// The length of the buffer on the stack.
		enum initialPathBufLength = 256;

		private static void scan(DIR* dir, int dirFD, Entry* parentEntry)
		{
			Entry entry = void;
			entry.parent = parentEntry;
			entry.context = entry.parent.context;
			entry.dirFD = dirFD;

			scope(exit) closedir(dir);

			dirent* ent;
			while ((ent = readdir(dir)) != null)
			{
				// Apparently happens on some OS X versions.
				enforce(ent.d_name[0],
					"Empty dir entry name (OS bug?)");

				// Skip "." and ".."
				if (ent.d_name[0] == '.' && (
						ent.d_name[1] == 0 ||
						(ent.d_name[1] == '.' && ent.d_name[2] == 0)))
					continue;

				entry.ent = ent;
				entry.data = Entry.Data.init;
				entry.context.callHandler(&entry);
				if (entry.context.timeToStop)
					break;
			}
		}
	}

	enum isPath(Path) = (isForwardRange!Path || isSomeString!Path) &&
		isSomeChar!(ElementEncodingType!Path);

	import core.stdc.stdlib : malloc, realloc, free;

	static FSChar[] reallocPathBuf(FSChar[] buf, size_t newLength) nothrow @nogc
	{
		if (buf.length == initialPathBufLength) // current buffer is on stack
		{
			auto ptr = cast(FSChar*) malloc(newLength * FSChar.sizeof);
			ptr[0 .. buf.length] = buf[];
			return ptr[0 .. newLength];
		}
		else // current buffer on C heap (malloc'd above)
		{
			auto ptr = cast(FSChar*) realloc(buf.ptr, newLength * FSChar.sizeof);
			return ptr[0 .. newLength];
		}
	}

	// Append a string to the buffer, reallocating as necessary.
	// Returns the new length of the string in the buffer.
	static size_t appendString(Str)(ref FSChar[] buf, size_t pos, Str str) nothrow @nogc
	if (isPath!Str)
	{
		static if (ElementEncodingType!Str.sizeof == FSChar.sizeof
			&& is(typeof(str.length)))
		{
			// No transcoding needed and length known
			auto remainingSpace = buf.length - pos;
			if (str.length > remainingSpace)
				buf = reallocPathBuf(buf, (pos + str.length) * 3 / 2);
			buf[pos .. pos + str.length] = str[];
			pos += str.length;
		}
		else
		{
			// Need to transcode
			auto p = buf.ptr + pos;
			auto bufEnd = buf.ptr + buf.length;
			foreach (c; byUTF!FSChar(str))
			{
				if (p == bufEnd) // out of room
				{
					auto newBuf = reallocPathBuf(buf, buf.length * 3 / 2);

					// Update pointers to point into the new buffer.
					p = newBuf.ptr + (p - buf.ptr);
					buf = newBuf;
					bufEnd = buf.ptr + buf.length;
				}
				*p++ = c;
			}
			pos = p - buf.ptr;
		}
		return pos;
	}

	version (Windows)
	{
		mixin(importWin32!(q{winbase}));
		import ae.sys.windows.misc : makeUlong;

		// The length of the buffer on the stack.
		enum initialPathBufLength = MAX_PATH;

		enum FIND_FIRST_EX_LARGE_FETCH = 2;
		enum FindExInfoBasic = cast(FINDEX_INFO_LEVELS)1;

		static void scan(Entry* parentEntry)
		{
			Entry entry = void;
			entry.parent = parentEntry;
			entry.context = parentEntry.context;

			HANDLE hFind = FindFirstFileExW(
				entry.context.pathBuf.ptr,
				FindExInfoBasic,
				&entry.findData,
				FINDEX_SEARCH_OPS.FindExSearchNameMatch,
				null,
				FIND_FIRST_EX_LARGE_FETCH, // https://blogs.msdn.microsoft.com/oldnewthing/20131024-00/?p=2843
			);
			if (hFind == INVALID_HANDLE_VALUE)
				throw new WindowsException(GetLastError(),
					text("FindFirstFileW: ", parentEntry.fullNameFS));
			scope(exit) FindClose(hFind);
			do
			{
				// Skip "." and ".."
				auto fn = entry.findData.cFileName.ptr;
				if (fn[0] == '.' && (
						fn[1] == 0 ||
						(fn[1] == '.' && fn[2] == 0)))
					continue;

				entry.data = Entry.Data.init;
				entry.context.callHandler(&entry);
				if (entry.context.timeToStop)
					break;
			}
			while (FindNextFileW(hFind, &entry.findData));
			if (GetLastError() != ERROR_NO_MORE_FILES)
				throw new WindowsException(GetLastError(),
					text("FindNextFileW: ", parentEntry.fullNameFS));
		}
	}

	public void listDir(Path)(Path dirPath)
	if (isPath!Path)
	{
		import std.internal.cstring;

		if (dirPath.empty)
			return listDir(".");

		Context context;

		FSChar[initialPathBufLength] pathBufStore = void;
		context.pathBuf = pathBufStore[];

		scope (exit)
		{
			if (context.pathBuf.length != initialPathBufLength)
				free(context.pathBuf.ptr);
		}

		Entry rootEntry = void;
		rootEntry.context = &context;

		auto endPos = appendString(context.pathBuf, 0, dirPath);
		rootEntry.data.pathTailPos = endPos - (endPos > 0 && context.pathBuf[endPos - 1].isDirSeparator() ? 1 : 0);
		assert(rootEntry.data.pathTailPos > 0);

		version (Posix)
		{
			auto dir = opendir(tempCString(dirPath));
			checkDir(dir, dirPath);

			scan(dir, dirfd(dir), &rootEntry);
		}
		else
		version (Windows)
		{
			const WCHAR[] tailString = endPos == 0 || context.pathBuf[endPos - 1].isDirSeparator() ? "*.*\0"w : "\\*.*\0"w;
			appendString(context.pathBuf, endPos, tailString);

			scan(&rootEntry);
		}
	}

	// Workaround for https://github.com/ldc-developers/ldc/issues/2960
	version (Posix)
	private void checkDir(Path)(DIR* dir, auto ref Path dirPath)
	{
		errnoEnforce(dir, "Failed to open directory " ~ dirPath);
	}
}

unittest
{
	auto tmpDir = deleteme ~ "-dir";
	if (tmpDir.exists) tmpDir.removeRecurse();
	mkdirRecurse(tmpDir);
	scope(exit) rmdirRecurse(tmpDir);

	touch(tmpDir ~ "/a");
	touch(tmpDir ~ "/b");
	mkdir(tmpDir ~ "/c");
	touch(tmpDir ~ "/c/1");
	touch(tmpDir ~ "/c/2");

	string[] entries;
	listDir!((e) {
		assert(equal(e.fullNameFS, e.fullName));
		entries ~= e.fullName.relPath(tmpDir);
		if (e.entryIsDir)
			e.recurse();
	})(tmpDir);

	assert(equal(
		entries.sort,
		["a", "b", "c", "c/1", "c/2"].map!(name => name.replace("/", dirSeparator)),
	), text(entries));

	entries = null;
	import std.ascii : isDigit;
	listDir!((e) {
		entries ~= e.fullName.relPath(tmpDir);
		if (e.baseNameFS[0].isDigit)
			e.stop();
		else
		if (e.entryIsDir)
			e.recurse();
	})(tmpDir);

	assert(entries.length < 5 && entries[$-1][$-1].isDigit, text(entries));

	// Symlink test
	(){
		// Wine's implementation of symlinks/junctions is incomplete
		version (Windows)
			if (getWineVersion())
				return;

		dirLink("c", tmpDir ~ "/d");
		dirLink("x", tmpDir ~ "/e");

		string[] entries;
		listDir!((e) {
			entries ~= e.fullName.relPath(tmpDir);
			if (e.entryIsDir)
				e.recurse();
		})(tmpDir);

		assert(equal(
			entries.sort,
			["a", "b", "c", "c/1", "c/2", "d", "e"].map!(name => name.replace("/", dirSeparator)),
		));

		// Recurse into symlinks

		entries = null;
		listDir!((e) {
			entries ~= e.fullName.relPath(tmpDir);
			if (e.isDir)
				try
					e.recurse();
				catch (Exception e) // broken junctions on Windows throw
					{}
		})(tmpDir);

		assert(equal(
			entries.sort,
			["a", "b", "c", "c/1", "c/2", "d", "d/1", "d/2", "e"].map!(name => name.replace("/", dirSeparator)),
		));
	}();
}

// ************************************************************************

private string buildPath2(string[] segments...) { return segments.length ? buildPath(segments) : null; }

/// Shell-like expansion of ?, * and ** in path components
DirEntry[] fileList(string pattern)
{
	auto components = cast(string[])array(pathSplitter(pattern));
	foreach (i, component; components[0..$-1])
		if (component.contains("?") || component.contains("*")) // TODO: escape?
		{
			DirEntry[] expansions; // TODO: filter range instead?
			auto dir = buildPath2(components[0..i]);
			if (component == "**")
				expansions = array(dirEntries(dir, SpanMode.depth));
			else
				expansions = array(dirEntries(dir, component, SpanMode.shallow));

			DirEntry[] result;
			foreach (expansion; expansions)
				if (expansion.isDir())
					result ~= fileList(buildPath(expansion.name ~ components[i+1..$]));
			return result;
		}

	auto dir = buildPath2(components[0..$-1]);
	if (!dir || exists(dir))
		return array(dirEntries(dir, components[$-1], SpanMode.shallow));
	else
		return null;
}

/// ditto
DirEntry[] fileList(string pattern0, string[] patterns...)
{
	DirEntry[] result;
	foreach (pattern; [pattern0] ~ patterns)
		result ~= fileList(pattern);
	return result;
}

/// ditto
deprecated string[] fastFileList(string pattern)
{
	auto components = cast(string[])array(pathSplitter(pattern));
	foreach (i, component; components[0..$-1])
		if (component.contains("?") || component.contains("*")) // TODO: escape?
		{
			string[] expansions; // TODO: filter range instead?
			auto dir = buildPath2(components[0..i]);
			if (component == "**")
				expansions = fastListDir!true(dir);
			else
				expansions = fastListDir(dir, component);

			string[] result;
			foreach (expansion; expansions)
				if (expansion.isDir())
					result ~= fastFileList(buildPath(expansion ~ components[i+1..$]));
			return result;
		}

	auto dir = buildPath2(components[0..$-1]);
	if (!dir || exists(dir))
		return fastListDir(dir, components[$-1]);
	else
		return null;
}

/// ditto
deprecated string[] fastFileList(string pattern0, string[] patterns...)
{
	string[] result;
	foreach (pattern; [pattern0] ~ patterns)
		result ~= fastFileList(pattern);
	return result;
}

// ************************************************************************

import std.datetime;
import std.exception;

deprecated SysTime getMTime(string name)
{
	return timeLastModified(name);
}

/// If target exists, update its modification time;
/// otherwise create it as an empty file.
void touch(in char[] target)
{
	if (exists(target))
	{
		auto now = Clock.currTime();
		setTimes(target, now, now);
	}
	else
		std.file.write(target, "");
}

/// Returns true if the target file doesn't exist,
/// or source is newer than the target.
bool newerThan(string source, string target)
{
	if (!target.exists)
		return true;
	return source.timeLastModified() > target.timeLastModified();
}

/// Returns true if the target file doesn't exist,
/// or any of the sources are newer than the target.
bool anyNewerThan(string[] sources, string target)
{
	if (!target.exists)
		return true;
	auto targetTime = target.timeLastModified();
	return sources.any!(source => source.timeLastModified() > targetTime)();
}

version (Posix)
{
	import core.sys.posix.sys.stat;
	import core.sys.posix.unistd;

	/// Get the ID of the user owning this file.
	int getOwner(string fn)
	{
		stat_t s;
		errnoEnforce(stat(toStringz(fn), &s) == 0, "stat: " ~ fn);
		return s.st_uid;
	}

	/// Get the ID of the group owning this file.
	int getGroup(string fn)
	{
		stat_t s;
		errnoEnforce(stat(toStringz(fn), &s) == 0, "stat: " ~ fn);
		return s.st_gid;
	}

	/// Set the owner user and group of this file.
	void setOwner(string fn, int uid, int gid)
	{
		errnoEnforce(chown(toStringz(fn), uid, gid) == 0, "chown: " ~ fn);
	}
}

/// Try to rename; copy/delete if rename fails
void move(string src, string dst)
{
	try
		src.rename(dst);
	catch (Exception e)
	{
		atomicCopy(src, dst);
		src.remove();
	}
}

/// Make sure that the given directory exists
/// (and create parent directories as necessary).
void ensureDirExists(string path)
{
	if (!path.exists)
		path.mkdirRecurse();
}

/// Make sure that the path to the given file name
/// exists (and create directories as necessary).
void ensurePathExists(string fn)
{
	fn.dirName.ensureDirExists();
}

static import core.stdc.errno;
version (Windows)
{
	static import core.sys.windows.winerror;
	static import std.windows.syserror;
	static import ae.sys.windows.exception;
}

/// Catch common Phobos exception types corresponding to file operations.
bool collectOSError(alias checkCError, alias checkWinError)(scope void delegate() operation)
{
	mixin(() {
		string code = q{
			try
			{
				operation();
				return true;
			}
			catch (FileException e)
			{
				version (Windows)
					bool collect = checkWinError(e.errno);
				else
					bool collect = checkCError(e.errno);
				if (collect)
					return false;
				else
					throw e;
			}
			catch (ErrnoException e)
			{
				if (checkCError(e.errno))
					return false;
				else
					throw e;
			}
		};
		version(Windows) code ~= q{
			catch (std.windows.syserror.WindowsException e)
			{
				if (checkWinError(e.code))
					return false;
				else
					throw e;
			}
			catch (ae.sys.windows.exception.WindowsException e)
			{
				if (checkWinError(e.code))
					return false;
				else
					throw e;
			}
		};
		return code;
	}());
}

/// Collect a "file not found" error.
alias collectNotFoundError = collectOSError!(
	errno => errno == core.stdc.errno.ENOENT,
	(code) { version(Windows) return
			 code == core.sys.windows.winerror.ERROR_FILE_NOT_FOUND ||
			 code == core.sys.windows.winerror.ERROR_PATH_NOT_FOUND; },
);

///
unittest
{
	auto fn = deleteme;
	if (fn.exists) fn.removeRecurse();
	foreach (dg; [
		{ openFile(fn, "rb"); },
		{ mkdir(fn.buildPath("b")); },
		{ hardLink(fn, fn ~ "2"); },
	])
		assert(!dg.collectNotFoundError);
}

/// Collect a "file already exists" error.
alias collectFileExistsError = collectOSError!(
	errno => errno == core.stdc.errno.EEXIST,
	(code) { version(Windows) return
			 code == core.sys.windows.winerror.ERROR_FILE_EXISTS ||
			 code == core.sys.windows.winerror.ERROR_ALREADY_EXISTS; },
);

///
unittest
{
	auto fn = deleteme;
	foreach (dg; [
		{ mkdir(fn); },
		{ openFile(fn, "wxb"); },
		{ touch(fn ~ "2"); hardLink(fn ~ "2", fn); },
	])
	{
		if (fn.exists) fn.removeRecurse();
		assert( dg.collectFileExistsError);
		assert(!dg.collectFileExistsError);
	}
}

import ae.utils.text;

/// Forcibly remove a file or directory.
/// If atomic is true, the entire directory is deleted "atomically"
/// (it is first moved/renamed to another location).
/// On Windows, this will move the file/directory out of the way,
/// if it is in use and cannot be deleted (but can be renamed).
void forceDelete(Flag!"atomic" atomic=Yes.atomic)(string fn, Flag!"recursive" recursive = No.recursive)
{
	import std.process : environment;
	version(Windows)
	{
		mixin(importWin32!q{winnt});
		mixin(importWin32!q{winbase});
	}

	auto name = fn.baseName();
	fn = fn.absolutePath().longPath();

	version(Windows)
	{
		auto fnW = toUTF16z(fn);
		auto attr = GetFileAttributesW(fnW);
		wenforce(attr != INVALID_FILE_ATTRIBUTES, "GetFileAttributes");
		if (attr & FILE_ATTRIBUTE_READONLY)
			SetFileAttributesW(fnW, attr & ~FILE_ATTRIBUTE_READONLY).wenforce("SetFileAttributes");
	}

	static if (atomic)
	{
		// To avoid zombifying locked directories, try renaming it first.
		// Attempting to delete a locked directory will make it inaccessible.

		bool tryMoveTo(string target)
		{
			target = target.longPath();
			if (target.endsWith(dirSeparator))
				target = target[0..$-1];
			if (target.length && !target.exists)
				return false;

			string newfn;
			do
				newfn = format("%s%sdeleted-%s.%s.%s", target, dirSeparator, name, thisProcessID, randomString());
			while (newfn.exists);

			version(Windows)
			{
				auto newfnW = toUTF16z(newfn);
				if (!MoveFileW(fnW, newfnW))
					return false;
			}
			else
			{
				try
					rename(fn, newfn);
				catch (FileException e)
					return false;
			}

			fn = newfn;
			version(Windows) fnW = newfnW;
			return true;
		}

		void tryMove()
		{
			auto tmp = environment.get("TEMP");
			if (tmp)
				if (tryMoveTo(tmp))
					return;

			version(Windows)
				string tempDir = fn[0..7]~"Temp";
			else
				enum tempDir = "/tmp";

			if (tryMoveTo(tempDir))
				return;

			if (tryMoveTo(fn.dirName()))
				return;

			throw new Exception("Unable to delete " ~ fn ~ " atomically (all rename attempts failed)");
		}

		tryMove();
	}

	version(Windows)
	{
		if (attr & FILE_ATTRIBUTE_DIRECTORY)
		{
			if (recursive && (attr & FILE_ATTRIBUTE_REPARSE_POINT) == 0)
			{
				foreach (de; fn.dirEntries(SpanMode.shallow))
					forceDelete!(No.atomic)(de.name, Yes.recursive);
			}
			// Will fail if !recursive and directory is not empty
			RemoveDirectoryW(fnW).wenforce("RemoveDirectory");
		}
		else
			DeleteFileW(fnW).wenforce("DeleteFile");
	}
	else
	{
		if (recursive)
			fn.removeRecurse();
		else
			if (fn.isDir)
				fn.rmdir();
			else
				fn.remove();
	}
}


deprecated void forceDelete(bool atomic)(string fn, bool recursive = false) { forceDelete!(cast(Flag!"atomic")atomic)(fn, cast(Flag!"recursive")recursive); }
//deprecated void forceDelete()(string fn, bool recursive) { forceDelete!(Yes.atomic)(fn, cast(Flag!"recursive")recursive); }

deprecated unittest
{
	mkdir("testdir"); touch("testdir/b"); forceDelete!(false     )("testdir", true);
	mkdir("testdir"); touch("testdir/b"); forceDelete!(true      )("testdir", true);
}

unittest
{
	mkdir("testdir"); touch("testdir/b"); forceDelete             ("testdir", Yes.recursive);
	mkdir("testdir"); touch("testdir/b"); forceDelete!(No .atomic)("testdir", Yes.recursive);
	mkdir("testdir"); touch("testdir/b"); forceDelete!(Yes.atomic)("testdir", Yes.recursive);
}

/// If fn is a directory, delete it recursively.
/// Otherwise, delete the file or symlink fn.
void removeRecurse(string fn)
{
	auto attr = fn.getAttributes();
	if (attr.attrIsSymlink)
	{
		version (Windows)
			if (attr.attrIsDir)
				fn.rmdir();
			else
				fn.remove();
		else
			fn.remove();
	}
	else
	if (attr.attrIsDir)
		version (Windows)
			fn.forceDelete!(No.atomic)(Yes.recursive); // For read-only files
		else
			fn.rmdirRecurse();
	else
		fn.remove();
}

/// Create an empty directory, deleting
/// all its contents if it already exists.
void recreateEmptyDirectory()(string dir)
{
	if (dir.exists)
		dir.forceDelete(Yes.recursive);
	mkdir(dir);
}

/// Copy a directory recursively.
void copyRecurse(DirEntry src, string dst)
{
	version (Posix)
		if (src.isSymlink)
			return symlink(dst, readLink(src));
	if (src.isFile)
		return copy(src, dst, PreserveAttributes.yes);
	dst.mkdir();
	foreach (de; src.dirEntries(SpanMode.shallow))
		copyRecurse(de, dst.buildPath(de.baseName));
}
void copyRecurse(string src, string dst) { copyRecurse(DirEntry(src), dst); } /// ditto

/// Return true if the given file would be hidden from directory listings.
/// Returns true for files starting with `'.'`, and, on Windows, hidden files.
bool isHidden()(string fn)
{
	if (baseName(fn).startsWith("."))
		return true;
	version (Windows)
	{
		mixin(importWin32!q{winnt});
		if (getAttributes(fn) & FILE_ATTRIBUTE_HIDDEN)
			return true;
	}
	return false;
}

/// Return a file's unique ID.
ulong getFileID()(string fn)
{
	version (Windows)
	{
		mixin(importWin32!q{winnt});
		mixin(importWin32!q{winbase});

		auto fnW = toUTF16z(fn);
		auto h = CreateFileW(fnW, FILE_READ_ATTRIBUTES, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		wenforce(h!=INVALID_HANDLE_VALUE, fn);
		scope(exit) CloseHandle(h);
		BY_HANDLE_FILE_INFORMATION fi;
		GetFileInformationByHandle(h, &fi).wenforce("GetFileInformationByHandle");

		ULARGE_INTEGER li;
		li.LowPart  = fi.nFileIndexLow;
		li.HighPart = fi.nFileIndexHigh;
		auto result = li.QuadPart;
		enforce(result, "Null file ID");
		return result;
	}
	else
	{
		return DirEntry(fn).statBuf.st_ino;
	}
}

unittest
{
	auto base = deleteme;
	touch(base ~ "a");
	scope(exit) remove(base ~ "a");
	hardLink(base ~ "a", base ~ "b");
	scope(exit) remove(base ~ "b");
	touch(base ~ "c");
	scope(exit) remove(base ~ "c");
	assert(getFileID(base ~ "a") == getFileID(base ~ "b"));
	assert(getFileID(base ~ "a") != getFileID(base ~ "c"));
}

deprecated alias std.file.getSize getSize2;

/// Using UNC paths bypasses path length limitation when using Windows wide APIs.
string longPath(string s)
{
	version (Windows)
	{
		if (!s.startsWith(`\\`))
			return `\\?\` ~ s.absolutePath().buildNormalizedPath().replace(`/`, `\`);
	}
	return s;
}

version (Windows)
{
	static if (__traits(compiles, { mixin importWin32!q{winnt}; }))
		static mixin(importWin32!q{winnt});

	/// Common code for creating Windows reparse points.
	private void createReparsePoint(string reparseBufferName, string extraInitialization, string reparseTagName)(in char[] target, in char[] print, in char[] link)
	{
		mixin(importWin32!q{winbase});
		mixin(importWin32!q{windef});
		mixin(importWin32!q{winioctl});

		enum SYMLINK_FLAG_RELATIVE = 1;

		HANDLE hLink = CreateFileW(link.toUTF16z(), GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, null);
		wenforce(hLink && hLink != INVALID_HANDLE_VALUE, "CreateFileW");
		scope(exit) CloseHandle(hLink);

		enum pathOffset =
			mixin(q{REPARSE_DATA_BUFFER.} ~ reparseBufferName)            .offsetof +
			mixin(q{REPARSE_DATA_BUFFER.} ~ reparseBufferName)._PathBuffer.offsetof;

		auto targetW = target.toUTF16();
		auto printW  = print .toUTF16();

		// Despite MSDN, two NUL-terminating characters are needed, one for each string.

		auto pathBufferSize = targetW.length + 1 + printW.length + 1; // in chars
		auto buf = new ubyte[pathOffset + pathBufferSize * WCHAR.sizeof];
		auto r = cast(REPARSE_DATA_BUFFER*)buf.ptr;

		r.ReparseTag = mixin(reparseTagName);
		r.ReparseDataLength = to!WORD(buf.length - mixin(q{r.} ~ reparseBufferName).offsetof);

		auto pathBuffer = mixin(q{r.} ~ reparseBufferName).PathBuffer;
		auto p = pathBuffer;

		mixin(q{r.} ~ reparseBufferName).SubstituteNameOffset = to!WORD((p-pathBuffer) * WCHAR.sizeof);
		mixin(q{r.} ~ reparseBufferName).SubstituteNameLength = to!WORD(targetW.length * WCHAR.sizeof);
		p[0..targetW.length] = targetW;
		p += targetW.length;
		*p++ = 0;

		mixin(q{r.} ~ reparseBufferName).PrintNameOffset      = to!WORD((p-pathBuffer) * WCHAR.sizeof);
		mixin(q{r.} ~ reparseBufferName).PrintNameLength      = to!WORD(printW .length * WCHAR.sizeof);
		p[0..printW.length] = printW;
		p += printW.length;
		*p++ = 0;

		assert(p-pathBuffer == pathBufferSize);

		mixin(extraInitialization);

		DWORD dwRet; // Needed despite MSDN
		DeviceIoControl(hLink, FSCTL_SET_REPARSE_POINT, buf.ptr, buf.length.to!DWORD(), null, 0, &dwRet, null).wenforce("DeviceIoControl");
	}

	/// Attempt to acquire the specified privilege.
	void acquirePrivilege(S)(S name)
	{
		mixin(importWin32!q{winbase});
		mixin(importWin32!q{windef});

		import ae.sys.windows;

		HANDLE hToken = null;
		wenforce(OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES, &hToken));
		scope(exit) CloseHandle(hToken);

		TOKEN_PRIVILEGES tp;
		wenforce(LookupPrivilegeValue(null, name.toUTF16z(), &tp.Privileges[0].Luid), "LookupPrivilegeValue");

		tp.PrivilegeCount = 1;
		tp.Privileges[0].Attributes = SE_PRIVILEGE_ENABLED;
		wenforce(AdjustTokenPrivileges(hToken, FALSE, &tp, cast(DWORD)TOKEN_PRIVILEGES.sizeof, null, null), "AdjustTokenPrivileges");
	}

	/// Link a directory.
	/// Uses symlinks on POSIX, and directory junctions on Windows.
	void dirLink()(in char[] original, in char[] link)
	{
		mkdir(link);
		scope(failure) rmdir(link);

		auto target = `\??\` ~ (cast(string)original).absolutePath((cast(string)link.dirName).absolutePath).buildNormalizedPath;
		if (target[$-1] != '\\')
			target ~= '\\';

		createReparsePoint!(q{MountPointReparseBuffer}, q{}, q{IO_REPARSE_TAG_MOUNT_POINT})(target, null, link);
	}

	/// Windows implementation of `std.file.symlink`.
	void symlink()(in char[] original, in char[] link)
	{
		mixin(importWin32!q{winnt});

		acquirePrivilege(SE_CREATE_SYMBOLIC_LINK_NAME);

		touch(link);
		scope(failure) remove(link);

		createReparsePoint!(q{SymbolicLinkReparseBuffer}, q{r.SymbolicLinkReparseBuffer.Flags = link.isAbsolute() ? 0 : SYMLINK_FLAG_RELATIVE;}, q{IO_REPARSE_TAG_SYMLINK})(original, original, link);
	}
}
else
	alias std.file.symlink dirLink; /// `std.file.symlink` is used to implement `dirLink` on POSIX.

version(Windows) version(unittest) static mixin(importWin32!q{winnt});

unittest
{
	// Wine's implementation of symlinks/junctions is incomplete
	version (Windows)
		if (getWineVersion())
			return;

	mkdir("a"); scope(exit) rmdir("a"[]);
	touch("a/f"); scope(exit) remove("a/f");
	dirLink("a", "b"); scope(exit) version(Windows) rmdir("b"); else remove("b");
	//symlink("a/f", "c"); scope(exit) remove("c");
	assert("b".isSymlink());
	//assert("c".isSymlink());
	assert("b/f".exists());
}

version (Windows)
{
	/// Create a hard link.
	void hardLink()(string src, string dst)
	{
		mixin(importWin32!q{w32api});

		static assert(_WIN32_WINNT >= 0x501, "CreateHardLinkW not available for target Windows platform. Specify -version=WindowsXP");

		mixin(importWin32!q{winnt});
		mixin(importWin32!q{winbase});

		wenforce(CreateHardLinkW(toUTF16z(dst), toUTF16z(src), null), "CreateHardLink failed: " ~ src ~ " -> " ~ dst);
	}

	/// Deletes a file, which might be a read-only hard link
	/// (thus, deletes the read-only file/link without affecting other links to it).
	void deleteHardLink()(string fn)
	{
		mixin(importWin32!q{winbase});

		auto fnW = toUTF16z(fn);

		DWORD attrs = GetFileAttributesW(fnW);
		wenforce(attrs != INVALID_FILE_ATTRIBUTES, "GetFileAttributesW failed: " ~ fn);

		if (attrs & FILE_ATTRIBUTE_READONLY)
			SetFileAttributesW(fnW, attrs & ~FILE_ATTRIBUTE_READONLY)
			.wenforce("SetFileAttributesW failed: " ~ fn);
		HANDLE h = CreateFileW(fnW, GENERIC_READ|GENERIC_WRITE, 7, null, OPEN_EXISTING,
					FILE_FLAG_DELETE_ON_CLOSE, null);
		wenforce(h != INVALID_HANDLE_VALUE, "CreateFileW failed: " ~ fn);
		if (attrs & FILE_ATTRIBUTE_READONLY)
			SetFileAttributesW(fnW, attrs)
			.wenforce("SetFileAttributesW failed: " ~ fn);
		CloseHandle(h).wenforce("CloseHandle failed: " ~ fn);
	}
}
version (Posix)
{
	/// Create a hard link.
	void hardLink()(string src, string dst)
	{
		import core.sys.posix.unistd;
		errnoEnforce(link(toUTFz!(const char*)(src), toUTFz!(const char*)(dst)) == 0, "link() failed: " ~ dst);
	}

	alias deleteHardLink = remove; /// `std.file.remove` is used to implement `deleteHardLink` on POSIX.
}

unittest
{
	write("a", "foo"); scope(exit) remove("a");
	hardLink("a", "b");
	assert("b".readText == "foo");
	deleteHardLink("b");
	assert(!"b".exists);
}

version (Posix)
{
	/// Wrapper around the C `realpath` function.
	string realPath(string path)
	{
		// TODO: Windows version
		import core.sys.posix.stdlib;
		auto p = realpath(toUTFz!(const char*)(path), null);
		errnoEnforce(p, "realpath");
		string result = fromStringz(p).idup;
		free(p);
		return result;
	}
}

// /proc/self/mounts parsing
version (linux)
{
	/// A parsed line from /proc/self/mounts.
	struct MountInfo
	{
		string spec; /// device path
		string file; /// mount path
		string vfstype; /// file system
		string mntops; /// options
		int freq; /// dump flag
		int passno; /// fsck order
	}

	private string unescapeMountString(in char[] s)
	{
		string result;

		size_t p = 0;
		for (size_t i=0; i+3<s.length;)
		{
			auto c = s[i];
			if (c == '\\')
			{
				result ~= s[p..i];
				result ~= to!int(s[i+1..i+4], 8);
				i += 4;
				p = i;
			}
			else
				i++;
		}
		result ~= s[p..$];
		return result;
	}

	unittest
	{
		assert(unescapeMountString(`a\040b\040c`) == "a b c");
		assert(unescapeMountString(`\040`) == " ");
	}

	/// Parse a line from /proc/self/mounts.
	MountInfo parseMountInfo(in char[] line)
	{
		const(char)[][6] parts;
		copy(line.splitter(" "), parts[]);
		return MountInfo(
			unescapeMountString(parts[0]),
			unescapeMountString(parts[1]),
			unescapeMountString(parts[2]),
			unescapeMountString(parts[3]),
			parts[4].to!int,
			parts[5].to!int,
		);
	}

	/// Returns an iterator of MountInfo structs.
	auto getMounts()
	{
		return File("/proc/self/mounts", "rb").byLine().map!parseMountInfo();
	}

	/// Get MountInfo with longest mount point matching path.
	/// Returns MountInfo.init if none match.
	MountInfo getPathMountInfo(string path)
	{
		path = realPath(path);
		size_t bestLength; MountInfo bestInfo;
		foreach (ref info; getMounts())
		{
			if (path.pathStartsWith(info.file))
			{
				if (bestLength < info.file.length)
				{
					bestLength = info.file.length;
					bestInfo = info;
				}
			}
		}
		return bestInfo;
	}

	/// Get the name of the filesystem that the given path is mounted under.
	/// Returns null if none match.
	string getPathFilesystem(string path)
	{
		return getPathMountInfo(path).vfstype;
	}
}

// ****************************************************************************

version (linux)
{
	import core.sys.linux.sys.xattr;
	import core.stdc.errno;
	private alias ENOATTR = ENODATA;

	/// AA-like object for accessing a file's extended attributes.
	struct XAttrs(Obj, string funPrefix)
	{
		private Obj obj;

		mixin("alias getFun = " ~ funPrefix ~ "getxattr;");
		mixin("alias setFun = " ~ funPrefix ~ "setxattr;");
		mixin("alias removeFun = " ~ funPrefix ~ "removexattr;");
		mixin("alias listFun = " ~ funPrefix ~ "listxattr;");

		/// True if extended attributes are supported on this filesystem.
		bool supported()
		{
			auto size = getFun(obj, "user.\x01", null, 0);
			return size >= 0 || errno != EOPNOTSUPP;
		}

		/// Read an extended attribute.
		void[] opIndex(string key)
		{
			auto cKey = key.toStringz();
			size_t size = 0;
			void[] buf;
			do
			{
				buf.length = size;
				size = getFun(obj, cKey, buf.ptr, buf.length);
				errnoEnforce(size >= 0, __traits(identifier, getFun));
			} while (size != buf.length);
			return buf;
		}

		/// Check if an extended attribute is present.
		bool opBinaryRight(string op)(string key)
		if (op == "in")
		{
			auto cKey = key.toStringz();
			auto size = getFun(obj, cKey, null, 0);
			if (size >= 0)
				return true;
			else
			if (errno == ENOATTR)
				return false;
			else
				errnoEnforce(false, __traits(identifier, getFun));
			assert(false);
		}

		/// Write an extended attribute.
		void opIndexAssign(in void[] value, string key)
		{
			auto ret = setFun(obj, key.toStringz(), value.ptr, value.length, 0);
			errnoEnforce(ret == 0, __traits(identifier, setFun));
		}

		/// Delete an extended attribute.
		void remove(string key)
		{
			auto ret = removeFun(obj, key.toStringz());
			errnoEnforce(ret == 0, __traits(identifier, removeFun));
		}

		/// Return a list of all extended attribute names.
		string[] keys()
		{
			size_t size = 0;
			char[] buf;
			do
			{
				buf.length = size;
				size = listFun(obj, buf.ptr, buf.length);
				errnoEnforce(size >= 0, __traits(identifier, listFun));
			} while (size != buf.length);

			char[][] result;
			size_t start;
			foreach (p, c; buf)
				if (!c)
				{
					result ~= buf[start..p];
					start = p+1;
				}

			return cast(string[])result;
		}
	}

	/// Return `XAttrs` for the given path,
	/// or the link destination if the path leads to as symbolic link.
	auto xAttrs(string path)
	{
		return XAttrs!(const(char)*, "")(path.toStringz());
	}

	/// Return `XAttrs` for the given path.
	auto linkXAttrs(string path)
	{
		return XAttrs!(const(char)*, "l")(path.toStringz());
	}

	/// Return `XAttrs` for the given open file.
	auto xAttrs(ref const File f)
	{
		return XAttrs!(int, "f")(f.fileno);
	}

	///
	unittest
	{
		if (!xAttrs(".").supported)
		{
			import std.stdio : stderr;
			stderr.writeln("ae.sys.file: xattrs not supported on current filesystem, skipping test.");
			return;
		}

		enum fn = "test.txt";
		std.file.write(fn, "test");
		scope(exit) remove(fn);

		auto attrs = xAttrs(fn);
		enum key = "user.foo";
		assert(key !in attrs);
		assert(attrs.keys == []);

		attrs[key] = "bar";
		assert(key in attrs);
		assert(attrs[key] == "bar");
		assert(attrs.keys == [key]);

		attrs.remove(key);
		assert(key !in attrs);
		assert(attrs.keys == []);
	}
}

// ****************************************************************************

version (Windows)
{
	/// Enumerate all hard links to the specified file.
	// TODO: Return a range
	string[] enumerateHardLinks()(string fn)
	{
		mixin(importWin32!q{winnt});
		mixin(importWin32!q{winbase});

		alias extern(System) HANDLE function(LPCWSTR lpFileName, DWORD dwFlags, LPDWORD StringLength, PWCHAR LinkName) TFindFirstFileNameW;
		alias extern(System) BOOL function(HANDLE hFindStream, LPDWORD StringLength, PWCHAR LinkName) TFindNextFileNameW;

		auto kernel32 = GetModuleHandle("kernel32.dll");
		auto FindFirstFileNameW = cast(TFindFirstFileNameW)GetProcAddress(kernel32, "FindFirstFileNameW").wenforce("GetProcAddress(FindFirstFileNameW)");
		auto FindNextFileNameW = cast(TFindNextFileNameW)GetProcAddress(kernel32, "FindNextFileNameW").wenforce("GetProcAddress(FindNextFileNameW)");

		static WCHAR[0x8000] buf;
		DWORD len = buf.length;
		auto h = FindFirstFileNameW(toUTF16z(fn), 0, &len, buf.ptr);
		wenforce(h != INVALID_HANDLE_VALUE, "FindFirstFileNameW");
		scope(exit) FindClose(h);

		string[] result;
		do
		{
			enforce(len > 0 && len < buf.length && buf[len-1] == 0, "Bad FindFirst/NextFileNameW result");
			result ~= buf[0..len-1].toUTF8();
			len = buf.length;
			auto ok = FindNextFileNameW(h, &len, buf.ptr);
			if (!ok && GetLastError() == ERROR_HANDLE_EOF)
				break;
			wenforce(ok, "FindNextFileNameW");
		} while(true);
		return result;
	}
}

/// Obtain the hard link count for the given file.
uint hardLinkCount(string fn)
{
	version (Windows)
	{
		// TODO: Optimize (don't transform strings)
		return cast(uint)fn.enumerateHardLinks.length;
	}
	else
	{
		import core.sys.posix.sys.stat;

		stat_t s;
		errnoEnforce(stat(fn.toStringz(), &s) == 0, "stat");
		return s.st_nlink.to!uint;
	}
}

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version (unittest)
	version (Windows)
		import ae.sys.windows.misc : getWineVersion;

unittest
{
	// FindFirstFileNameW not implemented in Wine
	version (Windows)
		if (getWineVersion())
			return;

	touch("a.test");
	scope(exit) remove("a.test");
	assert("a.test".hardLinkCount() == 1);

	hardLink("a.test", "b.test");
	scope(exit) remove("b.test");
	assert("a.test".hardLinkCount() == 2);
	assert("b.test".hardLinkCount() == 2);

	version(Windows)
	{
		auto paths = enumerateHardLinks("a.test");
		assert(paths.length == 2);
		paths.sort();
		assert(paths[0].endsWith(`\a.test`), paths[0]);
		assert(paths[1].endsWith(`\b.test`));
	}
}

/// Argument-reversed version of `std.file.write`,
/// usable at the end of an UFCS chain.
static if (is(typeof({ import std.stdio : toFile; })))
{
	static import std.stdio;
	alias toFile = std.stdio.toFile;
}
else
{
	void toFile(in void[] data, in char[] name)
	{
		std.file.write(name, data);
	}
}

/// Same as toFile, but accepts void[] and does not conflict with the
/// std.stdio function.
void writeTo(in void[] data, in char[] target)
{
	std.file.write(target, data);
}

/// Polyfill for Windows fopen implementations with support for UNC
/// paths and the 'x' subspecifier.
File openFile()(string fn, string mode = "rb")
{
	File f;
	static if (is(typeof(&f.windowsHandleOpen)))
	{
		import core.sys.windows.windows;
		import ae.sys.windows.exception;

		string winMode, cMode;
		foreach (c; mode)
		{
			switch (c)
			{
				case 'r':
				case 'w':
				case 'a':
				case '+':
				case 'x':
					winMode ~= c;
					break;
				case 'b':
				case 't':
					break;
				default:
					assert(false, "Unknown character in mode");
			}
			if (c != 'x')
				cMode ~= c;
		}
		DWORD access, creation;
		bool append;
		switch (winMode)
		{
			case "r"  : access = GENERIC_READ                ; creation = OPEN_EXISTING; break;
			case "r+" : access = GENERIC_READ | GENERIC_WRITE; creation = OPEN_EXISTING; break;
			case "w"  : access =                GENERIC_WRITE; creation = CREATE_ALWAYS; break;
			case "w+" : access = GENERIC_READ | GENERIC_WRITE; creation = CREATE_ALWAYS; break;
			case "a"  : access =                GENERIC_WRITE; creation = OPEN_ALWAYS  ; version (CRuntime_Microsoft) append = true; break;
			case "a+" : access = GENERIC_READ | GENERIC_WRITE; creation = OPEN_ALWAYS  ; version (CRuntime_Microsoft) assert(false, "MSVCRT can't fdopen with a+"); else break;
			case "wx" : access =                GENERIC_WRITE; creation = CREATE_NEW   ; break;
			case "w+x": access = GENERIC_READ | GENERIC_WRITE; creation = CREATE_NEW   ; break;
			case "ax" : access =                GENERIC_WRITE; creation = CREATE_NEW   ; version (CRuntime_Microsoft) append = true; break;
			case "a+x": access = GENERIC_READ | GENERIC_WRITE; creation = CREATE_NEW   ; version (CRuntime_Microsoft) assert(false, "MSVCRT can't fdopen with a+"); else break;
			default: assert(false, "Bad file mode: " ~ mode);
		}

		auto pathW = toUTF16z(longPath(fn));
		auto h = CreateFileW(pathW, access, FILE_SHARE_READ, null, creation, 0, HANDLE.init);
		wenforce(h != INVALID_HANDLE_VALUE);

		if (append)
			h.SetFilePointer(0, null, FILE_END);

		f.windowsHandleOpen(h, cMode);
	}
	else
		f.open(fn, mode);
	return f;
}

unittest
{
	enum Existence { any, mustExist, mustNotExist }
	enum Pos { none /* not readable/writable */, start, end, empty }
	static struct Behavior
	{
		Existence existence;
		bool truncating;
		Pos read, write;
	}

	void test(string mode, in Behavior expected)
	{
		static if (isVersion!q{CRuntime_Microsoft} || isVersion!q{OSX})
			if (mode == "a+" || mode == "a+x")
				return;

		Behavior behavior;

		static int counter;
		auto fn = text(deleteme, counter++);

		collectException(fn.remove());
		bool mustExist    = !!collectException(openFile(fn, mode));
		touch(fn);
		bool mustNotExist = !!collectException(openFile(fn, mode));

		if (!mustExist)
			if (!mustNotExist)
				behavior.existence = Existence.any;
			else
				behavior.existence = Existence.mustNotExist;
		else
			if (!mustNotExist)
				behavior.existence = Existence.mustExist;
			else
				assert(false, "Can't open file whether it exists or not");

		void create()
		{
			if (mustNotExist)
				collectException(fn.remove());
			else
				write(fn, "foo");
		}

		create();
		openFile(fn, mode);
		behavior.truncating = getSize(fn) == 0;

		create();
		{
			auto f = openFile(fn, mode);
			ubyte[] buf;
			if (collectException(f.rawRead(new ubyte[1]), buf))
			{
				behavior.read = Pos.none;
				// Work around https://issues.dlang.org/show_bug.cgi?id=19751
				f.reopen(fn, "w");
			}
			else
			if (buf.length)
				behavior.read = Pos.start;
			else
			if (f.size)
				behavior.read = Pos.end;
			else
				behavior.read = Pos.empty;
		}

		create();
		{
			string s;
			{
				auto f = openFile(fn, mode);
				if (collectException(f.rawWrite("b")))
				{
					s = null;
					// Work around https://issues.dlang.org/show_bug.cgi?id=19751
					f.reopen(fn, "w");
				}
				else
				{
					f.close();
					s = fn.readText;
				}
			}

			if (s is null)
				behavior.write = Pos.none;
			else
			if (s == "b")
				behavior.write = Pos.empty;
			else
			if (s.endsWith("b"))
				behavior.write = Pos.end;
			else
			if (s.startsWith("b"))
				behavior.write = Pos.start;
			else
				assert(false, "Can't detect write position");
		}


		if (behavior != expected)
		{
			import ae.utils.array : isOneOf;
			version (Windows)
				if (getWineVersion() && mode.isOneOf("w", "a", "wx", "ax"))
				{
					// Ignore bug in Wine msvcrt implementation
					return;
				}

			assert(false, text(mode, ": expected ", expected, ", got ", behavior));
		}
	}

	test("r"  , Behavior(Existence.mustExist   , false, Pos.start, Pos.none ));
	test("r+" , Behavior(Existence.mustExist   , false, Pos.start, Pos.start));
	test("w"  , Behavior(Existence.any         , true , Pos.none , Pos.empty));
	test("w+" , Behavior(Existence.any         , true , Pos.empty, Pos.empty));
	test("a"  , Behavior(Existence.any         , false, Pos.none , Pos.end  ));
	test("a+" , Behavior(Existence.any         , false, Pos.start, Pos.end  ));
	test("wx" , Behavior(Existence.mustNotExist, true , Pos.none , Pos.empty));
	test("w+x", Behavior(Existence.mustNotExist, true , Pos.empty, Pos.empty));
	test("ax" , Behavior(Existence.mustNotExist, true , Pos.none , Pos.empty));
	test("a+x", Behavior(Existence.mustNotExist, true , Pos.empty, Pos.empty));
}

private version(Windows)
{
	version (CRuntime_Microsoft)
	{
		alias chsize_size_t = long;
		extern(C) int _chsize_s(int fd, chsize_size_t size);
		alias chsize = _chsize_s;
	}
	else
	{
		import core.stdc.config : c_long;
		alias chsize_size_t = c_long;
		extern(C) int chsize(int fd, c_long size);
	}
}

/// Truncate the given file to the given size.
void truncate(File f, ulong length)
{
	f.flush();
	version (Windows)
		chsize(f.fileno, length.to!chsize_size_t);
	else
		ftruncate(f.fileno, length.to!off_t);
}

unittest
{
	write("test.txt", "abcde");
	auto f = File("test.txt", "r+b");
	f.write("xyz");
	f.truncate(f.tell);
	f.close();
	assert("test.txt".readText == "xyz");
}

/// Calculate the digest of a file.
auto fileDigest(Digest)(string fn)
{
	import std.range.primitives;
	Digest context;
	context.start();
	put(context, openFile(fn, "rb").byChunk(64 * 1024));
	auto digest = context.finish();
	return digest;
}

/// Calculate the MD5 hash of a file.
template mdFile()
{
	import std.digest.md;
	alias mdFile = fileDigest!MD5;
}

version (HAVE_WIN32)
unittest
{
	import std.digest : toHexString;
	write("test.txt", "Hello, world!");
	scope(exit) remove("test.txt");
	assert(mdFile("test.txt").toHexString() == "6CD3556DEB0DA54BCA060B4C39479839");
}

/// Calculate the digest of a file, and memoize it.
auto fileDigestCached(Digest)(string fn)
{
	static typeof(Digest.init.finish())[ulong] cache;
	auto id = getFileID(fn);
	auto phash = id in cache;
	if (phash)
		return *phash;
	return cache[id] = fileDigest!Digest(fn);
}

/// Calculate the MD5 hash of a file, and memoize it.
template mdFileCached()
{
	import std.digest.md;
	alias mdFileCached = fileDigestCached!MD5;
}

version (HAVE_WIN32)
unittest
{
	import std.digest : toHexString;
	write("test.txt", "Hello, world!");
	scope(exit) remove("test.txt");
	assert(mdFileCached("test.txt").toHexString() == "6CD3556DEB0DA54BCA060B4C39479839");
	write("test.txt", "Something else");
	assert(mdFileCached("test.txt").toHexString() == "6CD3556DEB0DA54BCA060B4C39479839");
}

/// Read a File (which might be a stream) into an array
void[] readFile(File f)
{
	import std.range.primitives;
	auto result = appender!(ubyte[]);
	put(result, f.byChunk(64*1024));
	return result.data;
}

unittest
{
	auto s = "0123456789".replicate(10_000);
	write("test.txt", s);
	scope(exit) remove("test.txt");
	assert(readFile(File("test.txt")) == s);
}

/// Read exactly `buf.length` bytes and return true.
/// On EOF, return false.
bool readExactly(ref File f, ubyte[] buf)
{
	if (!buf.length)
		return true;
	auto read = f.rawRead(buf);
	if (read.length==0) return false;
	enforce(read.length == buf.length, "Unexpected end of file");
	return true;
}

private
version (Windows)
{
	version (CRuntime_DigitalMars)
		extern(C) sizediff_t read(int, void*, size_t);
	else
	{
		extern(C) sizediff_t _read(int, void*, size_t);
		alias read = _read;
	}
}
else
	import core.sys.posix.unistd : read;

/// Like `File.rawRead`, but returns as soon as any data is available.
void[] readPartial(File f, void[] buf)
{
	assert(buf.length);
	auto numRead = read(f.fileno, buf.ptr, buf.length);
	errnoEnforce(numRead >= 0);
	return buf[0 .. numRead];
}

/// Like std.file.readText for non-UTF8
ascii readAscii()(string fileName)
{
	return cast(ascii)readFile(openFile(fileName, "rb"));
}

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version(Posix) static import ae.sys.signals;

/// Start a thread which writes data to f asynchronously.
Thread writeFileAsync(File f, in void[] data)
{
	static class Writer : Thread
	{
		File target;
		const void[] data;

		this(ref File f, in void[] data)
		{
			this.target = f;
			this.data = data;
			super(&run);
		}

		void run()
		{
			version (Posix)
			{
				import ae.sys.signals;
				collectSignal(SIGPIPE, &write);
			}
			else
				write();
		}

		void write()
		{
			target.rawWrite(data);
			target.close();
		}
	}

	auto t = new Writer(f, data);
	t.start();
	return t;
}

/// Write data to a file, and ensure it gets written to disk
/// before this function returns.
/// Consider using as atomic!syncWrite.
/// See also: syncUpdate
void syncWrite()(string target, in void[] data)
{
	auto f = File(target, "wb");
	f.rawWrite(data);
	version (Windows)
	{
		mixin(importWin32!q{windows});
		FlushFileBuffers(f.windowsHandle);
	}
	else
	{
		import core.sys.posix.unistd;
		fsync(f.fileno);
	}
	f.close();
}

/// Atomically save data to a file (if the file doesn't exist,
/// or its contents differs). The update operation as a whole
/// is not atomic, only the write is.
void syncUpdate()(string fn, in void[] data)
{
	if (!fn.exists || fn.read() != data)
		atomic!(syncWrite!())(fn, data);
}

version(Windows) import ae.sys.windows.exception;

/// Create a named pipe, and allow interacting with it using a `std.stdio.File`.
struct NamedPipeImpl
{
	immutable string fileName; ///

	/// Create a named pipe, and reserve a filename.
	this()(string name)
	{
		version(Windows)
		{
			mixin(importWin32!q{winbase});

			fileName = `\\.\pipe\` ~ name;
			auto h = CreateNamedPipeW(fileName.toUTF16z, PIPE_ACCESS_OUTBOUND, PIPE_TYPE_BYTE, 10, 4096, 4096, 0, null).wenforce("CreateNamedPipeW");
			f.windowsHandleOpen(h, "wb");
		}
		else
		{
			import core.sys.posix.sys.stat;

			fileName = `/tmp/` ~ name ~ `.fifo`;
			mkfifo(fileName.toStringz, S_IWUSR | S_IRUSR);
		}
	}

	/// Wait for a peer to open the other end of the pipe.
	File connect()()
	{
		version(Windows)
		{
			mixin(importWin32!q{winbase});
			mixin(importWin32!q{windef});

			BOOL bSuccess = ConnectNamedPipe(f.windowsHandle, null);

			// "If a client connects before the function is called, the function returns zero
			// and GetLastError returns ERROR_PIPE_CONNECTED. This can happen if a client
			// connects in the interval between the call to CreateNamedPipe and the call to
			// ConnectNamedPipe. In this situation, there is a good connection between client
			// and server, even though the function returns zero."
			if (!bSuccess)
				wenforce(GetLastError() == ERROR_PIPE_CONNECTED, "ConnectNamedPipe");

			return f;
		}
		else
		{
			return File(fileName, "w");
		}
	}

	~this()
	{
		version(Windows)
		{
			// File.~this will take care of cleanup
		}
		else
			fileName.remove();
	}

private:
	File f;
}
alias NamedPipe = RefCounted!NamedPipeImpl; /// ditto

import ae.utils.textout : StringBuilder;

/// Avoid std.stdio.File.readln's memory corruption bug
/// https://issues.dlang.org/show_bug.cgi?id=13856
string safeReadln(File f)
{
	StringBuilder buf;
	char[1] arr;
	while (true)
	{
		auto result = f.rawRead(arr[]);
		if (!result.length)
			break;
		buf.put(result);
		if (result[0] == '\x0A')
			break;
	}
	return buf.get();
}

// ****************************************************************************

/// Change the current directory to the given directory. Does nothing if dir is null.
/// Return a scope guard which, upon destruction, restores the previous directory.
/// Asserts that only one thread has changed the process's current directory at any time.
auto pushd(string dir)
{
	import core.atomic;

	static int threadCount = 0;
	static shared int processCount = 0;

	static struct Popd
	{
		string oldPath;
		this(string cwd) { oldPath = cwd; }
		~this() { if (oldPath) pop(); }
		@disable this();
		@disable this(this);

		void pop()
		{
			assert(oldPath);
			scope(exit) oldPath = null;
			chdir(oldPath);

			auto newThreadCount = --threadCount;
			auto newProcessCount = atomicOp!"-="(processCount, 1);
			assert(newThreadCount == newProcessCount); // Shouldn't happen
		}
	}

	string cwd;
	if (dir)
	{
		auto newThreadCount = ++threadCount;
		auto newProcessCount = atomicOp!"+="(processCount, 1);
		assert(newThreadCount == newProcessCount, "Another thread already has an active pushd");

		cwd = getcwd();
		chdir(dir);
	}
	return Popd(cwd);
}

// ****************************************************************************

import std.algorithm;
import std.process : thisProcessID;
import std.traits;
import std.typetuple;
import ae.utils.meta;

/// Parameter names that `atomic` assumes
/// indicate a destination file by default.
enum targetParameterNames = "target/to/name/dst";

/// Wrap an operation which creates a file or directory,
/// so that it is created safely and, for files, atomically
/// (by performing the underlying operation to a temporary
/// location, then renaming the completed file/directory to
/// the actual target location). targetName specifies the name
/// of the parameter containing the target file/directory.
auto atomic(alias impl, string targetName = targetParameterNames)(staticMap!(Unqual, ParameterTypeTuple!impl) args)
{
	enum targetIndex = findParameter([ParameterIdentifierTuple!impl], targetName, __traits(identifier, impl));
	return atomic!(impl, targetIndex)(args);
}

/// ditto
auto atomic(alias impl, size_t targetIndex)(staticMap!(Unqual, ParameterTypeTuple!impl) args)
{
	// idup for https://d.puremagic.com/issues/show_bug.cgi?id=12503
	auto target = args[targetIndex].idup;
	auto temp = "%s.%s.%s.temp".format(target, thisProcessID, getCurrentThreadID);
	if (temp.exists) temp.removeRecurse();
	scope(success) rename(temp, target);
	scope(failure) if (temp.exists) temp.removeRecurse();
	args[targetIndex] = temp;
	return impl(args);
}

/// ditto
// Workaround for https://d.puremagic.com/issues/show_bug.cgi?id=12230
// Can't be an overload because of https://issues.dlang.org/show_bug.cgi?id=13374
//R atomicDg(string targetName = "target", R, Args...)(R delegate(Args) impl, staticMap!(Unqual, Args) args)
auto atomicDg(size_t targetIndexA = size_t.max, Impl, Args...)(Impl impl, Args args)
{
	enum targetIndex = targetIndexA == size_t.max ? ParameterTypeTuple!impl.length-1 : targetIndexA;
	return atomic!(impl, targetIndex)(args);
}

deprecated alias safeUpdate = atomic;

unittest
{
	enum fn = "atomic.tmp";
	scope(exit) if (fn.exists) fn.remove();

	atomic!touch(fn);
	assert(fn.exists);
	fn.remove();

	atomicDg(&touch, fn);
	assert(fn.exists);
}

/// Wrap an operation so that it is skipped entirely
/// if the target already exists. Implies atomic.
auto cached(alias impl, string targetName = targetParameterNames)(ParameterTypeTuple!impl args)
{
	enum targetIndex = findParameter([ParameterIdentifierTuple!impl], targetName, __traits(identifier, impl));
	auto target = args[targetIndex];
	if (!target.exists)
		atomic!(impl, targetIndex)(args);
	return target;
}

/// ditto
// Exists due to the same reasons as atomicDg
auto cachedDg(size_t targetIndexA = size_t.max, Impl, Args...)(Impl impl, Args args)
{
	enum targetIndex = targetIndexA == size_t.max ? ParameterTypeTuple!impl.length-1 : targetIndexA;
	auto target = args[targetIndex];
	if (!target.exists)
		atomic!(impl, targetIndex)(args);
	return target;
}

deprecated alias obtainUsing = cached;

/// Create a file, or replace an existing file's contents
/// atomically.
/// Note: Consider using atomic!syncWrite or
/// atomic!syncUpdate instead.
alias atomicWrite = atomic!_writeProxy;
deprecated alias safeWrite = atomicWrite;
/*private*/ void _writeProxy(string target, in void[] data)
{
	std.file.write(target, data);
}

// Work around for https://github.com/D-Programming-Language/phobos/pull/2784#issuecomment-68117241
private void copy2(string source, string target) { std.file.copy(source, target); }

/// Copy a file, or replace an existing file's contents
/// with another file's, atomically.
alias atomic!copy2 atomicCopy;

unittest
{
	enum fn = "cached.tmp";
	scope(exit) if (fn.exists) fn.remove();

	cached!touch(fn);
	assert(fn.exists);

	std.file.write(fn, "test");

	cachedDg!0(&_writeProxy, fn, "test2");
	assert(fn.readText() == "test");
}

// ****************************************************************************

/// Composes a function which generates a file name
/// with a function which creates the file.
/// Returns the file name.
template withTarget(alias targetGen, alias fun)
{
	auto withTarget(Args...)(auto ref Args args)
	{
		auto target = targetGen(args);
		fun(args, target);
		return target;
	}
}

/// Two-argument buildPath with reversed arguments.
/// Useful for UFCS chaining.
string prependPath(string target, string path)
{
	return buildPath(path, target);
}
