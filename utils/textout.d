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

/// Sink which simply copies data to a pointer and advances it.
/// No reallocation, no bounds check - unsafe.
struct BlindWriter(T)
{
	T* ptr;

	void put(T v)
	{
		*ptr++ = v;
	}

	void put(in T[] v)
	{
		import core.stdc.string;
		memcpy(ptr, v.ptr, v.length*T.sizeof);
		ptr += v.length;
	}
}

unittest
{
	import ae.utils.time;
	import std.datetime;

	char[64] buf;
	auto writer = BlindWriter!char(buf.ptr);

	auto time = SysTime(DateTime(2010, 7, 4, 7, 6, 12), UTC());
	putTime(writer, TimeFormats.ISO8601, time);
	auto timeStr = buf[0..writer.ptr-buf.ptr];
	assert(timeStr == "2010-07-04T07:06:12+0000", timeStr.idup);
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
import ae.utils.text : toDec, DecimalSize;

// Decimal
void put(S, N)(ref S sink, N n)
	if (IsStringSink!S && is(N : long) && !isSomeChar!N)
{
	char[DecimalSize!N] buf = void;
	sink.put(toDec(n, buf));
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

