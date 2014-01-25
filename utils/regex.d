/**
 * std.regex helpers
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

module ae.utils.regex;

import std.conv;
import std.exception;
import std.regex;

import ae.utils.text;

// ************************************************************************

/// Allows specifying regular expression patterns in expressions,
/// without having to compile them each time.
/// Example:
///   if (text.match(`^\d+$`)) {}    // old code - recompiles every time
///   if (text.match(re!`^\d+$`)) {} // new code - recompiles once

Regex!char re(string pattern)
{
	static Regex!char r;
	if (r.empty)
		r = regex(pattern);
	return r;
}

/// Lua-like pattern matching.
bool matchInto(S, R, Args...)(S s, R r, ref Args args)
{
	auto m = s.match(r);
	if (m)
	{
		foreach (n, ref arg; args)
			arg = to!(Args[n])(m.captures[n+1]);
		return true;
	}
	return false;
}

///
unittest
{
	string name, fruit;
	int count;
	assert("Mary has 5 apples"
		.matchInto(`^(\w+) has (\d+) (\w+)$`, name, count, fruit));
	assert(name == "Mary" && count == 5 && fruit == "apples");
}

// ************************************************************************
