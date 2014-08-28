/**
 * WiX Toolset
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

module ae.sys.install.wix;

import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;

import ae.sys.archive;
import ae.sys.file;
import ae.utils.meta.misc;

public import ae.sys.install.common;

class Wix : Installer
{
	string url = "http://download-codeplex.sec.s-msft.com/Download/Release?ProjectName=wix&DownloadId=762938&FileTime=130301249355530000&Build=20928";

	@property override string[] requiredExecutables() { return ["candle", "dark", "heat", "light", "lit", "lux", "melt", "nit", "pyro", "retina", "shine", "smoke", "torch"]; }

	override void installImpl(string target)
	{
		windowsOnly();
		url
			.I!saveAs("wix-762938-20928.zip")
			.I!unpackTo(target);
	}
}

alias wixInstaller = singleton!Wix;
