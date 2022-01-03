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
 *   Vladimir Panteleev <ae@cy.md>
 *
 * References:
 *   https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
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

	/*private*/ string _getAppDir(int csidl, string appName = null)
	{
		return getShellPath(csidl) ~ `\` ~ (appName ? appName : getExecutableName());
	}

	/*private*/ string[] _getAppDirs(int csidl, string appName = null)
	{
		return [thisExePath.dirName(), _getAppDir(csidl, appName)];
	}

	alias getLocalAppProfile   = _bindArgs!(_getAppDir, CSIDL_LOCAL_APPDATA); ///
	alias getRoamingAppProfile = _bindArgs!(_getAppDir, CSIDL_APPDATA);       ///

	alias getConfigDir  = getRoamingAppProfile; ///
	alias getDataDir    = getRoamingAppProfile; ///
	alias getCacheDir   = getLocalAppProfile;   ///

	alias getConfigDirs = _bindArgs!(_getAppDir, CSIDL_LOCAL_APPDATA); ///
	alias getDataDirs   = _bindArgs!(_getAppDir, CSIDL_LOCAL_APPDATA); ///

	string getHomeDir() { return environment.get("USERPROFILE"); }
}
else // POSIX
{
	import std.algorithm.iteration;
	import std.array;
	import std.ascii;
	import std.conv : octal;
	import std.file;
	import std.process;
	import std.string;

	private alias toLower = std.ascii.toLower;

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

	private struct XdgDir
	{
		string homeVarName;
		string homeDefaultValue;
		string dirsVarName;
		string dirsDefaultValue;

		string getHome() const
		{
			return environment.get(homeVarName, homeDefaultValue.expandTilde());
		}

		string getAppHome(string appName) const
		{
			return getHome().buildPath(getPosixAppName(appName));
		}

		string[] getDirs() const
		{
			string paths = environment.get(dirsVarName, dirsDefaultValue);
			return [getHome()] ~ paths.split(pathSeparator);
		}

		string[] getAppDirs(string appName) const
		{
			return getDirs()
				.map!(dir => dir.buildPath(getPosixAppName(appName)))
				.array();
		}

	}

	immutable XdgDir _xdgData   = XdgDir("XDG_DATA_HOME"  , "~/.local/share", "XDG_DATA_DIRS"  , "/usr/local/share/:/usr/share/");
	immutable XdgDir _xdgConfig = XdgDir("XDG_CONFIG_HOME", "~/.config"     , "XDG_CONFIG_DIRS", "/etc/xdg");
	immutable XdgDir _xdgCache  = XdgDir("XDG_CACHE_HOME" , "~/.cache"      );

	/*private*/ string _getXdgAppDir(alias xdgDir)(string appName = null)
	{
		return xdgDir.getAppHome(appName);
	}

	/*private*/ string[] _getXdgAppDirs(alias xdgDir)(string appName = null)
	{
		return xdgDir.getAppDirs(appName);
	}

	alias getDataDir    = _getXdgAppDir!_xdgData;    ///
	alias getConfigDir  = _getXdgAppDir!_xdgConfig;  ///
	alias getCacheDir   = _getXdgAppDir!_xdgCache;   ///

	alias getDataDirs   = _getXdgAppDirs!_xdgData;   ///
	alias getConfigDirs = _getXdgAppDirs!_xdgConfig; ///

	string getHomeDir() { return environment.get("HOME"); }
}

/// Get the base name of the current executable.
string getExecutableName()
{
	import std.file;
	return thisExePath().baseName();
}

/*private*/ template _bindArgs(alias fun, CTArgs...)
{
	auto _bindArgs(RTArgs...)(auto ref RTArgs rtArgs)
	{
		return fun(CTArgs, rtArgs);
	}
}
