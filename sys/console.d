/**
 * Enable UTF-8 output on Windows.
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

module ae.sys.console;

version(Windows)
{
	import std.c.windows.windows;
	UINT oldCP, oldOutputCP;

	shared static this()
	{
		oldCP = GetConsoleCP();
		oldOutputCP = GetConsoleOutputCP();

		SetConsoleCP(65001);
		SetConsoleOutputCP(65001);
	}

	shared static ~this()
	{
		SetConsoleCP(oldCP);
		SetConsoleOutputCP(oldOutputCP);
	}
}
