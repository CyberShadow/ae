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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.path;

import std.path;

/// Modify a path under oldBase to a new path with the same subpath under newBase.
/// E.g.: `/foo/bar`.rebasePath(`/foo`, `/quux`) == `/quux/bar`
string rebasePath(string path, string oldBase, string newBase)
{
	return buildPath(newBase, path.absolutePath.relativePath(oldBase.absolutePath));
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

// ************************************************************************

/// The file name for the null device
/// (which discards all writes).
version (Windows)
	enum nullFileName = "nul";
else
	enum nullFileName = "/dev/null";
