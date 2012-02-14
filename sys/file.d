/**
 * File stuff
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

module ae.sys.file;

import std.file, std.path;
import std.array;

// ************************************************************************

version(Windows)
{
	import std.c.windows.windows;

	string[] fastListDir(bool recursive = false)(string pathname)
	{
		string[] result;
		string c;
		HANDLE h;

		c = std.path.join(pathname, "*.*");
		WIN32_FIND_DATAW fileinfo;

		h = FindFirstFileW(std.utf.toUTF16z(c), &fileinfo);
		if (h != INVALID_HANDLE_VALUE)
		{
			try
			{
				do
				{
					// Skip "." and ".."
					if (std.string.wcscmp(fileinfo.cFileName.ptr, ".") == 0 ||
						std.string.wcscmp(fileinfo.cFileName.ptr, "..") == 0)
						continue;

					size_t clength = std.string.wcslen(fileinfo.cFileName.ptr);
					string name = std.utf.toUTF8(fileinfo.cFileName[0 .. clength]);
					string path = std.path.join(pathname, name);

					static if (recursive)
					{
						if (fileinfo.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
						{
							result ~= fastListDir(path);
							continue;
						}
					}

					result ~= path;
				} while (FindNextFileW(h,&fileinfo) != FALSE);
			}
			finally
			{
				FindClose(h);
			}
		}
		return result;
	}
}
else
version (linux)
{
	// TODO: fixme
	private import std.c.stdlib : getErrno;
	private import std.c.linux.linux : DIR, dirent, opendir, readdir, closedir;

	string[] fastListDir(string pathname)
	{
		string[] result;
		DIR* h;
		dirent* fdata;

		h = opendir(toStringz(pathname));
		if (h)
		{
			try
			{
				while((fdata = readdir(h)) != null)
				{
					// Skip "." and ".."
					if (!std.c.string.strcmp(fdata.d_name.ptr, ".") ||
						!std.c.string.strcmp(fdata.d_name.ptr, ".."))
							continue;

					size_t len = std.c.string.strlen(fdata.d_name.ptr);
					result ~= fdata.d_name[0 .. len].dup;
				}
			}
			finally
			{
				closedir(h);
			}
		}
		else
		{
			throw new std.file.FileException(pathname, getErrno());
		}
		return result;
	}
}
else
	static assert(0, "TODO");

import std.datetime;
import std.exception;

SysTime getMTime(string name)
{
	version(Windows)
	{
		auto h = CreateFileW(std.utf.toUTF16z(name), GENERIC_READ, 0, null, OPEN_EXISTING, 0, HANDLE.init);
		enforce(h!=INVALID_HANDLE_VALUE, "CreateFile");
		FILETIME ft;
		enforce(GetFileTime(h, null, null, &ft), "GetFileTime");
		CloseHandle(h);
		return FILETIMEToSysTime(&ft);
	}
	else
	{
		d_time ftc, fta, ftm;
		std.file.getTimes(name, ftc, fta, ftm);
		return ftm;
	}
}
