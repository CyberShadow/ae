/**
 * ae.ui.app.posix.main
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

module ae.ui.app.posix.main;

import std.stdio;
import ae.utils.exception;
import ae.ui.app.application;

int main(string[] args)
{
	try
		return runApplication(args);
	catch (Throwable o)
	{
		stderr.writeln(formatException(o));
		return 1;
	}
}
