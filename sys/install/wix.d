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
 *   Vladimir Panteleev <ae@cy.md>
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

/// Installs the Wix MSI toolkit.
class WixInstaller : Installer
{
	string wixVersion = "3.10.4"; /// Version to install.

	@property override string[] requiredExecutables() { return ["candle", "dark", "heat", "light", "lit", "lux", "melt", "nit", "pyro", "retina", "shine", "smoke", "torch"]; }

	override void installImpl(string target)
	{
		windowsOnly();
		"https://github.com/wixtoolset/wix3/releases/download/wix%srtm/wix%s-binaries.zip"
			.format(wixVersion.split(".").join(), wixVersion.split(".")[0..2].join())
			.I!resolveRedirect()
			.I!verify("147ebb26a67c5621a104f9794deae925908884e7")
			.I!saveAs("wix-%s.zip".format(wixVersion))
			.I!unpackTo(target);
	}

	static string verify(string url, string hash)
	{
		urlDigests[url] = hash;
		return url;
	}
}

alias wixInstaller = singleton!WixInstaller; /// ditto
