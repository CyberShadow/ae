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

mixin template importWin32(string moduleName, string access = "")
{
	static if (__VERSION__ >= 2070)
		mixin(access ~ " import core.sys.windows." ~ moduleName ~ ";");
	else
		mixin(access ~ " import win32." ~ moduleName ~ ";");
}
