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

import std.traits;

void put(S, N)(ref S sink, N n)
	if (IsStringSink!S && is(N : long) && !isSomeChar!N)
{
	char[21] buf = void;
	char* p = buf.ptr+buf.length;

	static if (isSigned!N)
	{
		bool negative;
		if (n<0)
			negative = true, n = -n;
	}
	do
	{
		*--p = '0' + n%10;
		n = n/10;
	} while (n);
	static if (isSigned!N)
		if (negative)
			*--p = '-';

	sink.put(p[0 .. buf.ptr + buf.length - p]);
}

unittest
{
	import std.conv;
	void test(N)(N n) { StringBuilder sb; put(sb, n); assert(sb.get() == text(n), sb.get() ~ "!=" ~ text(n)); }
	test(0);
	test(1);
	test(-1);
	test(0xFFFFFFFFFFFFFFFFLU);
}

// **************************************************************************

