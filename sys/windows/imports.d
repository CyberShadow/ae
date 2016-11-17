/**
 * win32 / core.sys.windows package selection.
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

module ae.sys.windows.imports;

// Using a string mixin instead of a mixin template due to
// https://issues.dlang.org/show_bug.cgi?id=15925
template importWin32(string moduleName, string access = null, string selective = null)
{
	// All Druntime headers are version(Windows)
	version (Windows)
		enum useDruntime = __VERSION__ >= 2070;
	else
		enum useDruntime = false;

	enum importWin32 =
		access ~
			" import " ~
			(useDruntime ? "core.sys.windows" : "win32") ~
			"." ~
			moduleName ~
			" " ~
			(selective ? ":" : "") ~
			selective ~
			";";
}
