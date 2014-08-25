/**
 * DigitalMars C++ installer
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

module ae.sys.install.dmc;

version(Windows):

import std.array;
import std.exception;
import std.file;
import std.path;

import ae.sys.archive;
import ae.sys.file;
import ae.sys.net;
import ae.utils.meta.misc;

public import ae.sys.install.common;

class DMC : Installer
{
	@property override string name() { return "DigitalMars C++"; }
	@property override string subdirectory() { return "dm"; }

	@property override string[] requiredExecutables() { return ["dmc", "link"]; }
	@property override string[] binPaths() { return ["bin"]; }

	string dmcURL = "http://ftp.digitalmars.com/dmc.zip";
	string optlinkURL = "http://ftp.digitalmars.com/optlink.zip";

	override void installImpl(string target)
	{
		auto dmcZip = buildPath(installationDirectory, "dmc.zip");
		auto optlinkZip = buildPath(installationDirectory, "optlink.zip");

		log("Fetching DMC...");
		auto dmcDir = buildPath(installationDirectory, "dmc");
		dmcURL
			.downloadTo(installationDirectory)
			.atomic!unpack(dmcDir);
		scope(success) removeRecurse(dmcDir);

		enforce(buildPath(dmcDir, "dm", "bin", "dmc.exe").exists);
		rename(buildPath(dmcDir, "dm"), target);

		// Get latest OPTLINK

		log("Fetching OPTLINK...");
		auto optlinkDir = buildPath(installationDirectory, "optlink");
		optlinkURL
			.downloadTo(installationDirectory)
			.atomic!unpack(optlinkDir);
		scope(success) rmdir(optlinkDir);

		rename(buildPath(optlinkDir, "link.exe"), buildPath(target, "bin", "link.exe"));
	}
}

alias dmcInstaller = singleton!DMC;
