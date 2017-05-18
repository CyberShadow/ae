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
	import std.utf;
	import std.conv;

	import ae.sys.windows.exception;

	import ae.sys.windows.imports;
	mixin(importWin32!q{winbase});
	mixin(importWin32!q{windef});
	mixin(importWin32!q{winnls});
	mixin(importWin32!q{winuser});

	void setClipboardText(string s)
	{
		auto ws = s.toUTF16();

		char[] as;
		int readLen;
		as.length = WideCharToMultiByte(0, 0, ws.ptr, ws.length.to!DWORD, null, 0, null, null);

		if (as.length)
		{
			readLen = WideCharToMultiByte(0, 0, ws.ptr, ws.length.to!DWORD, as.ptr, to!int(as.length), null, null);
			wenforce(readLen == as.length, "WideCharToMultiByte");
		}

		as ~= 0;
		ws ~= 0;

		setClipboard([
			ClipboardFormat(CF_TEXT,        as),
			ClipboardFormat(CF_UNICODETEXT, ws),
		]);
	}

	string getClipboardText()
	{
		static immutable DWORD[] textFormat = [CF_UNICODETEXT];
		auto format = getClipboard(textFormat)[0];
		wchar[] ws = (cast(wchar[])format.data)[0..$-1];
		return ws.toUTF8();
	}

	// Windows-specific

	/// One format entry in the Windows clipboard.
	struct ClipboardFormat
	{
		DWORD format;
		const (void)[] data;

		string getName()
		{
			import ae.utils.meta : progn;

			wchar[256] sbuf;
			wchar[] buf = sbuf[];
			int ret;
			do
			{
				ret = wenforce(GetClipboardFormatNameW(format, buf.ptr, buf.length.to!DWORD), "GetClipboardFormatNameW");
			} while (ret == buf.length ? progn(buf.length *=2, true) : false);
			return buf[0..ret].toUTF8();
		}
	}

	/// Get clipboard data for the specified (default: all) formats.
	ClipboardFormat[] getClipboard(in DWORD[] desiredFormatsP = null)
	{
		const(DWORD)[] desiredFormats = desiredFormatsP;

		wenforce(OpenClipboard(null), "OpenClipboard");
		scope(exit) wenforce(CloseClipboard(), "CloseClipboard");

		if (desiredFormats is null)
		{
			auto allFormats = new DWORD[CountClipboardFormats()];
			DWORD previous = 0;
			foreach (ref f; allFormats)
				f = previous = EnumClipboardFormats(previous);
			desiredFormats = allFormats;
		}

		auto result = new ClipboardFormat[desiredFormats.length];
		foreach (n, ref r; result)
		{
			r.format = desiredFormats[n];
			auto hBuf = wenforce(GetClipboardData(r.format), "GetClipboardData");
			auto size = GlobalSize(hBuf);
			LPVOID buf = wenforce(GlobalLock(hBuf), "GlobalLock");
			r.data = buf[0..size].dup;
			wenforce(GlobalUnlock(hBuf) || GetLastError()==NO_ERROR, "GlobalUnlock");
		}

		return result;
	}

	void setClipboard(in ClipboardFormat[] formats)
	{
		wenforce(OpenClipboard(null), "OpenClipboard");
		scope(exit) wenforce(CloseClipboard(), "CloseClipboard");
		EmptyClipboard();
		foreach (ref format; formats)
		{
			HGLOBAL hBuf = wenforce(GlobalAlloc(GMEM_MOVEABLE, format.data.length.to!DWORD), "GlobalAlloc");
			scope(failure) wenforce(!GlobalFree(hBuf), "GlobalFree");
			LPVOID buf = wenforce(GlobalLock(hBuf), "GlobalLock");
			buf[0..format.data.length] = format.data[];
			wenforce(GlobalUnlock(hBuf) || GetLastError()==NO_ERROR, "GlobalUnlock");
			wenforce(SetClipboardData(format.format, hBuf), "SetClipboardData");
		}
	}
}
else
version (Posix)
{
	import std.process;
	import std.exception;

	import ae.utils.path;

	void setClipboardText(string s)
	{
		string[] cmdLine;
		if (haveExecutable("xclip"))
			cmdLine = ["xclip", "-in", "-selection", "clipboard"];
		else
		if (haveExecutable("xsel"))
			cmdLine = ["xsel", "--input", "--clipboard"];
		else
		if (haveExecutable("pbcopy"))
			cmdLine = ["pbcopy"];
		else
			throw new Exception("No clipboard management programs detected");
		auto p = pipe();
		auto pid = spawnProcess(cmdLine, p.readEnd);
		p.writeEnd.rawWrite(s);
		p.writeEnd.close();
		enforce(pid.wait() == 0, cmdLine[0] ~ " failed");
	}

	string getClipboardText()
	{
		string[] cmdLine;
		if (haveExecutable("xclip"))
			cmdLine = ["xclip", "-out", "-selection", "clipboard"];
		else
		if (haveExecutable("xsel"))
			cmdLine = ["xsel", "--output", "--clipboard"];
		else
		if (haveExecutable("pbpaste"))
			cmdLine = ["pbpaste"];
		else
			throw new Exception("No clipboard management programs detected");
		auto result = execute(cmdLine);
		enforce(result.status == 0, cmdLine[0] ~ " failed");
		return result.output;
	}
}
