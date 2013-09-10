/**
 * OS clipboard interaction.
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

module ae.sys.clipboard;

version (Windows)
{
	import win32.winbase;
	import win32.windef;
	import win32.winnls;
	import win32.winuser;
	import ae.sys.windows;
	import std.utf;
	import std.conv;

	void setClipboardText(string s)
	{
		auto ws = s.toUTF16();

		char[] as;
		int readLen;
		as.length = WideCharToMultiByte(0, 0, ws.ptr, ws.length, null, 0, null, null);

		if (as.length)
		{
			readLen = WideCharToMultiByte(0, 0, ws.ptr, ws.length, as.ptr, to!int(as.length), null, null);
			wenforce(readLen == as.length, "WideCharToMultiByte");
		}

		as ~= 0;
		ws ~= 0;

		setClipboard([
			ClipboardFormat(CF_TEXT,        as),
			ClipboardFormat(CF_UNICODETEXT, ws),
		]);
	}

	// Windows-specific
	struct ClipboardFormat { DWORD format; const (void)[] data; }
	void setClipboard(in ClipboardFormat[] formats)
	{
		wenforce(OpenClipboard(null), "OpenClipboard");
		scope(exit) wenforce(CloseClipboard(), "CloseClipboard");
		EmptyClipboard();
		foreach (ref format; formats)
		{
			HGLOBAL hBuf = wenforce(GlobalAlloc(GMEM_MOVEABLE, format.data.length), "GlobalAlloc");
			scope(failure) wenforce(!GlobalFree(hBuf), "GlobalFree");
			LPVOID buf = wenforce(GlobalLock(hBuf), "GlobalLock");
			buf[0..format.data.length] = format.data[];
			wenforce(GlobalUnlock(hBuf) || GetLastError()==NO_ERROR, "GlobalUnlock");
			wenforce(SetClipboardData(format.format, hBuf), "SetClipboardData");
		}
	}

}
