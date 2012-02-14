/**
 * Exception formatting
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

module ae.utils.exception;

import std.string;

string formatException(Throwable e)
{
	string[] descriptions;
	while (e)
		descriptions ~= e.toString(),
		e = e.next;
	return descriptions.join("\n===================================\n");
}
