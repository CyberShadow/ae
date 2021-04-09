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
 *   Vladimir Panteleev <ae@cy.md>
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

	string ver;    /// Version to install
	string dmcURL; /// URL to DigitalMars C

	this(string ver)
	{
		ver = ver.replace(".", "");
		this.ver = ver;
		if (ver >= "855")
			dmcURL = "http://downloads.dlang.org/other/dm" ~ ver ~ "c.zip";
		else
			dmcURL = "http://ftp.digitalmars.com/Digital_Mars_C++/Patch/dm" ~ ver ~ "c.zip";
	} ///

	static this()
	{
		urlDigests["http://ftp.digitalmars.com/Digital_Mars_C++/Patch/dm850c.zip"] = "de1d27c337f028f4d001aec903474b85275c7118";
		urlDigests["http://downloads.dlang.org/other/dm855c.zip"				 ] = "5a177e50495f0062f107cba0c9231f780ebc56e1";
		urlDigests["http://downloads.dlang.org/other/dm856c.zip"				 ] = "c46302e645f9ce649fe8b80c0dec513f1622ccc0";
		urlDigests["http://downloads.dlang.org/other/dm857c.zip"				 ] = "c6bbaf8b872bfb1c82e611ef5e249dd19eab5272";
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

/// Installs DMC and updates it with the latest OPTLINK and snn.lib.
class DMCInstaller : LegacyDMCInstaller
{
	//string optlinkURL = "http://downloads.dlang.org/other/optlink-8.00.15.zip";
	string optlinkURL = null; /// URL to OPTLINK .zip file to install on top of the DMC one
	string dmdURL = "http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.windows.7z"; /// URL to DMD .zip file with latest snn.lib

	@property override string subdirectory() { return super.subdirectory ~ "-snn2074-optlink80017"; }

	this()
	{
		super("857");
	} ///

	static this()
	{
		urlDigests["http://downloads.dlang.org/other/optlink-8.00.15.zip"                  ] = "f5a161029d795063e57523824be7408282cbdb81";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.071.0/dmd.2.071.0.windows.7z"] = "c1bc880e54ff25ba8ee938abb2a1436ff6a9dec8";
		urlDigests["http://downloads.dlang.org/releases/2.x/2.074.0/dmd.2.074.0.windows.7z"] = "b2f491a448a674c0c3854ffa6b38b2da638c0ea0";
	}

	override void installImpl(string target)
	{
		super.installImpl(target);

		// Get latest OPTLINK

		if (optlinkURL)
		{
			auto optlinkDir =
				optlinkURL
				.I!save()
				.I!unpack();
			scope(success) rmdirRecurse(optlinkDir);

			rename(buildPath(optlinkDir, "link.exe"), buildPath(target, "bin", "link.exe"));
			hardLink(buildPath(target, "bin", "link.exe"), buildPath(target, "bin", "optlink.exe"));
		}

		// Get latest snn.lib

		if (dmdURL)
		{
			auto dmdDir =
				dmdURL
				.I!save()
				.I!unpack();
			scope(success) rmdirRecurse(dmdDir);

			rename(buildPath(dmdDir, "dmd2", "windows", "lib", "snn.lib"), buildPath(target, "lib", "snn.lib"));
			if (!optlinkURL)
			{
				rename(buildPath(dmdDir, "dmd2", "windows", "bin", "link.exe"), buildPath(target, "bin", "link.exe"));
				hardLink(buildPath(target, "bin", "link.exe"), buildPath(target, "bin", "optlink.exe"));
			}
		}
	}
}

alias dmcInstaller = singleton!DMCInstaller; /// ditto
