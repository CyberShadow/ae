/**
 * Fast string building with minimum heap allocations.
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

module ae.utils.textout;

import ae.utils.appender;

alias FastAppender!(immutable(char)) StringBuilder;
alias FastAppender!           char   StringBuffer;

unittest
{
	StringBuilder sb;
	sb.put("Hello", ' ', "world!");
	assert(sb.get() == "Hello world!");
}

unittest
{
	StringBuilder sb;
	foreach (n; 0..4096)
		sb.put("Hello", " ", "world!");
	string s;
	foreach (n; 0..4096)
		s ~= "Hello world!";
	assert(sb.get() == s);
}

// **************************************************************************

template IsStringSink(T)
{
	enum IsStringSink = is(typeof(T.init.put("Test")));
}

// **************************************************************************

void put(S)(ref S sink, dchar c)
	if (IsStringSink!S)
{
	import std.utf;
	char[4] buf;
	auto size = encode(buf, c);
	sink.put(buf[0..size]);
}

unittest
{
	StringBuilder sb;
	put(sb, 'Я');
	assert(sb.get() == "Я");
}

// **************************************************************************

