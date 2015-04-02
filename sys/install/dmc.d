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
import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

/// Installs old versions of DMC.
class LegacyDMCInstaller : Installer
{
	@property override string name() { return "DigitalMars C++" ~ (ver ? " v" ~ ver[0] ~ "." ~ ver[1..$] : null); }
	@property override string subdirectory() { return "dm" ~ ver; }

	@property override string[] requiredExecutables() { return ["dmc", "link"]; }
	@property override string[] binPaths() { return ["bin"]; }

	string dmcURL;
	string ver;

	this(string ver)
	{
		ver = ver.replace(".", "");
		this.ver = ver;
		dmcURL = "http://ftp.digitalmars.com/Digital_Mars_C++/Patch/dm" ~ ver ~ "c.zip";
	}

	override void installImpl(string target)
	{
		auto dmcDir =
			dmcURL
			.I!save()
			.I!unpack();
		scope(success) removeRecurse(dmcDir);

		enforce(buildPath(dmcDir, "dm", "bin", "dmc.exe").exists);
		rename(buildPath(dmcDir, "dm"), target);
	}
}

/// Installs the latest DMC and updates it with the latest OPTLINK.
class DMCInstaller : LegacyDMCInstaller
{
	string optlinkURL = "http://ftp.digitalmars.com/optlink.zip";

	this()
	{
		super(null);
		dmcURL = "http://ftp.digitalmars.com/dmc.zip";
	}

	override void installImpl(string target)
	{
		super.installImpl(target);

		// Get latest OPTLINK

		auto optlinkDir =
			optlinkURL
			.I!save()
			.I!unpack();
		scope(success) rmdir(optlinkDir);

		rename(buildPath(optlinkDir, "link.exe"), buildPath(target, "bin", "link.exe"));
	}
}

alias dmcInstaller = singleton!DMCInstaller;
