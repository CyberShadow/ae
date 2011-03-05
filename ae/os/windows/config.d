module ae.os.windows.config;

import std.windows.charset;
import std.exception;
import std.traits;
import std.utf;
import std.conv;

import win32.windef;
import win32.winreg;

import ae.core.application;

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
		enforce(RegQueryValueExW(key, toUTF16z(name), null, null, cast(ubyte*)dest.ptr, &size) == ERROR_SUCCESS, "RegQueryValueEx failed");
		enforce(size == dest.length, "Not enough data read");
	}

	void writeRaw(string name, const(void)[] dest, DWORD type)
	{
		if (!key) openKey();
		enforce(RegSetValueExW(key, toUTF16z(name), 0, type, cast(ubyte*)dest.ptr, dest.length) == ERROR_SUCCESS, "RegSetValueEx failed");
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
