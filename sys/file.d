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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.file;

import core.stdc.wchar_;
import core.thread;

import std.array;
import std.conv;
import std.file;
import std.path;
import std.stdio : File;
import std.string;
import std.typecons;
import std.utf;

import ae.sys.cmd : getCurrentThreadID;
import ae.utils.path;

public import std.typecons : No, Yes;

alias wcscmp = core.stdc.wchar_.wcscmp;
alias wcslen = core.stdc.wchar_.wcslen;

version(Windows) import ae.sys.windows.imports;

// ************************************************************************

version (Windows)
{
	// Work around std.file overload
	mixin(importWin32!(q{winnt}, null, q{FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT}));
}

// ************************************************************************

version(Windows)
{
	string[] fastListDir(bool recursive = false, bool symlinks=false)(string pathname, string pattern = null)
	{
		import core.sys.windows.windows;

		static if (recursive)
			enforce(!pattern, "TODO: recursive fastListDir with pattern");

		string[] result;
		string c;
		HANDLE h;

		c = buildPath(pathname, pattern ? pattern : "*.*");
		WIN32_FIND_DATAW fileinfo;

		h = FindFirstFileW(toUTF16z(c), &fileinfo);
		if (h != INVALID_HANDLE_VALUE)
		{
			scope(exit) FindClose(h);

			do
			{
				// Skip "." and ".."
				if (wcscmp(fileinfo.cFileName.ptr, ".") == 0 ||
					wcscmp(fileinfo.cFileName.ptr, "..") == 0)
					continue;

				static if (!symlinks)
				{
					if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
						continue;
				}

				size_t clength = wcslen(fileinfo.cFileName.ptr);
				string name = std.utf.toUTF8(fileinfo.cFileName[0 .. clength]);
				string path = buildPath(pathname, name);

				static if (recursive)
				{
					if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
					{
						result ~= fastListDir!recursive(path);
						continue;
					}
				}

				result ~= path;
			} while (FindNextFileW(h,&fileinfo) != FALSE);
		}
		return result;
	}
}
else
version (Posix)
{
	private import core.stdc.errno;
	private import core.sys.posix.dirent;
	private import core.stdc.string;

	string[] fastListDir(bool recursive=false, bool symlinks=false)(string pathname, string pattern = null)
	{
		string[] result;
		DIR* h;
		dirent* fdata;

		h = opendir(toStringz(pathname));
		if (h)
		{
			try
			{
				while((fdata = readdir(h)) != null)
				{
					// Skip "." and ".."
					if (!core.stdc.string.strcmp(fdata.d_name.ptr, ".") ||
						!core.stdc.string.strcmp(fdata.d_name.ptr, ".."))
							continue;

					static if (!symlinks)
					{
						if (fdata.d_type == DT_LNK)
							continue;
					}

					size_t len = core.stdc.string.strlen(fdata.d_name.ptr);
					string name = fdata.d_name[0 .. len].idup;
					if (pattern && !globMatch(name, pattern))
						continue;
					string path = pathname ~ (pathname.length && pathname[$-1] != '/' ? "/" : "") ~ name;

					static if (recursive)
					{
						if (fdata.d_type & DT_DIR)
						{
							result ~= fastListDir!(recursive, symlinks)(path);
							continue;
						}
					}

					result ~= path;
				}
			}
			finally
			{
				closedir(h);
			}
		}
		else
		{
			throw new std.file.FileException(pathname, errno);
		}
		return result;
	}
}
else
	static assert(0, "TODO");

// ************************************************************************

/// The OS's "native" filesystem character type (private in Phobos).
version (Windows)
	alias FSChar = wchar;
else version (Posix)
	alias FSChar = char;
else
	static assert(0);

/// Reads a time field from a stat_t with full precision (private in Phobos).
version (Posix)
SysTime statTimeToStdTime(char which)(ref const stat_t statbuf)
{
	auto unixTime = mixin(`statbuf.st_` ~ which ~ `time`);
	long stdTime = unixTimeToStdTime(unixTime);

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

private
version (Posix)
{
	extern (C)
	{
		int dirfd(DIR *dirp) pure nothrow @nogc;
		int openat(int fd, const char *path, int oflag, ...) nothrow @nogc;
		DIR *fdopendir(int fd) nothrow @nogc;
		int fstatat(int fd, const(char)* path, stat_t* buf, int flag) nothrow @nogc;
	}
	version (linux)
	{
		enum AT_SYMLINK_NOFOLLOW = 0x100;
	}
}

/// Fast templated directory iterator
template listDir(alias handler)
{
	// Tether to handler alias context
	/*non-static*/ struct HandlerPtr
	{
		void callHandler(Entry* e) { handler(e); }
	}

	static struct Entry
	{
		Entry* parent;
		dirent* ent;

		// Cleared (memset to 0) for every directory entry.
		struct Data
		{
			FSChar[] baseNameFS;
			string baseName;
			string fullName;
			StatResult[enumLength!StatTarget] statResult;
		}
		Data data;

		stat_t[enumLength!StatTarget] statBuf;
		enum StatResult : int
		{
			noInfo = 0,
			statOK = int.max,
			unknownError = int.min,
			// other values are the same as errno
		}

		// Recursion

		HandlerPtr handlerPtr;
		int dirFD;

		void recurse()
		{
			int flags = O_RDONLY;
			version(linux) enum O_DIRECTORY = 0x10000;
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

		// Name

		const(FSChar)* baseNameFSPtr() pure nothrow @nogc // fastest
		{
			return ent.d_name.ptr;
		}

		const(FSChar)[] baseNameFS() pure nothrow @nogc // fast
		{
			if (!data.baseNameFS)
			{
				size_t len = core.stdc.string.strlen(ent.d_name.ptr);
				data.baseNameFS = ent.d_name[0 .. len];
			}
			return data.baseNameFS;
		}

		string baseName() // allocates
		{
			if (!data.baseName)
				data.baseName = baseNameFS.to!string;
			return data.baseName;
		}

		string fullName() // allocates
		{
			if (!data.fullName)
			{
				auto parentName = parent.fullName;
				data.fullName = text(
					parentName,
					!parentName.length || isDirSeparator(parentName[$-1]) ? "" : dirSeparator,
					baseNameFS);
			}
			return data.fullName;
		}

		// Attributes

		enum StatTarget
		{
			dirEntry,   // do not dereference (lstat)
			linkTarget, // dereference
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

		ErrnoException statError(StatTarget target)()
		{
			errno = data.statResult[target];
			return new ErrnoException("Failed to stat " ~
				(target == StatTarget.linkTarget ? "link target" : "directory entry") ~
				": " ~ fullName);
		}

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

		@property uint attributes()
		{
			return needStat!(StatTarget.linkTarget)().st_mode;
		}

		@property uint linkAttributes()
		{
			return needStat!(StatTarget.dirEntry)().st_mode;
		}

		// Other attributes

		@property SysTime timeStatusChanged()
		{
			return statTimeToStdTime!'c'(*needStat!(StatTarget.linkTarget)());
		}

		@property SysTime timeLastAccessed()
		{
			return statTimeToStdTime!'a'(*needStat!(StatTarget.linkTarget)());
		}

		@property SysTime timeLastModified()
		{
			return statTimeToStdTime!'m'(*needStat!(StatTarget.linkTarget)());
		}

		@property ulong size()
		{
			return needStat!(StatTarget.linkTarget)().st_size;
		}

		@property ulong fileID()
		{
			return needStat!(StatTarget.linkTarget)().st_ino;
		}
	}

	import core.sys.posix.fcntl;

	static void scan(DIR* dir, int dirFD, Entry* parentEntry)
	{
		Entry entry = void;
		entry.parent = parentEntry;
		entry.handlerPtr = entry.parent.handlerPtr;
		entry.dirFD = dirFD;

		scope(exit) closedir(dir);

		dirent* ent;
		while ((ent = readdir(dir)) != null)
		{
			// Skip "." and ".."
			if (ent.d_name[0] == '.' && (
					ent.d_name[1] == 0 ||
					(ent.d_name[1] == '.' && ent.d_name[2] == 0)))
				continue;

			entry.ent = ent;
			entry.data = Entry.Data.init;
			entry.handlerPtr.callHandler(&entry);
		}
	}

	void listDir(string dirPath)
	{
		import std.internal.cstring;

		auto dir = opendir(tempCString(dirPath));
		errnoEnforce(dir, "Failed to open directory " ~ dirPath);

		Entry rootEntry = void;
		rootEntry.parent = null;
		rootEntry.handlerPtr = HandlerPtr();
		rootEntry.data.fullName = dirPath;

		scan(dir, dirfd(dir), &rootEntry);
	}
}

unittest
{
	auto tmpDir = deleteme;
	mkdirRecurse(deleteme);
	scope(exit) rmdirRecurse(deleteme);

	touch(deleteme ~ "/a");
	touch(deleteme ~ "/b");
	mkdir(deleteme ~ "/c");
	touch(deleteme ~ "/c/1");
	touch(deleteme ~ "/c/2");
	dirLink("c", deleteme ~ "/d");
	dirLink("x", deleteme ~ "/e");

	string[] entries;
	listDir!((e) {
		entries ~= e.fullName.fastRelativePath(deleteme);
		if (e.entryIsDir)
			e.recurse();
	})(deleteme);

	assert(equal(
		entries.sort,
		["a", "b", "c", "c/1", "c/2", "d", "e"].map!(name => name.replace("/", dirSeparator)),
	));
}

// ************************************************************************

string buildPath2(string[] segments...) { return segments.length ? buildPath(segments) : null; }

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
string[] fastFileList(string pattern)
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
string[] fastFileList(string pattern0, string[] patterns...)
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

	int getOwner(string fn)
	{
		stat_t s;
		errnoEnforce(stat(toStringz(fn), &s) == 0, "stat: " ~ fn);
		return s.st_uid;
	}

	int getGroup(string fn)
	{
		stat_t s;
		errnoEnforce(stat(toStringz(fn), &s) == 0, "stat: " ~ fn);
		return s.st_gid;
	}

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
void copyRecurse(string src, string dst) { copyRecurse(DirEntry(src), dst); }

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
	touch("a");
	scope(exit) remove("a");
	hardLink("a", "b");
	scope(exit) remove("b");
	touch("c");
	scope(exit) remove("c");
	assert(getFileID("a") == getFileID("b"));
	assert(getFileID("a") != getFileID("c"));
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

	void createReparsePoint(string reparseBufferName, string extraInitialization, string reparseTagName)(in char[] target, in char[] print, in char[] link)
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

		auto target = `\??\` ~ original.idup.absolutePath();
		if (target[$-1] != '\\')
			target ~= '\\';

		createReparsePoint!(q{MountPointReparseBuffer}, q{}, q{IO_REPARSE_TAG_MOUNT_POINT})(target, null, link);
	}

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
	alias std.file.symlink dirLink;

version(Windows) version(unittest) static mixin(importWin32!q{winnt});

unittest
{
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
	void hardLink()(string src, string dst)
	{
		mixin(importWin32!q{w32api});

		static assert(_WIN32_WINNT >= 0x501, "CreateHardLinkW not available for target Windows platform. Specify -version=WindowsXP");

		mixin(importWin32!q{winnt});
		mixin(importWin32!q{winbase});

		wenforce(CreateHardLinkW(toUTF16z(dst), toUTF16z(src), null), "CreateHardLink failed: " ~ src ~ " -> " ~ dst);
	}
}
version (Posix)
{
	void hardLink()(string src, string dst)
	{
		import core.sys.posix.unistd;
		enforce(link(toUTFz!(const char*)(src), toUTFz!(const char*)(dst)) == 0, "link() failed: " ~ dst);
	}
}

version (Posix)
{
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
	struct MountInfo
	{
		string spec; /// device path
		string file; /// mount path
		string vfstype; /// file system
		string mntops; /// options
		int freq; /// dump flag
		int passno; /// fsck order
	}

	string unescapeMountString(in char[] s)
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
	alias ENOATTR = ENODATA;

	/// AA-like object for accessing a file's extended attributes.
	struct XAttrs(Obj, string funPrefix)
	{
		Obj obj;

		mixin("alias getFun = " ~ funPrefix ~ "getxattr;");
		mixin("alias setFun = " ~ funPrefix ~ "setxattr;");
		mixin("alias removeFun = " ~ funPrefix ~ "removexattr;");
		mixin("alias listFun = " ~ funPrefix ~ "listxattr;");

		bool supported()
		{
			auto size = getFun(obj, "user.\x01", null, 0);
			return size >= 0 || errno != EOPNOTSUPP;
		}

		void[] opIndex(string key)
		{
			auto cKey = key.toStringz();
			auto size = getFun(obj, cKey, null, 0);
			errnoEnforce(size >= 0);
			auto result = new void[size];
			// TODO: race condition, retry
			size = getFun(obj, cKey, result.ptr, result.length);
			errnoEnforce(size == result.length);
			return result;
		}

		bool opIn_r(string key)
		{
			auto cKey = key.toStringz();
			auto size = getFun(obj, cKey, null, 0);
			if (size >= 0)
				return true;
			else
			if (errno == ENOATTR)
				return false;
			else
				errnoEnforce(false, "Error reading file xattrs");
			assert(false);
		}

		void opIndexAssign(in void[] value, string key)
		{
			auto ret = setFun(obj, key.toStringz(), value.ptr, value.length, 0);
			errnoEnforce(ret == 0);
		}

		void remove(string key)
		{
			auto ret = removeFun(obj, key.toStringz());
			errnoEnforce(ret == 0);
		}

		string[] keys()
		{
			auto size = listFun(obj, null, 0);
			errnoEnforce(size >= 0);
			auto buf = new char[size];
			// TODO: race condition, retry
			size = listFun(obj, buf.ptr, buf.length);
			errnoEnforce(size == buf.length);

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

	auto xAttrs(string path)
	{
		return XAttrs!(const(char)*, "")(path.toStringz());
	}

	auto linkXAttrs(string path)
	{
		return XAttrs!(const(char)*, "l")(path.toStringz());
	}

	auto xAttrs(in ref File f)
	{
		return XAttrs!(int, "f")(f.fileno);
	}

	unittest
	{
		if (!xAttrs(".").supported)
		{
			import std.stdio;
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

void toFile(in void[] data, in char[] name)
{
	std.file.write(name, data);
}

/// Uses UNC paths to open a file.
/// Requires https://github.com/D-Programming-Language/phobos/pull/1888
File openFile()(string fn, string mode = "rb")
{
	File f;
	static if (is(typeof(&f.windowsHandleOpen)))
	{
		import core.sys.windows.windows;
		import ae.sys.windows.exception;

		string winMode;
		foreach (c; mode)
			switch (c)
			{
				case 'r':
				case 'w':
				case 'a':
				case '+':
					winMode ~= c;
					break;
				case 'b':
				case 't':
					break;
				default:
					assert(false, "Unknown character in mode");
			}
		DWORD access, creation;
		bool append;
		switch (winMode)
		{
			case "r" : access = GENERIC_READ                ; creation = OPEN_EXISTING; break;
			case "r+": access = GENERIC_READ | GENERIC_WRITE; creation = OPEN_EXISTING; break;
			case "w" : access =                GENERIC_WRITE; creation = OPEN_ALWAYS  ; break;
			case "w+": access = GENERIC_READ | GENERIC_WRITE; creation = OPEN_ALWAYS  ; break;
			case "a" : access =                GENERIC_WRITE; creation = OPEN_ALWAYS  ; append = true; break;
			case "a+": assert(false, "Not implemented"); // requires two file pointers
			default: assert(false, "Bad file mode: " ~ mode);
		}

		auto pathW = toUTF16z(longPath(fn));
		auto h = CreateFileW(pathW, access, FILE_SHARE_READ, null, creation, 0, HANDLE.init);
		wenforce(h != INVALID_HANDLE_VALUE);

		if (append)
			h.SetFilePointer(0, null, FILE_END);

		f.windowsHandleOpen(h, mode);
	}
	else
		f.open(fn, mode);
	return f;
}

auto fileDigest(Digest)(string fn)
{
	import std.range.primitives;
	Digest context;
	context.start();
	put(context, openFile(fn, "rb").byChunk(64 * 1024));
	auto digest = context.finish();
	return digest;
}

template mdFile()
{
	import std.digest.md;
	alias mdFile = fileDigest!MD5;
}

version (HAVE_WIN32)
unittest
{
	import std.digest.digest : toHexString;
	write("test.txt", "Hello, world!");
	scope(exit) remove("test.txt");
	assert(mdFile("test.txt").toHexString() == "6CD3556DEB0DA54BCA060B4C39479839");
}

auto fileDigestCached(Digest)(string fn)
{
	static typeof(Digest.init.finish())[ulong] cache;
	auto id = getFileID(fn);
	auto phash = id in cache;
	if (phash)
		return *phash;
	return cache[id] = fileDigest!Digest(fn);
}

template mdFileCached()
{
	import std.digest.md;
	alias mdFileCached = fileDigestCached!MD5;
}

version (HAVE_WIN32)
unittest
{
	import std.digest.digest : toHexString;
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

struct NamedPipeImpl
{
	immutable string fileName;

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
alias NamedPipe = RefCounted!NamedPipeImpl;

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
alias atomic!writeProxy atomicWrite;
deprecated alias safeWrite = atomicWrite;
void writeProxy(string target, in void[] data)
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

	cachedDg!0(&writeProxy, fn, "test2");
	assert(fn.readText() == "test");
}

// ****************************************************************************

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
