/**
 * MSYS installer
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

module ae.sys.install.msys;

import std.file;
import std.path;
import std.string : format;

import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

final class MSYSComponent : Installer
{
	string componentName, testFile, url;
	this(string componentName, string testFile, string url) { this.componentName = componentName; this.testFile = testFile; this.url = url; }

	@property override string name() { return "%s (MSYS)".format(componentName); }
	@property override string subdirectory() { return "msys"; }
	@property override string[] binPaths() { return ["bin"]; }

	override @property bool installedLocally()
	{
		return directory.buildPath(testFile).exists;
	}

	override void atomicInstallImpl()
	{
		windowsOnly();
		if (!directory.exists)
			directory.mkdir();
		url
			.I!save()
			.I!unpack()
			.atomicMoveInto(directory);
		assert(installedLocally);
	}
}

struct MSYS
{
	alias msysCORE   = singleton!(MSYSComponent, "msysCORE"  , "bin/msys-1.0.dll"      , "https://sourceforge.net/projects/mingw/files/MSYS/Base/msys-core/msys-1.0.18-1/msysCORE-1.0.18-1-msys-1.0.18-bin.tar.lzma");
	alias libintl    = singleton!(MSYSComponent, "libintl"   , "bin/msys-intl-8.dll"   , "https://sourceforge.net/projects/mingw/files/MSYS/Base/gettext/gettext-0.18.1.1-1/libintl-0.18.1.1-1-msys-1.0.17-dll-8.tar.lzma");
	alias libiconv   = singleton!(MSYSComponent, "libiconv"  , "bin/msys-iconv-2.dll"  , "https://sourceforge.net/projects/mingw/files/MSYS/Base/libiconv/libiconv-1.14-1/libiconv-1.14-1-msys-1.0.17-dll-2.tar.lzma");
	alias libtermcap = singleton!(MSYSComponent, "libtermcap", "bin/msys-termcap-0.dll", "https://sourceforge.net/projects/mingw/files/MSYS/Base/termcap/termcap-0.20050421_1-2/libtermcap-0.20050421_1-2-msys-1.0.13-dll-0.tar.lzma");
	alias libregex   = singleton!(MSYSComponent, "libregex"  , "bin/msys-regex-1.dll"  , "https://sourceforge.net/projects/mingw/files/MSYS/Base/regex/regex-1.20090805-2/libregex-1.20090805-2-msys-1.0.13-dll-1.tar.lzma");

	alias coreutils  = singleton!(MSYSComponent, "coreutils" , "bin/true.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/coreutils/coreutils-5.97-3/coreutils-5.97-3-msys-1.0.13-bin.tar.lzma");
	alias bash       = singleton!(MSYSComponent, "bash"      , "bin/bash.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/bash/bash-3.1.23-1/bash-3.1.23-1-msys-1.0.18-bin.tar.xz");
	alias make       = singleton!(MSYSComponent, "make"      , "bin/make.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/make/make-3.81-3/make-3.81-3-msys-1.0.13-bin.tar.lzma");
	alias grep       = singleton!(MSYSComponent, "grep"      , "bin/grep.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/grep/grep-2.5.4-2/grep-2.5.4-2-msys-1.0.13-bin.tar.lzma");
	alias diffutils  = singleton!(MSYSComponent, "diffutils" , "bin/diff.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/diffutils/diffutils-2.8.7.20071206cvs-3/diffutils-2.8.7.20071206cvs-3-msys-1.0.13-bin.tar.lzma");
}
