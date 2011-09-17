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

module ae.sys.os.windows.config;

import std.windows.charset;
import std.exception;
import std.traits;
import std.utf;
import std.conv;

import win32.windef;
import win32.winreg;

import ae.ui.app.application;

struct WindowsConfig
{
static:
	T read(T)(string name, T defaultValue = T.init)
	{
		try
		{
			static if (is(T : const(char[]))) // strings
			{
				uint bytes = getSize(name);
				enforce(bytes % 2 == 0);
				wchar[] ws = new wchar[bytes / 2];
				readRaw(name, ws);
				enforce(ws[$-1]==0); // should be null-terminated
				return to!T(ws[0..$-1]);
			}
			else
			static if (is(T == long) || is(T == ulong))
			{
				T value;
				readRaw(name, (&value)[0..1]);
				return value;
			}
			else
			static if (is(T : uint) || is(T : bool))
			{
				uint value;
				readRaw(name, (&value)[0..1]);
				return cast(T)value;
			}
			else
				static assert(0, "Can't read values of type " ~ T.stringof);
		}
		catch (Throwable e)
			return defaultValue;
	}
	
	void write(T)(string name, T value)
	{
		static if (is(T : const(char[]))) // strings
		{
			wstring ws = to!wstring(value ~ '\0');
			writeRaw(name, ws, REG_SZ);
		}
		else
		static if (is(T == long) || is(T == ulong))
			writeRaw(name, (&value)[0..1], REG_QWORD);
		else
		static if (is(T : uint) || is(T : bool))
		{
			uint dwordValue = cast(uint)value;
			writeRaw(name, (&dwordValue)[0..1], REG_DWORD);
		}
		else
			static assert(0, "Can't write values of type " ~ T.stringof);
	}
	
private:
	HKEY key;
	
	void openKey()
	{
		enforce(RegCreateKeyExA(
			HKEY_CURRENT_USER, 
			toMBSz(`Software\` ~ application.getCompanyName() ~ `\` ~ application.getName()), 
			0,
			null,
			0,
			KEY_READ | KEY_WRITE,
			null,
			&key,
			null));
	}

	void readRaw(string name, void[] dest)
	{
		if (!key) openKey();
		enforce(getSize(name) == dest.length, "Invalid registry value length for " ~ name);
		DWORD size = dest.length;
		enforce(RegQueryValueExW(key, toUTFz!LPCWSTR(name), null, null, cast(ubyte*)dest.ptr, &size) == ERROR_SUCCESS, "RegQueryValueEx failed");
		enforce(size == dest.length, "Not enough data read");
	}

	void writeRaw(string name, const(void)[] dest, DWORD type)
	{
		if (!key) openKey();
		enforce(RegSetValueExW(key, toUTFz!LPCWSTR(name), 0, type, cast(ubyte*)dest.ptr, dest.length) == ERROR_SUCCESS, "RegSetValueEx failed");
	}

	uint getSize(string name)
	{
		DWORD size;
		enforce(RegQueryValueExW(key, toUTFz!LPCWSTR(name), null, null, null, &size) == ERROR_SUCCESS);
		return size;
	}

	~this()
	{
		if (key)
			RegCloseKey(key);
	}
}
