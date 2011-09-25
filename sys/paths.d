/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// OS-specific paths.
module ae.sys.paths;

import std.path;

version (Windows)
{
	import std.c.string;
	import std.file;
	import std.exception;

	import win32.shlobj;
	import win32.objidl;
	import win32.windef;
	import win32.winbase;

	string getExecutableName()
	{
		auto path = new char[MAX_PATH];
		path.length = enforce(GetModuleFileNameA(null, path.ptr, path.length));
		return baseName(assumeUnique(path));
	}

	private string getShellPath(int csidl)
	{
		LPITEMIDLIST pidl;
		IMalloc aMalloc;

		auto path = new char[MAX_PATH];
		SHGetSpecialFolderLocation(null, csidl, &pidl);
		if(!SHGetPathFromIDList(pidl, path.ptr))
			path = null;
		path.length = strlen(path.ptr);
		SHGetMalloc(&aMalloc);
		aMalloc.Free(pidl);
		return assumeUnique(path);
	}

	private string getAppDir(string appName, int csidl)
	{
		string dir = getShellPath(csidl) ~ `\` ~ (appName ? appName : getExecutableName());
		if (!exists(dir))
			mkdir(dir);
		return dir;
	}

	string getLocalAppProfile  (string appName = null) { return getAppDir(appName, CSIDL_LOCAL_APPDATA); }
	string getRoamingAppProfile(string appName = null) { return getAppDir(appName, CSIDL_APPDATA); }
}
else // POSIX
{
	import std.string;
	import std.ascii;
	import std.file;

	string getExecutableName()
	{
		// TODO: is this valid with OS X app bundles?
		return baseName(readLink("/proc/self/exe"));
	}

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

	string getAppProfile(string appName = null)
	{
		string path = expandTilde("~/." ~ getPosixAppName(appName));
		if (!exists(path))
			mkdir(path);
		return path;
	}

	alias getAppProfile getLocalAppProfile;
	alias getAppProfile getRoamingAppProfile;
}
