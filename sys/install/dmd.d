/**
 * DMD installer
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

module ae.sys.install.dmd;

version(Windows):

import std.array;
import std.conv;
import std.exception;
import std.file;
import std.string;
import std.path;

import ae.sys.archive;
import ae.sys.file;
import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

class DMD : Installer
{
	string dmdVersion;

	this(string v = currentVersion)
	{
		dmdVersion = v;
	}

	// Note: we can't get the dot-release version. Assume ".0".
	enum currentVersion = text(__VERSION__)[0] ~ "." ~ text(__VERSION__)[1..$] ~ ".0";

	version (Windows)
		enum modelString = "";
	else
	version (OSX)
		enum modelString = "";
	else
	version (D_LP64)
		enum modelString = "64";
	else
		enum modelString = "32";

	version (Windows)
		enum platformDir = "windows";
	else
	version (linux)
		enum platformDir = "linux";
	else
	version (FreeBSD)
		enum platformDir = "freebsd";
	else
	version (OSX)
		enum platformDir = "osx";
	else
		static assert(false, "Unknown platform");

	@property override string name() { return "DigitalMars D compiler v" ~ dmdVersion; }
	@property override string subdirectory() { return "dmd-" ~ dmdVersion; }

	@property override string[] requiredExecutables() { return ["dmd"]; }
	@property override string[] binPaths() { return ["dmd2/" ~ platformDir ~ "/bin" ~ modelString]; }

	@property string url() { return "http://downloads.dlang.org/releases/%s.x/%s/dmd.%s.zip".format(dmdVersion[0], dmdVersion, dmdVersion); }

	override void installImpl(string target)
	{
		url
			.I!save()
			.I!unpackTo(target);
	}
}

alias dmdInstaller = singleton!DMD;
