/**
 * A basic virtual filesystem API.
 * Intended as a drop-in std.file replacement.
 * VFS driver is indicated by "driver://" prefix
 * ("//" cannot exist in a valid filesystem path).
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

module ae.sys.vfs;

// User interface:

/// Read entire file at given location.
void[] read(string path) { return getVFS(path).read(path); }

/// Write entire file at given location (overwrite if exists).
void write(string path, const(void)[] data) { return getVFS(path).write(path, data); }

/// Check if file/directory exists at location.
@property bool exists(string path) { return getVFS(path).exists(path); }

/// Delete file at location.
void remove(string path) { return getVFS(path).remove(path); }

/// Create directory ( and parents as necessary) at location, if it does not exist.
void mkdirRecurse(string path) { return getVFS(path).mkdirRecurse(path); }

/// Rename file at location. Clobber destination, if it exists.
void rename(string from, string to)
{
	if (getVFSName(from) == getVFSName(to))
		return getVFS(from).rename(from, to);
	else
		throw new Exception("Cannot rename across VFS");
}

/// Get MD5 digest of file at location.
ubyte[16] mdFile(string path) { return getVFS(path).mdFile(path); }

/// std.file shims
S readText(S = string)(string name)
{
    auto result = cast(S) read(name);
    import std.utf;
    validate(result);
    return result;
}

/// ditto
void copy(string from, string to)
{
	if (getVFSName(from) == getVFSName(to))
		getVFS(from).copy(from, to);
	else
		write(to, read(from));
}

/// ae.sys.file shims
void move(string src, string dst)
{
	try
		src.rename(dst);
	catch (Exception e)
	{
		auto tmp = dst ~ ".ae-tmp";
		if (tmp.exists) tmp.remove();
		scope(exit) if (tmp.exists) tmp.remove();
		src.copy(tmp);
		tmp.rename(dst);
		src.remove();
	}
}

/// ditto
void ensurePathExists(string fn)
{
	import std.path;
	auto path = dirName(fn);
	if (!exists(path))
		mkdirRecurse(path);
}

/// ditto
void safeWrite(string fn, in void[] data)
{
	auto tmp = fn ~ ".ae-tmp";
	write(tmp, data);
	if (fn.exists) fn.remove();
	tmp.rename(fn);
}

/// ditto
void touch(string path)
{
	if (!getVFSName(path))
		return ae.sys.file.touch(path);
	else
		safeWrite(path, read(path));
}


// Implementer interface:

/// Abstract VFS driver base class.
class VFS
{
	/// Read entire file at given location.
	abstract void[] read(string path);

	/// Write entire file at given location (overwrite if exists).
	abstract void write(string path, const(void)[] data);

	/// Check if file/directory exists at location.
	abstract bool exists(string path);

	/// Delete file at location.
	abstract void remove(string path);

	/// Copy file from one location to another (same VFS driver).
	void copy(string from, string to) { write(to, read(from)); }

	/// Rename file at location. Clobber destination, if it exists.
	void rename(string from, string to) { copy(from, to); remove(from); }

	/// Create directory (and parents as necessary) at location, if it does not exist.
	abstract void mkdirRecurse(string path);

	/// Get MD5 digest of file at location.
	ubyte[16] mdFile(string path) { import std.digest.md; return md5Of(read(path)); }
}

VFS[string] registry;

/// Test a VFS at a certain path. Must end with directory separator.
void testVFS(string base)
{
	import std.exception;

	auto testPath0 = base ~ "ae-test0.txt";
	auto testPath1 = base ~ "ae-test1.txt";

	scope(exit) if (testPath0.exists) testPath0.remove();
	scope(exit) if (testPath1.exists) testPath1.remove();

	write(testPath0, "Hello");
	assert(testPath0.exists);
	assert(readText(testPath0) == "Hello");

	copy(testPath0, testPath1);
	assert(testPath1.exists);
	assert(readText(testPath1) == "Hello");

	remove(testPath0);
	assert(!testPath0.exists);
	assertThrown(testPath0.readText());

	rename(testPath1, testPath0);
	assert(testPath0.exists);
	assert(readText(testPath0) == "Hello");
	assert(!testPath1.exists);
	assertThrown(testPath1.readText());
}

// Other:

bool isVFSPath(string path)
{
	import ae.utils.text;
	return path.contains("://");
}

string getVFSName(string path)
{
	import std.string;
	auto index = indexOf(path, "://");
	return index > 0 ? path[0..index] : null;
}

VFS getVFS(string path)
{
	auto vfsName = getVFSName(path);
	auto pvfs = vfsName in registry;
	assert(pvfs, "Unknown VFS: " ~ vfsName);
	return *pvfs;
}

private:

static import std.file, ae.sys.file;

/////////////////////////////////////////////////////////////////////////////

/// Pass-thru native filesystem driver.
class FS : VFS
{
	override void[] read(string path) { return std.file.read(path); }
	override void write(string path, const(void)[] data) { return std.file.write(path, data); }
	override bool exists(string path) { return std.file.exists(path); }
	override void remove(string path) { return std.file.remove(path); }
	override void copy(string from, string to) { std.file.copy(from, to); }
	override void rename(string from, string to) { std.file.rename(from, to); }
	override void mkdirRecurse(string path) { std.file.mkdirRecurse(path); }
	override ubyte[16] mdFile(string path) { return ae.sys.file.mdFile(path); }

	static this()
	{
		registry[null] = new FS();
	}
}

unittest
{
	testVFS("");
}
