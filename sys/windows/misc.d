/**
 * Miscellaneous Windows utility code.
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

module ae.sys.windows.misc;

import std.string;
import std.utf;

import win32.winbase;
import win32.wincon;
import win32.winnt;
import win32.winuser;

string fromWString(in wchar[] buf)
{
	foreach (i, c; buf)
		if (!c)
			return toUTF8(buf[0..i]);
	return toUTF8(buf);
}

string fromWString(in wchar* buf)
{
	const(wchar)* p = buf;
	for (; *p; p++) {}
	return toUTF8(buf[0..p-buf]);
}

LPCWSTR toWStringz(string s)
{
	return s is null ? null : toUTF16z(s);
}

LARGE_INTEGER largeInteger(long n)
{
	LARGE_INTEGER li; li.QuadPart = n; return li;
}

ULARGE_INTEGER ulargeInteger(ulong n)
{
	ULARGE_INTEGER li; li.QuadPart = n; return li;
}

ulong makeUlong(DWORD dwLow, DWORD dwHigh)
{
	ULARGE_INTEGER li;
	li.LowPart  = dwLow;
	li.HighPart = dwHigh;
	return li.QuadPart;
}

// ***************************************************************************

class WindowsException : Exception
{
	DWORD code;

	this(DWORD code, string str=null)
	{
		this.code = code;

		wchar *lpMsgBuf = null;
		FormatMessageW(
			FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
			null,
			code,
			MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
			cast(LPWSTR)&lpMsgBuf,
			0,
			null);

		auto message = lpMsgBuf.fromWString();
		if (lpMsgBuf)
			LocalFree(lpMsgBuf);

		message = strip(message);
		message ~= format(" (error %d)", code);
		if (str)
			message = str ~ ": " ~ message;

		super(message);
	}
}

T wenforce(T)(T cond, string str=null)
{
	if (cond)
		return cond;

	throw new WindowsException(GetLastError(), str);
}

// ***************************************************************************

// Messages

void processWindowsMessages()
{
	MSG m;
	while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

void messageLoop()
{
	MSG m;
	while (GetMessageW(&m, null, 0, 0))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

// ***************************************************************************

int messageBox(string message, string title, int style=0)
{
	return MessageBoxW(null, toWStringz(message), toWStringz(title), style);
}

uint getLastInputInfo()
{
	LASTINPUTINFO lii = { LASTINPUTINFO.sizeof };
	wenforce(GetLastInputInfo(&lii), "GetLastInputInfo");
	return lii.dwTime;
}

// ***************************************************************************

/// Hides the console window, but only if we are the owner.
void hideOwnConsoleWindow()
{
	HWND w = GetConsoleWindow();
	if (!w)
		return;
	DWORD pid;
	GetWindowThreadProcessId(w, &pid);
	if (pid == GetCurrentProcessId())
		ShowWindow(w, SW_HIDE);
}
