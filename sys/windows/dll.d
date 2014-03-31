/**
 * Windows DLL utility code.
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

module ae.sys.windows.dll;

import std.traits;

import win32.winbase;

import ae.sys.windows.misc;

/// Given a static function declaration, generate a loader with the same name in the current scope
/// that loads the function dynamically from the given DLL.
mixin template DynamicLoad(alias F, string DLL, string NAME=__traits(identifier, F))
{
	static ReturnType!F loader(ARGS...)(ARGS args)
	{
		import win32.windef;

		alias typeof(&F) FP;
		static FP fp = null;
		if (!fp)
		{
			HMODULE dll = wenforce(LoadLibrary(DLL), "LoadLibrary");
			fp = cast(FP)wenforce(GetProcAddress(dll, NAME), "GetProcAddress");
		}
		return fp(args);
	}

	mixin(`alias loader!(ParameterTypeTuple!F) ` ~ NAME ~ `;`);
}

///
unittest
{
	mixin DynamicLoad!(GetVersion, "kernel32.dll");
	GetVersion(); // called via GetProcAddress
}
