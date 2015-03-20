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

import std.conv;
import std.file;
import std.regex;
import std.string;

import ae.sys.archive;
import ae.sys.file;
import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

class WixInstaller : Installer
{
	int downloadId = 762938;
	long fileTime = 130301249355530000;

	@property override string[] requiredExecutables() { return ["candle", "dark", "heat", "light", "lit", "lux", "melt", "nit", "pyro", "retina", "shine", "smoke", "torch"]; }

	override void installImpl(string target)
	{
		windowsOnly();
		// CodePlex does not have direct download URLs. Scrape it!
		"http://wix.codeplex.com/downloads/get/%d"
			.format(downloadId)
			.I!saveAs("wix-%d.html".format(downloadId))
			.readText()
			.match(regex(`<li>Version \d+\.\d+\.\d+\.(\d+)</li>`)).front[1]
			.to!int
			.I!buildZipUrl()
			.I!saveAs("wix-%d.zip".format(downloadId))
			.I!unpackTo(target);
	}

	string buildZipUrl(int build)
	{
		return "http://download-codeplex.sec.s-msft.com/Download/Release?ProjectName=wix&DownloadId=%d&FileTime=%d&Build=%d"
			.format(downloadId, fileTime, build);
	}
}

alias wixInstaller = singleton!WixInstaller;
