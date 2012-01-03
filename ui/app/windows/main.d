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
 * Portions created by the Initial Developer are Copyright (C) 2011-2012
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

	size_t    cargl = WideCharToMultiByte(CP_UTF8, 0, wcbuf, wclen, null, 0, null, null);

	char*     cargp = cast(char*) malloc(cargl);
	char[][]  args  = ((cast(char[]*) malloc(wargc * (char[]).sizeof)))[0 .. wargc];

	for (size_t i = 0, p = 0; i < wargc; i++)
	{
		int wlen = wcslen(wargs[i]);
		int clen = WideCharToMultiByte(CP_UTF8, 0, &wargs[i][0], wlen, null, 0, null, null);
		args[i]  = cargp[p .. p+clen];
		p += clen; assert(p <= cargl);
		WideCharToMultiByte(CP_UTF8, 0, &wargs[i][0], wlen, &args[i][0], clen, null, null);
	}
	LocalFree(cast(HLOCAL)wargs);
	wargs = null;
	wargc = 0;

	return cast(string[])args;
}
