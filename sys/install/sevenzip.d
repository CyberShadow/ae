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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.install.sevenzip;

import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

/// Installs the 7-Zip archiving tool.
/// Windows-only.
class SevenZipInstaller : Installer
{
	string url = "http://downloads.sourceforge.net/sevenzip/7za920.zip"; /// Download URL.

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

	/// "7za" or "7z", depending on which is available.
	@property string exe()
	{
		if (haveExecutable("7za"))
			return "7za";
		else
			return "7z";
	}

	static this()
	{
		urlDigests["http://downloads.sourceforge.net/sevenzip/7za920.zip"] = "9ce9ce89ebc070fea5d679936f21f9dde25faae0";
	}
}

alias sevenZip = singleton!SevenZipInstaller;
