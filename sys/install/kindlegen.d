/**
 * KindleGen installer
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

module ae.sys.install.kindlegen;

import std.exception;

import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

class KindleGenInstaller : Installer
{
	version (Windows)
		enum defaultUrl = "https://dump.cy.md/d4be194f848da73ea09742bc3a787f1b/kindlegen_win32_v2_9.zip";
	else
	version (linux)
		enum defaultUrl = "https://dump.cy.md/21aef3c8846946203e178c83a37beba1/kindlegen_linux_2.6_i386_v2_9.tar.gz";
	else
	version (OSX)
		enum defaultUrl = "https://dump.cy.md/204a2a4cc3e95e1a0dbbb9e52a7bc482/KindleGen_Mac_i386_v2_9.zip";
	else
		enum defaultUrl = null;

	string url = defaultUrl;

	static this()
	{
		urlDigests["https://dump.cy.md/d4be194f848da73ea09742bc3a787f1b/kindlegen_win32_v2_9.zip"            ] = "8b5540f12e291b4031ad5197e11c0c9f576ad1e5";
		urlDigests["https://dump.cy.md/21aef3c8846946203e178c83a37beba1/kindlegen_linux_2.6_i386_v2_9.tar.gz"] = "2e46cce099aba2725b5ba9ac9d1b1ecdc9dd77e2";
		urlDigests["https://dump.cy.md/204a2a4cc3e95e1a0dbbb9e52a7bc482/KindleGen_Mac_i386_v2_9.zip"         ] = "efa5ad0b05650f7f71543535ea2b232bb5fec571";
	}

	@property override string[] requiredExecutables() { return ["kindlegen"]; }

	override void installImpl(string target)
	{
		enforce(url, "KindleGen: No URL or platform not supported");
		url
			.I!save()
			.I!unpackTo(target);
	}
}

alias kindleGenInstaller = singleton!KindleGenInstaller;
