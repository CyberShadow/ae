/**
 * 7-Zip command-line installer
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

module ae.sys.install.sevenzip;

import std.array;
import std.file;
import std.path;

import ae.sys.archive;
import ae.sys.file;
import ae.utils.array;
import ae.utils.meta : singleton, I;
import ae.utils.xmllite;

public import ae.sys.install.common;

class SevenZipInstaller : Installer
{
	string url = "http://downloads.sourceforge.net/sevenzip/7za920.zip";

	@property override string name() { return "7-Zip"; }
	@property override string subdirectory() { return "7z"; }

	@property override string[] requiredExecutables() { assert(false); }

	import ae.utils.path : haveExecutable;

	override void installImpl(string target)
	{
		windowsOnly();
		url
			.I!save()
			.I!unpackTo(target);
	}

	@property override bool availableOnSystem()
	{
		return haveExecutable("7z") || haveExecutable("7za");
	}

	@property string exe()
	{
		if (haveExecutable("7za"))
			return "7za";
		else
			return "7z";
	}
}

alias sevenZip = singleton!SevenZipInstaller;
