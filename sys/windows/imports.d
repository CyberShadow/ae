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
version (Windows):

// Using a string mixin instead of a mixin template due to
// https://issues.dlang.org/show_bug.cgi?id=15925
enum importWin32(string moduleName, string access = null, string selective = null) =
	access ~
		" import " ~
		(__VERSION__ >= 2070 ? "core.sys.windows" : "win32") ~
		"." ~
		moduleName ~
		" " ~
		(selective ? ":" : "") ~
		selective ~
		";";
