/**
 * Time string formatting and such.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.time;

public import ae.utils.time.common;
public import ae.utils.time.format;
public import ae.utils.time.fpdur;
public import ae.utils.time.parse;
public import ae.utils.time.parsedur;
public import ae.utils.time.types;

debug(ae_unittest) unittest
{
	import core.stdc.time : time_t;

	enum f = `U\.9`;
	static if (time_t.sizeof == 4)
		assert("1234567890.123456789".parseTime!f.formatTime!f == "1234567890.123456700");
	else
		assert("123456789012.123456789".parseTime!f.formatTime!f == "123456789012.123456700");
}

// ***************************************************************************

// fpdur conflict test
debug(ae_unittest) unittest
{
	import std.datetime;
	import ae.utils.time.fpdur;
	static assert(1.5.seconds == 1500.msecs);
}
