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

/// File stuff
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
