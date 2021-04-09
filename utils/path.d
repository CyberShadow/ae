/**
 * ae.utils.path
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

module ae.utils.path;

import std.algorithm.searching;
import std.path;

/// Modify a path under oldBase to a new path with the same subpath under newBase.
/// E.g.: `/foo/bar`.rebasePath(`/foo`, `/quux`) == `/quux/bar`
string rebasePath(string path, string oldBase, string newBase)
{
	return buildPath(newBase, path.relPath(oldBase));
}

/// Variant of std.path.relativePath with the following differences:
/// - Works with relative paths.
///   If either path is relative, it is first resolved to an absolute path.
/// - If `path` starts with `base`, avoids allocating.
string relPath(string path, string base)
{
	if (base.length && path.length > base.length &&
		path[0..base.length] == base)
	{
		if (base[$-1].isDirSeparator)
			return path[base.length..$];
		if (path[base.length].isDirSeparator)
			return path[base.length+1..$];
	}
	return relativePath(path.absolutePath, base.absolutePath);
}

deprecated alias fastRelativePath = relPath;

unittest
{
	version(Windows)
	{
		assert(relPath(`C:\a\b\c`, `C:\a`) == `b\c`);
		assert(relPath(`C:\a\b\c`, `C:\a\`) == `b\c`);
		assert(relPath(`C:\a\b\c`, `C:\a/`) == `b\c`);
		assert(relPath(`C:\a\b\c`, `C:\a\d`) == `..\b\c`);
	}
	else
	{
		assert(relPath("/a/b/c", "/a") == "b/c");
		assert(relPath("/a/b/c", "/a/") == "b/c");
		assert(relPath("/a/b/c", "/a/d") == "../b/c");
	}
}

/// Like Pascal's IncludeTrailingPathDelimiter
string includeTrailingPathSeparator(string path)
{
	if (path.length && !path[$-1].isDirSeparator())
		path ~= dirSeparator;
	return path;
}

/// Like Pascal's ExcludeTrailingPathDelimiter
string excludeTrailingPathSeparator(string path)
{
	if (path.length && path[$-1].isDirSeparator())
		path = path[0..$-1];
	return path;
}

/// Like startsWith, but pathStartsWith("/foo/barbara", "/foo/bar") is false.
bool pathStartsWith(in char[] path, in char[] prefix)
{
	// Special cases to accommodate relativePath(path, path) results
	if (prefix == "" || prefix == ".")
		return true;

	return path.startsWith(prefix) &&
		(path.length == prefix.length || isDirSeparator(path[prefix.length]));
}

unittest
{
	assert( "/foo/bar"    .pathStartsWith("/foo/bar"));
	assert( "/foo/bar/baz".pathStartsWith("/foo/bar"));
	assert(!"/foo/barbara".pathStartsWith("/foo/bar"));
	assert( "/foo/bar"    .pathStartsWith(""));
	assert( "/foo/bar"    .pathStartsWith("."));
}

// ************************************************************************

import std.process : environment;
import std.string : split;

/// Return the PATH environment variable, split into individual paths.
@property string[] pathDirs()
{
	return environment["PATH"].split(pathSeparator);
}

/// Returns `true` if a program with the given name can be found in PATH.
bool haveExecutable(string name)
{
	return findExecutable(name, pathDirs) !is null;
}

/// Find an executable with the given name
/// (no extension) in the given directories.
/// Returns null if not found.
string findExecutable(string name, string[] dirs)
{
	import std.file : exists;

	version (Windows)
		enum executableSuffixes = [".exe", ".bat", ".cmd"];
	else
		enum executableSuffixes = [""];

	foreach (dir; dirs)
		foreach (suffix; executableSuffixes)
		{
			version (Posix)
				if (dir == "")
					dir = ".";
			auto fn = buildPath(dir, name) ~ suffix;
			if (fn.exists)
				return fn;
		}

	return null;
}

// ************************************************************************

/**
   Find a program's "home" directory, based on the presence of a file.

   This can be a directory containing files that are included with or
   created by the program, and should be accessible no matter how the
   program is built/invoked of which current directory it is invoked
   from.

   Use a set of individually-unreliable methods to find the path. This
   is necessary, because:

   - __FILE__ by itself is insufficient, because it may not be an
     absolute path, and the compiled binary may have been moved after
     being built;

   - The executable's directory by itself is insufficient, because
     build tools such as rdmd can place it in a temporary directory;

   - The current directory by itself is insufficient, because the
     program can be launched in more than one way, e.g.:

     - Running the program from the same directory as the source file
       containing main() (e.g. rdmd program.d)

     - Running the program from the upper directory containing all
       packages and dependencies, so that there is no need to specify
       include dirs (e.g. rdmd ae/demo/http/httpserve.d)

     - Running the program from a cronjob or another location, in
       which the current directory can be unrelated altogether.

    Params:
      testFile = Relative path to a file or directory, the presence of
                 which indicates that the "current" directory (base of
                 the relative path) is the sought-after program root
                 directory.
      sourceFile = Path to a source file part of the program's code
                   base. Defaults to the __FILE__ of the caller.

    Returns:
      Path to the sought root directory, or `null` if one was not found.
*/
string findProgramDirectory(string testFile, string sourceFile = __FILE__)
{
	import std.file : thisExePath, getcwd, exists;
	import core.runtime : Runtime;
	import std.range : only;

	foreach (path; only(Runtime.args[0].absolutePath().dirName(), thisExePath.dirName, sourceFile.dirName, null))
	{
		path = path.absolutePath().buildNormalizedPath();
		while (true)
		{
			auto indicator = path.buildPath(testFile);
			if (indicator.exists)
				return path;
			auto parent = dirName(path);
			if (parent == path)
				break;
			path = parent;
		}
	}
	return null;
}

// ************************************************************************

/// The file name for the null device
/// (which discards all writes).
version (Windows)
	enum nullFileName = "nul";
else
	enum nullFileName = "/dev/null";
