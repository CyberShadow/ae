/**
 * ae.sys.archive
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

module ae.sys.archive;

import std.exception;
import std.file;
import std.path;
import std.process;
import std.string;

import ae.sys.file;
import ae.sys.install.sevenzip;

/// Unzips a .zip file to the target directory.
void unzip(string zip, string target)
{
	import std.zip;
	auto archive = new ZipArchive(zip.read);
	foreach (name, entry; archive.directory)
	{
		auto path = buildPath(target, name);
		ensurePathExists(path);
		if (name.endsWith(`/`))
		{
			if (!path.exists)
				path.mkdirRecurse();
		}
		else
			std.file.write(path, archive.expand(entry));
	}
}

/// Unpacks an archive to the specified directory.
/// Uses std.zip for .zip files, and invokes 7-Zip for
/// other file types (installing it locally if necessary).
void unpack(string archive, string target)
{
	if (archive.toLower().endsWith(".zip"))
		archive.unzip(target);
	else
	{
		sevenZip.require();
		target.mkdirRecurse();
		auto pid = spawnProcess([sevenZip.exe, "x", "-o" ~ target, archive]);
		enforce(pid.wait() == 0, "Extraction failed");
	}
}

/// Unpacks archive to a directory in targetDirectory.
/// Skips unpacking if the target already exists.
string unpackTo(string archive, string targetDirectory)
{
	auto target = buildPath(targetDirectory, archive.stripExtension());
	enforce(target != archive);
	cached!unpack(archive, target);
	return target;
}
