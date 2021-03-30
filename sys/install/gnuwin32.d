/**
 * GnuWin32 installer
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

module ae.sys.install.gnuwin32;

import std.file;
import std.path;
import std.string : format, split;

import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

final class GnuWin32Component : Installer
{
	string urlTemplate = "http://gnuwin32.sourceforge.net/downlinks/%s-%s-zip.php";

	string componentName;
	this(string componentName) { this.componentName = componentName; }

	@property override string name() { return "%s (GnuWin32)".format(componentName); }
	@property override string subdirectory() { return "gnuwin32"; }
	@property override string[] binPaths() { return ["bin"]; }

	override @property bool installedLocally()
	{
		auto manifestDir = directory.buildPath("manifest");
		return manifestDir.exists && !manifestDir.dirEntries(componentName ~ "-*-bin.ver", SpanMode.shallow).empty;
	}

	override void atomicInstallImpl()
	{
		windowsOnly();
		if (!directory.exists)
			directory.mkdir();
		installUrl(urlTemplate.format(componentName, "bin"));
		installUrl(urlTemplate.format(componentName, "dep"));
		assert(installedLocally);
	}

	void installUrl(string url)
	{
		url
			.I!saveAs(url.split("/")[$-1][0..$-8] ~ ".zip")
			.I!unpack()
			.atomicMoveInto(directory);
	}
}

struct GnuWin32
{
	static GnuWin32Component opDispatch(string name)()
	{
		alias component = singleton!(GnuWin32Component, name);
		return component;
	}
}
