/**
 * Git command-line installer
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

module ae.sys.install.git;

import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;

import ae.sys.archive;
import ae.sys.file;
import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

class GitInstaller : Installer
{
	string url = "https://github.com/git-for-windows/git/releases/download/v2.21.0.windows.1/PortableGit-2.21.0-32-bit.7z.exe";

	@property override string[] requiredExecutables() { return ["git"]; }
	@property override string[] binPaths() { return ["cmd"]; }

	override void installImpl(string target)
	{
		windowsOnly();
		url
			.I!save()
			.I!unpackTo(target);
	}

	static this()
	{
		urlDigests["https://github.com/git-for-windows/git/releases/download/v2.21.0.windows.1/PortableGit-2.21.0-32-bit.7z.exe"] = "db083fde82c743a26dbd7fbd597d3a6321522936";
	}
}

alias gitInstaller = singleton!GitInstaller;
