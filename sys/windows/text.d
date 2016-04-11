/**
 * Miscellaneous Windows utility code.
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

module ae.sys.windows.text;
version (Windows):

import core.sys.windows.windows;

import std.utf;

string fromWString(in wchar[] buf)
{
	foreach (i, c; buf)
		if (!c)
			return toUTF8(buf[0..i]);
	return toUTF8(buf);
}

string fromWString(in wchar* buf)
{
	if (!buf) return null;
	const(wchar)* p = buf;
	for (; *p; p++) {}
	return toUTF8(buf[0..p-buf]);
}

LPCWSTR toWStringz(string s)
{
	return s is null ? null : toUTF16z(s);
}
