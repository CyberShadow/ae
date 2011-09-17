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

module ae.ui.app.windows.main;

import core.runtime;
import std.c.windows.windows;
import std.windows.charset : toMBSz;

import ae.ui.app.main;

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

		result = ngmain(getArgs());

		Runtime.terminate(&exceptionHandler);
	}

	catch (Throwable o)				// catch any uncaught exceptions
	{
		MessageBoxA(null, toMBSz(o.toString()), "Error",
					MB_OK | MB_ICONEXCLAMATION);
		result = 1;				// failed
	}

	return result;
}

// Following code is from D's druntime\src\rt\dmain2.d

private import core.stdc.wchar_;
private import core.stdc.stdlib;

extern (Windows) alias int function() FARPROC;
extern (Windows) FARPROC    GetProcAddress(void*, in char*);
extern (Windows) void*      LoadLibraryA(in char*);
extern (Windows) int        FreeLibrary(void*);
extern (Windows) void*      LocalFree(void*);
extern (Windows) wchar_t*   GetCommandLineW();
extern (Windows) wchar_t**  CommandLineToArgvW(wchar_t*, int*);
extern (Windows) export int WideCharToMultiByte(uint, uint, wchar_t*, int, char*, int, char*, int);
pragma(lib, "shell32.lib"); // needed for CommandLineToArgvW

string[] getArgs()
{
	wchar_t*  wcbuf = GetCommandLineW();
	size_t    wclen = wcslen(wcbuf);
	int       wargc = 0;
	wchar_t** wargs = CommandLineToArgvW(wcbuf, &wargc);
	//assert(wargc == argc);

	size_t    cargl = WideCharToMultiByte(65001, 0, wcbuf, wclen, null, 0, null, 0);

	char*     cargp = cast(char*) alloca(cargl);
	char[][]  args  = ((cast(char[]*) alloca(wargc * (char[]).sizeof)))[0 .. wargc];

	for (size_t i = 0, p = 0; i < wargc; i++)
	{
		int wlen = wcslen(wargs[i]);
		int clen = WideCharToMultiByte(65001, 0, &wargs[i][0], wlen, null, 0, null, 0);
		args[i]  = cargp[p .. p+clen];
		p += clen; assert(p <= cargl);
		WideCharToMultiByte(65001, 0, &wargs[i][0], wlen, &args[i][0], clen, null, 0);
	}
	LocalFree(wargs);
	wargs = null;
	wargc = 0;

	return cast(string[])args;
}
