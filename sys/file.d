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

alias wcscmp = core.stdc.wchar_.wcscmp;
alias wcslen = core.stdc.wchar_.wcslen;

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
						if (fdata.d_type & DT_LNK)
							continue;
					}

					size_t len = core.stdc.string.strlen(fdata.d_name.ptr);
					string name = fdata.d_name[0 .. len].idup;
					if (pattern && !globMatch(name, pattern))
						continue;
					string path = buildPath(pathname, name);

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

/// Make sure that the path exists (and create directories as necessary).
void ensurePathExists(string fn)
{
	auto path = dirName(fn);
	if (!exists(path))
		mkdirRecurse(path);
}

import ae.utils.text;

/// Forcibly remove a file or directory.
/// If atomic is true, the entire directory is deleted "atomically"
/// (it is first moved/renamed to another location).
/// On Windows, this will move the file/directory out of the way,
/// if it is in use and cannot be deleted (but can be renamed).
void forceDelete(bool atomic=true)(string fn, bool recursive = false)
{
	import std.process : environment;
	version(Windows)
	{
		import win32.winnt;
		import win32.winbase;
		import ae.sys.windows;
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
			if (target.endsWith(`\`))
				target = target[0..$-1];
			if (target.length && !target.exists)
				return false;

			string newfn;
			do
				newfn = format("%s\\deleted-%s.%s.%s", target, name, thisProcessID, randomString());
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
					forceDelete!false(de.name, true);
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

/// If fn is a directory, delete it recursively.
/// Otherwise, delete the file fn.
void removeRecurse(string fn)
{
	if (fn.isDir)
		fn.rmdirRecurse();
	else
		fn.remove();
}

/// Create an empty directory, deleting
/// all its contents if it already exists.
void recreateEmptyDirectory()(string dir)
{
	if (dir.exists)
		dir.forceDelete(true);
	mkdir(dir);
}

bool isHidden()(string fn)
{
	if (baseName(fn).startsWith("."))
		return true;
	version (Windows)
	{
		import win32.winnt;
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
		import win32.winnt;
		import win32.winbase;

		import ae.sys.windows;

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
	void createReparsePoint(string reparseBufferName, string extraInitialization, string reparseTagName)(in char[] target, in char[] print, in char[] link)
	{
		import win32.winbase;
		import win32.windef;
		import win32.winioctl;

		import ae.sys.windows;

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
		import win32.winbase;
		import win32.windef;

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
		import win32.winnt;

		acquirePrivilege(SE_CREATE_SYMBOLIC_LINK_NAME);

		touch(link);
		scope(failure) remove(link);

		createReparsePoint!(q{SymbolicLinkReparseBuffer}, q{r.SymbolicLinkReparseBuffer.Flags = link.isAbsolute() ? 0 : SYMLINK_FLAG_RELATIVE;}, q{IO_REPARSE_TAG_SYMLINK})(original, original, link);
	}
}
else
	alias std.file.symlink dirLink;

version (unittest) version(Windows) static import ae.sys.windows;

unittest
{
	mkdir("a"); scope(exit) rmdir("a");
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
		import win32.w32api;

		static assert(_WIN32_WINNT >= 0x501, "CreateHardLinkW not available for target Windows platform. Specify -version=WindowsXP");

		import win32.winnt;
		import win32.winbase;

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

version (Windows)
{
	/// Enumerate all hard links to the specified file.
	string[] enumerateHardLinks()(string fn)
	{
		import win32.winnt;
		import win32.winbase;
		import ae.sys.windows;

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

version(Windows)
unittest
{
	touch("a.test");
	scope(exit) remove("a.test");
	hardLink("a.test", "b.test");
	scope(exit) remove("b.test");

	auto paths = enumerateHardLinks("a.test");
	assert(paths.length == 2);
	paths.sort();
	assert(paths[0].endsWith(`\a.test`), paths[0]);
	assert(paths[1].endsWith(`\b.test`));
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

ubyte[16] mdFile()(string fn)
{
	import std.digest.md;

	MD5 context;
	context.start();

	auto f = openFile(fn, "rb");
	static ubyte[64 * 1024] buffer = void;
	while (true)
	{
		auto readBuffer = f.rawRead(buffer);
		if (!readBuffer.length)
			break;
		context.put(cast(ubyte[])readBuffer);
	}
	f.close();

	ubyte[16] digest = context.finish();
	return digest;
}

/// Read a File (which might be a stream) into an array
void[] readFile(File f)
{
	ubyte[] result;
	static ubyte[64 * 1024] buffer = void;
	while (true)
	{
		auto readBuffer = f.rawRead(buffer);
		if (!readBuffer.length)
			break;
		result ~= readBuffer;
	}
	return result;
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
		import win32.windows;
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
/// or its contents differs).
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
			import win32.winbase;

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
			import win32.winbase;

			ConnectNamedPipe(f.windowsHandle, null).wenforce("ConnectNamedPipe");
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
	auto temp = "%s.%s.temp".format(target, thisProcessID);
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
alias atomic!(std.file.write) atomicWrite;
deprecated alias safeWrite = atomicWrite;

/// Copy a file, or replace an existing file's contents
/// with another file's, atomically.
alias atomic!(std.file.copy) atomicCopy;

unittest
{
	enum fn = "cached.tmp";
	scope(exit) if (fn.exists) fn.remove();

	cached!touch(fn);
	assert(fn.exists);

	std.file.write(fn, "test");

	cachedDg!0(&std.file.write, fn, "test2");
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
