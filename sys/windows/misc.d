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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.windows.misc;
version (Windows):

import std.string;

import ae.sys.windows.imports;
mixin(importWin32!q{winbase});
mixin(importWin32!q{wincon});
mixin(importWin32!q{winnt});
mixin(importWin32!q{winuser});

import ae.sys.windows.exception;
import ae.sys.windows.text;

/// Construct a `LARGE_INTEGER`.
LARGE_INTEGER largeInteger(long n) pure nothrow @nogc
{
	LARGE_INTEGER li; li.QuadPart = n; return li;
}

/// Construct a `ULARGE_INTEGER`.
ULARGE_INTEGER ulargeInteger(ulong n) pure nothrow @nogc
{
	ULARGE_INTEGER li; li.QuadPart = n; return li;
}

/// Construct an `ulong` from two `DWORD`s using `ULANGE_INTEGER`.
ulong makeUlong(DWORD dwLow, DWORD dwHigh) pure nothrow @nogc
{
	ULARGE_INTEGER li;
	li.LowPart  = dwLow;
	li.HighPart = dwHigh;
	return li.QuadPart;
}

// ***************************************************************************

// Messages

/// Pump pending messages.
void processWindowsMessages()()
{
	MSG m;
	while (PeekMessageW(&m, null, 0, 0, PM_REMOVE))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

/// Pump messages until a WM_QUIT.
void messageLoop()()
{
	MSG m;
	while (GetMessageW(&m, null, 0, 0))
	{
		TranslateMessage(&m);
		DispatchMessageW(&m);
	}
}

// ***************************************************************************

/// `MessageBoxW` wrapper.
int messageBox()(string message, string title, int style=0)
{
	return MessageBoxW(null, toWStringz(message), toWStringz(title), style);
}

/// `GetLastInputInfo` wrapper.
uint getLastInputInfo()()
{
	LASTINPUTINFO lii = { LASTINPUTINFO.sizeof };
	wenforce(GetLastInputInfo(&lii), "GetLastInputInfo");
	return lii.dwTime;
}

// ***************************************************************************

/// Hides the console window, but only if we are the owner.
void hideOwnConsoleWindow()()
{
	HWND w = GetConsoleWindow();
	if (!w)
		return;
	DWORD pid;
	GetWindowThreadProcessId(w, &pid);
	if (pid == GetCurrentProcessId())
		ShowWindow(w, SW_HIDE);
}

// ***************************************************************************

/// Returns true if the host Windows OS is 64-bit.
bool isWin64()
{
	version (D_LP64)
		return true; // host must be 64-bit if this compiles
	else
	{
		import core.sys.windows.winbase : IsWow64Process, GetCurrentProcess;
		int is64;
		IsWow64Process(GetCurrentProcess(), &is64).wenforce("IsWow64Process");
		return !!is64;
	}
}

/// Returns Wine version, or null if not running under Wine.
string getWineVersion()
{
	auto ntdll = GetModuleHandle("ntdll.dll");
	if (!ntdll)
		return null;
	alias wine_get_version_t = extern(C) const(char*) function();
	auto wine_get_version = cast(wine_get_version_t)GetProcAddress(ntdll, "wine_get_version");
	if (!wine_get_version)
		return null;
	import std.conv : to;
	return wine_get_version().to!string();
}
