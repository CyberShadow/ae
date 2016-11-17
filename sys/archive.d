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

import std.array;
import std.datetime;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.string;

import ae.sys.file;
import ae.sys.install.sevenzip;
import ae.utils.path : haveExecutable;

/// Unzips a .zip file to the target directory.
void unzip(string zip, string target)
{
	import std.zip;
	auto archive = new ZipArchive(zip.read);
	foreach (name, entry; archive.directory)
	{
		auto path = buildPath(target, name).replace("\\", "/");
		ensurePathExists(path);
		if (name.endsWith(`/`))
		{
			if (!path.exists)
				path.mkdirRecurse();
		}
		else
			std.file.write(path, archive.expand(entry));

		auto attr = entry.fileAttributes;
		if (attr)
			path.setAttributes(attr);

		auto time = entry.time().DosFileTimeToSysTime(UTC());
		path.setTimes(time, time);
	}
}

/// Unpacks a file with 7-Zip to the specified directory,
/// installing it locally if necessary.
void un7z(string archive, string target)
{
	sevenZip.require();
	target.mkdirRecurse();
	auto pid = spawnProcess([sevenZip.exe, "x", "-o" ~ target, archive]);
	enforce(pid.wait() == 0, "Extraction failed");
}

/// Unpacks an archive to the specified directory.
/// Uses std.zip for .zip files, and invokes tar (if available)
/// or 7-Zip (installing it locally if necessary) for other file types.
/// Always unpacks compressed tar archives in one go.
void unpack(string archive, string target)
{
	bool untar(string longExtension, string shortExtension, string tarSwitch, string unpacker)
	{
		if ((archive.toLower().endsWith(longExtension) || archive.toLower().endsWith(shortExtension)) && haveExecutable(unpacker))
		{
			target.mkdirRecurse();
			auto pid = spawnProcess(["tar", "xf", archive, tarSwitch, "--directory", target]);
			enforce(pid.wait() == 0, "Extraction failed");
			return true;
		}
		return false;
	}

	if (archive.toLower().endsWith(".zip"))
		archive.unzip(target);
	else
	if (haveExecutable("tar") && (
		untar(".tar.gz", ".tgz", "--gzip", "gzip") ||
		untar(".tar.bz2", ".tbz", "--bzip2", "bzip2") ||
		untar(".tar.lzma", ".tlz", "--lzma", "lzma") ||
		untar(".tar.xz", ".txz", "--xz", "xz")))
		{}
	else
	{
		auto tar = archive.stripExtension;
		if (tar.extension.toLower == ".tar")
		{
			un7z(archive, archive.dirName);
			enforce(tar.exists, "Expected to unpack " ~ archive ~ " to " ~ tar);
			scope(exit) tar.remove();
			un7z(tar, target);
		}
		else
			un7z(archive, target);
	}
}
