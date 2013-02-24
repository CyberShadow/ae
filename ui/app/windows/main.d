/**
 * ae.ui.app.windows.main
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

module ae.ui.app.windows.main;

import core.runtime;
import std.utf;

import win32.windef;
import win32.winuser;

import ae.ui.app.application;
import ae.utils.exception;

extern (Windows)
int WinMain(HINSTANCE hInstance,
            HINSTANCE hPrevInstance,
            LPSTR lpCmdLine,
            int nCmdShow)
{
	int result;

	void exceptionHandler(Throwable e)
	{
		throw e;
	}

	try
	{		
		Runtime.initialize(&exceptionHandler);
		result = runApplication(getArgs());
		Runtime.terminate(&exceptionHandler);
	}

	catch (Throwable o)				// catch any uncaught exceptions
	{
		MessageBoxA(null, toUTFz!LPCSTR(formatException(o)), "Error",
					MB_OK | MB_ICONEXCLAMATION);
		result = 1;				// failed
	}

	return result;
}

private:
// Following code is adapted from D's druntime\src\rt\dmain2.d

import core.stdc.wchar_;
import core.stdc.stdlib;

import win32.winbase;
import win32.shellapi;
import win32.winnls;

string[] getArgs()
{
	wchar_t*  wcbuf = GetCommandLineW();
	size_t    wclen = wcslen(wcbuf);
	int       wargc = 0;
	wchar_t** wargs = CommandLineToArgvW(wcbuf, &wargc);

	size_t    cargl = WideCharToMultiByte(CP_UTF8, 0, wcbuf, cast(uint)wclen, null, 0, null, null);

	char*     cargp = cast(char*) malloc(cargl);
	char[][]  args  = ((cast(char[]*) malloc(wargc * (char[]).sizeof)))[0 .. wargc];

	for (size_t i = 0, p = 0; i < wargc; i++)
	{
		size_t wlen = wcslen(wargs[i]);
		size_t clen = WideCharToMultiByte(CP_UTF8, 0, &wargs[i][0], cast(uint)wlen, null, 0, null, null);
		args[i]  = cargp[p .. p+clen];
		p += clen; assert(p <= cargl);
		WideCharToMultiByte(CP_UTF8, 0, &wargs[i][0], cast(uint)wlen, &args[i][0], cast(uint)clen, null, null);
	}
	LocalFree(cast(HLOCAL)wargs);
	wargs = null;
	wargc = 0;

	return cast(string[])args;
}
