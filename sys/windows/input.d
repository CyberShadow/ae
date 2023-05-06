/**
 * Windows input utility code.
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

module ae.sys.windows.input;
version (Windows):

import ae.sys.windows.imports;
mixin(importWin32!q{winbase});
mixin(importWin32!q{windef});
mixin(importWin32!q{winuser});

/// Send WM_COPYDATA to the specified window.
void sendCopyData(HWND hWnd, DWORD n, const(void)[] buf)
{
	COPYDATASTRUCT cds;
	cds.dwData = n;
	cds.cbData = cast(uint)buf.length;
	cds.lpData = cast(PVOID)buf.ptr;
	SendMessage(hWnd, WM_COPYDATA, 0, cast(LPARAM)&cds);
}

private enum MAPVK_VK_TO_VSC = 0;

/// Simulate keyboard input.
void keyDown(ubyte c) { keybd_event(c, cast(ubyte)MapVirtualKey(c, MAPVK_VK_TO_VSC), 0              , 0); }
void keyUp  (ubyte c) { keybd_event(c, cast(ubyte)MapVirtualKey(c, MAPVK_VK_TO_VSC), KEYEVENTF_KEYUP, 0); } /// ditto

void press(ubyte c, uint delay=0)
{
	if (c) keyDown(c);
	Sleep(delay);
	if (c) keyUp(c);
	Sleep(delay);
} /// ditto

void keyDownOn(HWND h, ubyte c) { PostMessage(h, WM_KEYDOWN, c, MapVirtualKey(c, MAPVK_VK_TO_VSC) << 16); } /// ditto
void keyUpOn  (HWND h, ubyte c) { PostMessage(h, WM_KEYUP  , c, MapVirtualKey(c, MAPVK_VK_TO_VSC) << 16); } /// ditto

void pressOn(HWND h, ubyte c, uint delay=0)
{
	if (c) keyDownOn(h, c);
	Sleep(delay);
	if (c) keyUpOn(h, c);
	Sleep(delay);
} /// ditto
