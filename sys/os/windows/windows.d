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

module ae.sys.os.windows.windows;

import win32.shlobj;
import win32.objidl;
import win32.shellapi;
import win32.winuser;
import win32.windef;
import win32.winbase;
import std.c.string;
import std.file;

import ae.sys.os.os;
import ae.ui.app.application;

import ae.sys.os.windows.config;

struct OS
{
static:
	DefaultOS defaultOS; // Issue 6656
	alias defaultOS this;

	void getDefaultResolution(out uint x, out uint y)
	{
		x = GetSystemMetrics(SM_CXSCREEN);
		y = GetSystemMetrics(SM_CYSCREEN);
	}

	// ************************************************************

	private string getShellPath(int csidl)
	{
		LPITEMIDLIST pidl;
		IMalloc aMalloc;

		char[] path = new char[MAX_PATH];
		SHGetSpecialFolderLocation(null, csidl, &pidl);
		if(!SHGetPathFromIDList(pidl, path.ptr))
			path = null;
		path.length = strlen(path.ptr);
		SHGetMalloc(&aMalloc);
		aMalloc.Free(pidl);
		return cast(string)path;
	}

	private string getAppDir(int csidl)
	{
		string dir = getShellPath(csidl) ~ `\` ~ application.getName();
		if (!exists(dir))
			mkdir(dir);
		return dir;
	}

	string getLocalAppProfile() { return getAppDir(CSIDL_LOCAL_APPDATA); }
	string getRoamingAppProfile() { return getAppDir(CSIDL_APPDATA); }

	// ************************************************************

	alias WindowsConfig Config;
}
