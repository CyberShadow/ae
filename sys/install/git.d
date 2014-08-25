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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.install.git;

import std.array;
import std.exception;
import std.file;
import std.path;
import std.process;

import ae.sys.archive;
import ae.sys.file;
import ae.sys.net;
import ae.utils.meta.misc;

public import ae.sys.install.common;

class Git : Installer
{
	string url = "https://github.com/msysgit/msysgit/releases/download/Git-1.9.4-preview20140815/PortableGit-1.9.4-preview20140815.7z";

	@property override string[] requiredExecutables() { return ["git"]; }
	@property override string[] binPaths() { return ["cmd"]; }

	override void installImpl(string target)
	{
		windowsOnly();
		url
			.downloadTo(installationDirectory)
			.unpack(target);
	}
}

alias gitInstaller = singleton!Git;
