/**
 * OS-specific paths.
 *
 * getConfigDir - roaming, for configuration
 * getDataDir - roaming, for user data
 * getCacheDir - local
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

module ae.sys.paths;

import std.path;

version (Windows)
{
	import core.stdc.wctype;

	import std.exception;
	import std.file;
	import std.utf;

	import ae.sys.windows.imports;
	mixin(importWin32!q{shlobj});
	mixin(importWin32!q{objidl});
	mixin(importWin32!q{windef});
	mixin(importWin32!q{winbase});

	private string getShellPath(int csidl)
	{
		LPITEMIDLIST pidl;
		SHGetSpecialFolderLocation(null, csidl, &pidl);
		scope(exit)
		{
			IMalloc aMalloc;
			SHGetMalloc(&aMalloc);
			aMalloc.Free(pidl);
		}

		auto path = new wchar[MAX_PATH];
		if (!SHGetPathFromIDListW(pidl, path.ptr))
			return null;
		path.length = wcslen(path.ptr);

		return toUTF8(path);
	}

	private string getAppDir(string appName, int csidl)
	{
		string dir = getShellPath(csidl) ~ `\` ~ (appName ? appName : getExecutableName());
		if (!exists(dir))
			mkdir(dir);
		return dir;
	}

	/*private*/ string getAppDir(int csidl)(string appName = null)
	{
		return getAppDir(appName, csidl);
	}

	alias getLocalAppProfile   = getAppDir!CSIDL_LOCAL_APPDATA;
	alias getRoamingAppProfile = getAppDir!CSIDL_APPDATA;

	alias getConfigDir = getLocalAppProfile;
	alias getDataDir   = getLocalAppProfile;
	alias getCacheDir  = getRoamingAppProfile;
}
else // POSIX
{
	import std.string;
	import std.ascii;
	import std.conv : octal;
	import std.file;
	import std.process;

	alias toLower = std.ascii.toLower;

	private string getPosixAppName(string appName)
	{
		string s = appName ? appName : getExecutableName();
		string s2;
		foreach (c; s)
			if (isAlphaNum(c))
				s2 ~= toLower(c);
			else
				if (!s2.endsWith('-'))
					s2 ~= '-';
		return s2;
	}

	private string getXdgDir(string varName, string defaultValue, string appName)
	{
		string path = environment.get(varName, defaultValue.expandTilde());
		if (!exists(path))
		{
			mkdir(path);
			setAttributes(path, octal!700);
		}
		path = path.buildPath(getPosixAppName(appName));
		if (!exists(path))
			mkdir(path);
		return path;
	}

	/*private*/ string getXdgDir(string varName, string defaultValue)(string appName = null)
	{
		return getXdgDir(varName, defaultValue, appName);
	}

	alias getDataDir    = getXdgDir!("XDG_DATA_HOME"  , "~/.local/share");
	alias getConfigDir  = getXdgDir!("XDG_CONFIG_HOME", "~/.config");
	alias getCacheDir   = getXdgDir!("XDG_CACHE_HOME" , "~/.cache");
}

/// Get the base name of the current executable.
string getExecutableName()
{
	import std.file;
	return thisExePath().baseName();
}

