module ng.os.windows.windows;

import win32.shlobj;
import win32.objidl;
import win32.shellapi;
import win32.winuser;
import win32.windef;
import win32.winbase;
import std.c.string;
import std.file;

import ng.os.os;
import ng.core.application;

import ng.os.windows.config;

struct OS
{
static:
	alias DefaultOS this;

	void getDefaultResolution(out int x, out int y)
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
