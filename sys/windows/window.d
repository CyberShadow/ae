/**
 * Windows GUI window utility code.
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

module ae.sys.windows.window;
version (Windows):

import std.range;
import std.utf;

import ae.sys.windows.imports;
mixin(importWin32!q{winbase});
mixin(importWin32!q{winnt});
mixin(importWin32!q{winuser});

import ae.sys.windows.exception;
import ae.sys.windows.text;

struct WindowIterator
{
private:
	LPCWSTR szClassName, szWindowName;
	HWND hParent, h;

public:
	@property
	bool empty() const { return h is null; }

	@property
	HWND front() const { return cast(HWND)h; }

	void popFront()
	{
		h = FindWindowExW(hParent, h, szClassName, szWindowName);
	}
}

WindowIterator windowIterator(string szClassName, string szWindowName, HWND hParent=null)
{
	auto iterator = WindowIterator(toWStringz(szClassName), toWStringz(szWindowName), hParent);
	iterator.popFront(); // initiate search
	return iterator;
}

private static wchar[0xFFFF] textBuf = void;

string windowStringQuery(alias FUNC)(HWND h)
{
	SetLastError(0);
	auto result = FUNC(h, textBuf.ptr, textBuf.length);
	if (result)
		return textBuf[0..result].toUTF8();
	else
	{
		auto code = GetLastError();
		if (code)
			throw new WindowsException(code, __traits(identifier, FUNC));
		else
			return null;
	}
}

alias windowStringQuery!GetClassNameW  getClassName;
alias windowStringQuery!GetWindowTextW getWindowText;

/// Create an utility hidden window.
HWND createHiddenWindow(string name, WNDPROC proc)
{
	auto szName = toWStringz(name);

	HINSTANCE hInstance = GetModuleHandle(null);

	WNDCLASSEXW wcx;

	wcx.cbSize = wcx.sizeof;
	wcx.lpfnWndProc = proc;
	wcx.hInstance = hInstance;
	wcx.lpszClassName = szName;
	wenforce(RegisterClassExW(&wcx), "RegisterClassEx failed");

	HWND hWnd = CreateWindowW(
		szName,              // name of window class
		szName,              // title-bar string
		WS_OVERLAPPEDWINDOW, // top-level window
		CW_USEDEFAULT,       // default horizontal position
		CW_USEDEFAULT,       // default vertical position
		CW_USEDEFAULT,       // default width
		CW_USEDEFAULT,       // default height
		null,                // no owner window
		null,                // use class menu
		hInstance,           // handle to application instance
		null);               // no window-creation data
	wenforce(hWnd, "CreateWindow failed");

	return hWnd;
}
