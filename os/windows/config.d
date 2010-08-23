module ng.os.windows.config;

import std.windows.charset;
import std.contracts;
import std.traits;
import std.utf;

import win32.windef;
import win32.winreg;

import ng.core.application;

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
				return to!T(ws);
			}
			else
				static assert(0, "Can't read values of type " ~ T.stringof);
		}
		catch (Throwable e)
			return defaultValue;
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
		enforce(RegQueryValueExW(key, toUTF16z(name), null, null, cast(ubyte*)dest.ptr, &size) == ERROR_SUCCESS, "RegQueryValueEx failed");
		enforce(size == dest.length, "Not enough data read");
	}

	uint getSize(string name)
	{
		DWORD size;
		enforce(RegQueryValueExW(key, toUTF16z(name), null, null, null, &size) == ERROR_SUCCESS);
		return size;
	}

	~this()
	{
		if (key)
			RegCloseKey(key);
	}
}
