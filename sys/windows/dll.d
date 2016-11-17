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
version (Windows):

import ae.sys.windows.imports;
mixin(importWin32!q{winbase});
mixin(importWin32!q{windef});

/// Loads or retrieves the handle of a DLL.
/// As there will be only one template instantiation
/// per unique DLL string, LoadLibrary will be called
/// at most once per unique "dll" parameter.
@property HMODULE moduleHandle(string dll)()
{
	import ae.sys.windows.exception;
	static HMODULE hModule = null;
	if (!hModule)
		hModule = LoadLibrary(dll).wenforce("LoadLibrary");
	return hModule;
}

/// Given a static function declaration, generate a loader with the same name in the current scope
/// that loads the function dynamically from the given DLL.
mixin template DynamicLoad(alias F, string DLL, string NAME=__traits(identifier, F))
{
	static import std.traits;

	static std.traits.ReturnType!F loader(ARGS...)(ARGS args)
	{
		import ae.sys.windows.exception;
		import ae.sys.windows.imports;
		mixin(importWin32!q{winbase});

		alias typeof(&F) FP;
		static FP fp = null;
		if (!fp)
			fp = cast(FP)wenforce(GetProcAddress(moduleHandle!DLL, NAME), "GetProcAddress");
		return fp(args);
	}

	mixin(`alias loader!(std.traits.ParameterTypeTuple!F) ` ~ NAME ~ `;`);
}

/// Ditto
mixin template DynamicLoadMulti(string DLL, FUNCS...)
{
	static if (FUNCS.length)
	{
		mixin DynamicLoad!(FUNCS[0], DLL);
		mixin DynamicLoadMulti!(DLL, FUNCS[1..$]);
	}
}

version(unittest) mixin(importWin32!q{winuser});

///
unittest
{
	mixin DynamicLoad!(GetVersion, "kernel32.dll");
	GetVersion(); // called via GetProcAddress

	// Multiple imports
	mixin DynamicLoadMulti!("user32.dll", GetDC, ReleaseDC);
}
