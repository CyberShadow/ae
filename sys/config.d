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

/// OS-specific configuration storage.
module ae.sys.config;

import ae.sys.paths;

version (Windows)
{
	import std.exception;
	import std.utf;
	import std.array;

	import win32.windef;
	import win32.winreg;

	// On Windows, just keep the registry key open and read/write values directly.
	class Config
	{
		this(string appName = null, string companyName = null)
		{
			if (!appName)
				appName = getExecutableName();
			if (companyName)
				appName = companyName ~ `\` ~ appName;

			enforce(RegCreateKeyExW(
				HKEY_CURRENT_USER,
				toUTFz!LPCWSTR(`Software\` ~ appName),
				0,
				null,
				0,
				KEY_READ | KEY_WRITE,
				null,
				&key,
				null) == ERROR_SUCCESS, "RegCreateKeyEx failed");
		}

		~this()
		{
			if (key)
				RegCloseKey(key);
		}

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

		void readRaw(string name, void[] dest)
		{
			enforce(getSize(name) == dest.length, "Invalid registry value length for " ~ name);
			DWORD size = dest.length;
			enforce(RegQueryValueExW(key, toUTFz!LPCWSTR(name), null, null, cast(ubyte*)dest.ptr, &size) == ERROR_SUCCESS, "RegQueryValueEx failed");
			enforce(size == dest.length, "Not enough data read");
		}

		void writeRaw(string name, const(void)[] dest, DWORD type)
		{
			enforce(RegSetValueExW(key, toUTFz!LPCWSTR(name), 0, type, cast(ubyte*)dest.ptr, dest.length) == ERROR_SUCCESS, "RegSetValueEx failed");
		}

		uint getSize(string name)
		{
			DWORD size;
			enforce(RegQueryValueExW(key, toUTFz!LPCWSTR(name), null, null, null, &size) == ERROR_SUCCESS);
			return size;
		}
	}
}
else // POSIX
{
	import std.string;
	import std.stdio;
	import std.file;
	import std.path;
	import std.conv;

	// Cache values from memory, and save them to disk when the program exits.
	class Config
	{
		this(string appName = null, string companyName = null)
		{
			fileName = getRoamingAppProfile(appName) ~ "/config";
			if (!exists(fileName))
				return;
			foreach (line; File(fileName, "rt").byLine())
				if (line.length>0 && line[0]!='#')
				{
					int p = line.indexOf('=');
					if (p>0)
						values[line[0..p].idup] = line[p+1..$].idup;
				}
			instances ~= this;
		}

		~this()
		{
			assert(!dirty, "Dirty config destruction");
		}

		T read(T)(string name, T defaultValue = T.init)
		{
			auto pvalue = name in values;
			if (pvalue)
				return to!T(*pvalue);
			else
				return defaultValue;
		}

		void write(T)(string name, T value)
			if (is(typeof(to!string(T.init))))
		{
			values[name] = to!string(value);
			dirty = true;
		}

		void save()
		{
			if (!dirty)
				return;
			auto f = File(fileName, "wt");
			foreach (name, value; values)
				f.writefln("%s=%s", name, value);
			dirty = false;
		}

	private:
		string[string] values;
		string fileName;
		bool dirty;

		static Config[] instances;

		static ~this()
		{
			foreach (instance; instances)
				instance.save();
		}
	}
}
