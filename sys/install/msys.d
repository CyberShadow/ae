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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.install.msys;

import std.file;
import std.path;
import std.string : format;

import ae.utils.meta : singleton, I;

public import ae.sys.install.common;

/// Installs an MSYS component.
final class MSYSComponent : Installer
{
	this(string componentName, string testFile, string url) { this.componentName = componentName; this.testFile = testFile; this.url = url; } ///

protected:
	string componentName, testFile, url;

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

	static this()
	{
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/msys-core/msys-1.0.18-1/msysCORE-1.0.18-1-msys-1.0.18-bin.tar.lzma"                            ] = "36d52ca7066eb6ad0da68c6f31214416f4c9dcec";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/gettext/gettext-0.18.1.1-1/libintl-0.18.1.1-1-msys-1.0.17-dll-8.tar.lzma"                      ] = "4000b935a5bc30b4c757fde69d27716fa3c2c269";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/libiconv/libiconv-1.14-1/libiconv-1.14-1-msys-1.0.17-dll-2.tar.lzma"                           ] = "056d16bfb7a91c3e3b1acf8adb20edea6fceecdd";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/termcap/termcap-0.20050421_1-2/libtermcap-0.20050421_1-2-msys-1.0.13-dll-0.tar.lzma"           ] = "e4273ccfde8ecf3a7631446fb2b01971a24ff9f7";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/regex/regex-1.20090805-2/libregex-1.20090805-2-msys-1.0.13-dll-1.tar.lzma"                     ] = "d95faa144cf06625b3932a8e84ed1a6ab6bbe644";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/coreutils/coreutils-5.97-3/coreutils-5.97-3-msys-1.0.13-bin.tar.lzma"                          ] = "54ac256a8f0c6a89f1b3c7758f3703b4e56382be";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/bash/bash-3.1.23-1/bash-3.1.23-1-msys-1.0.18-bin.tar.xz"                                       ] = "b6ef3399b8d76b5fbbd0a88774ebc2a90e8af13a";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/make/make-3.81-3/make-3.81-3-msys-1.0.13-bin.tar.lzma"                                         ] = "c7264eb13b05cf2e1a982a3c2619837b96203a27";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/grep/grep-2.5.4-2/grep-2.5.4-2-msys-1.0.13-bin.tar.lzma"                                       ] = "69d03c4415c55b9617850a4991d0708fbe3788f6";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/sed/sed-4.2.1-2/sed-4.2.1-2-msys-1.0.13-bin.tar.lzma"                                          ] = "ced60ab96ab3f713da0d0a570232f2a5f0ec5270";
		urlDigests["https://sourceforge.net/projects/mingw/files/MSYS/Base/diffutils/diffutils-2.8.7.20071206cvs-3/diffutils-2.8.7.20071206cvs-3-msys-1.0.13-bin.tar.lzma"] = "674d3e0be4c8ffe84290f48ed1dd8eb21bc3f805";
	}
}

/// Definitions for some MSYS components.
struct MSYS
{
	alias msysCORE   = singleton!(MSYSComponent, "msysCORE"  , "bin/msys-1.0.dll"      , "https://sourceforge.net/projects/mingw/files/MSYS/Base/msys-core/msys-1.0.18-1/msysCORE-1.0.18-1-msys-1.0.18-bin.tar.lzma"                             ); ///
	alias libintl    = singleton!(MSYSComponent, "libintl"   , "bin/msys-intl-8.dll"   , "https://sourceforge.net/projects/mingw/files/MSYS/Base/gettext/gettext-0.18.1.1-1/libintl-0.18.1.1-1-msys-1.0.17-dll-8.tar.lzma"                       ); ///
	alias libiconv   = singleton!(MSYSComponent, "libiconv"  , "bin/msys-iconv-2.dll"  , "https://sourceforge.net/projects/mingw/files/MSYS/Base/libiconv/libiconv-1.14-1/libiconv-1.14-1-msys-1.0.17-dll-2.tar.lzma"                            ); ///
	alias libtermcap = singleton!(MSYSComponent, "libtermcap", "bin/msys-termcap-0.dll", "https://sourceforge.net/projects/mingw/files/MSYS/Base/termcap/termcap-0.20050421_1-2/libtermcap-0.20050421_1-2-msys-1.0.13-dll-0.tar.lzma"            ); ///
	alias libregex   = singleton!(MSYSComponent, "libregex"  , "bin/msys-regex-1.dll"  , "https://sourceforge.net/projects/mingw/files/MSYS/Base/regex/regex-1.20090805-2/libregex-1.20090805-2-msys-1.0.13-dll-1.tar.lzma"                      ); ///

	alias coreutils  = singleton!(MSYSComponent, "coreutils" , "bin/true.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/coreutils/coreutils-5.97-3/coreutils-5.97-3-msys-1.0.13-bin.tar.lzma"                           ); ///
	alias bash       = singleton!(MSYSComponent, "bash"      , "bin/bash.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/bash/bash-3.1.23-1/bash-3.1.23-1-msys-1.0.18-bin.tar.xz"                                        ); ///
	alias make       = singleton!(MSYSComponent, "make"      , "bin/make.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/make/make-3.81-3/make-3.81-3-msys-1.0.13-bin.tar.lzma"                                          ); ///
	alias grep       = singleton!(MSYSComponent, "grep"      , "bin/grep.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/grep/grep-2.5.4-2/grep-2.5.4-2-msys-1.0.13-bin.tar.lzma"                                        ); ///
	alias sed        = singleton!(MSYSComponent, "sed"       , "bin/sed.exe"           , "https://sourceforge.net/projects/mingw/files/MSYS/Base/sed/sed-4.2.1-2/sed-4.2.1-2-msys-1.0.13-bin.tar.lzma"                                           ); ///
	alias diffutils  = singleton!(MSYSComponent, "diffutils" , "bin/diff.exe"          , "https://sourceforge.net/projects/mingw/files/MSYS/Base/diffutils/diffutils-2.8.7.20071206cvs-3/diffutils-2.8.7.20071206cvs-3-msys-1.0.13-bin.tar.lzma" ); ///
}
