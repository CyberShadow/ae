/**
 * Time parsing functions.
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

module ae.utils.time.parse;

import core.time : minutes, seconds, dur;

import std.exception : enforce;
import std.conv : to;
import std.ascii : isDigit, isWhite;
import std.datetime;
import std.string : indexOf;
import std.typecons : Rebindable;
import std.string : strip, startsWith;

import ae.utils.time.common;

private struct ParseContext(Char, bool checked)
{
	int year=0, month=1, day=1, hour=0, minute=0, second=0, usecs=0;
	int hour12 = 0; bool pm;
	Rebindable!(immutable(TimeZone)) tz;
	int dow = -1;
	Char[] t;
	bool escaping;

	void need(size_t n)()
	{
		static if (checked)
			enforce(t.length >= n, "Not enough characters in date string");
	}

	auto take(size_t n)()
	{
		need!n();
		auto result = t[0..n];
		t = t[n..$];
		return result;
	}

	char takeOne()
	{
		need!1();
		auto result = t[0];
		t = t[1..$];
		return result;
	}

	R takeNumber(size_t n, sizediff_t maxP = -1, R = int)()
	{
		enum max = maxP == -1 ? n : maxP;
		need!n();
		foreach (i, c; t[0..n])
			enforce((i==0 && c=='-') || isDigit(c) || isWhite(c), "Number expected");
		static if (n == max)
			enum i = n;
		else
		{
			auto i = n;
			while (i < max && (checked ? i < t.length : true) && isDigit(t[i]))
				i++;
		}
		auto s = t[0..i];
		t = t[i..$];
		return s.strip().to!R();
	}

	int takeWord(in string[] words, string name)
	{
		foreach (idx, string word; words)
		{
			static if (checked)
				bool b = t.startsWith(word);
			else
				bool b = t[0..word.length] == word;
			if (b)
			{
				t = t[word.length..$];
				return cast(int)idx;
			}
		}
		throw new Exception(name ~ " expected");
	}

	char peek()
	{
		need!1();
		return *t.ptr;
	}
}

private void parseToken(alias c, alias context)()
{
	with (context)
	{
		// TODO: check if the compiler optimizes this check away
		// in the compile-time version. If not, "escaping" needs to
		// be moved into an alias parameter.
		if (escaping)
		{
			enforce(takeOne() == c, c ~ " expected");
			escaping = false;
			return;
		}

		switch (c)
		{
			// Day
			case 'd':
				day = takeNumber!(2)();
				break;
			case 'D':
				dow = takeWord(WeekdayShortNames, "Weekday");
				break;
			case 'j':
				day = takeNumber!(1, 2);
				break;
			case 'l':
				dow = takeWord(WeekdayLongNames, "Weekday");
				break;
			case 'N':
				dow = takeNumber!1 % 7;
				break;
			case 'S': // ordinal suffix
				take!2;
				break;
			case 'w':
				dow = takeNumber!1;
				break;
			//case 'z': TODO

			// Week
			//case 'W': TODO

			// Month
			case 'F':
				month = takeWord(MonthLongNames, "Month") + 1;
				break;
			case 'm':
				month = takeNumber!2;
				break;
			case 'M':
				month = takeWord(MonthShortNames, "Month") + 1;
				break;
			case 'n':
				month = takeNumber!(1, 2);
				break;
			case 't':
				takeNumber!(1, 2); // TODO: validate DIM?
				break;

			// Year
			case 'L':
				takeNumber!1; // TODO: validate leapness?
				break;
			// case 'o': TODO (ISO 8601 year number)
			case 'Y':
				year = takeNumber!4;
				break;
			case 'y':
				year = takeNumber!2;
				if (year > 50) // TODO: find correct logic for this
					year += 1900;
				else
					year += 2000;
				break;

			// Time
			case 'a':
				pm = takeWord(["am", "pm"], "am/pm")==1;
				break;
			case 'A':
				pm = takeWord(["AM", "PM"], "AM/PM")==1;
				break;
			// case 'B': TODO (Swatch Internet time)
			case 'g':
				hour12 = takeNumber!(1, 2);
				break;
			case 'G':
				hour = takeNumber!(1, 2);
				break;
			case 'h':
				hour12 = takeNumber!2;
				break;
			case 'H':
				hour = takeNumber!2;
				break;
			case 'i':
				minute = takeNumber!2;
				break;
			case 's':
				second = takeNumber!2;
				break;
			case 'u':
				usecs = takeNumber!6;
				break;
			case 'E': // not standard
				usecs = 1000 * takeNumber!3;
				break;

			// Timezone
			// case 'e': ???
			case 'I':
				takeNumber!1;
				break;
			case 'O':
			{
				if (peek() == 'Z')
				{
					t = t[1..$];
					tz = UTC();
				}
				else
				if (peek() == 'G')
				{
					enforce(take!3() == "GMT", "GMT expected");
					tz = UTC();
				}
				else
				{
					auto tzStr = take!5();
					enforce(tzStr[0]=='-' || tzStr[0]=='+', "- / + expected");
					auto n = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[3..5])) * (tzStr[0]=='-' ? -1 : 1);
					tz = new immutable(SimpleTimeZone)(minutes(n));
				}
				break;
			}
			case 'P':
			{
				auto tzStr = take!6();
				enforce(tzStr[0]=='-' || tzStr[0]=='+', "- / + expected");
				enforce(tzStr[3]==':', ": expected");
				auto n = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[4..6])) * (tzStr[0]=='-' ? -1 : 1);
				tz = new immutable(SimpleTimeZone)(minutes(n));
				break;
			}
			case 'T':
				version(Posix)
					tz = PosixTimeZone.getTimeZone(t.idup);
				else
				version(Windows)
					tz = WindowsTimeZone.getTimeZone(t.idup);

				t = null;
				break;
			case 'Z':
			{
				// TODO: is this correct?
				auto n = takeNumber!(1, 6);
				tz = new immutable(SimpleTimeZone)(seconds(n));
				break;
			}

			// Full date/time
			//case 'c': TODO
			//case 'r': TODO
			//case 'U': TODO

			// Escape next character
			case '\\':
				escaping = true;
				break;

			// Other characters (whitespace, delimiters)
			default:
			{
				enforce(t.length && t[0]==c, c~ " expected or unsupported format character");
				t = t[1..$];
			}
		}
	}
}

import ae.utils.meta;

private SysTime parseTimeImpl(alias fmt, bool checked, C)(C[] t, immutable TimeZone defaultTZ = null)
{
	ParseContext!(C, checked) context;
	context.t = t;
	context.tz = defaultTZ;

	foreach (c; CTIterate!fmt)
		parseToken!(c, context)();

	enforce(context.t.length == 0, "Left-over characters: " ~ context.t);

	SysTime result;

	with (context)
	{
		if (hour12)
			hour = hour12%12 + (pm ? 12 : 0);

		// Compatibility with both <=2.066 and >=2.067
		static if (__traits(hasMember, SysTime, "fracSecs"))
			auto frac = dur!"usecs"(usecs);
		else
			auto frac = FracSec.from!"usecs"(usecs);

		result = SysTime(
			DateTime(year, month, day, hour, minute, second),
			frac,
			tz);

		if (dow >= 0)
			enforce(result.dayOfWeek == dow, "Mismatching weekday");
	}

	return result;
}

/// Parse the given string into a SysTime, using the format spec fmt.
/// This version generates specialized code for the given fmt.
SysTime parseTime(string fmt, C)(C[] t, immutable TimeZone tz = null)
{
	// Omit length checks if we know the input string is long enough
	enum maxLength = timeFormatSize(fmt);
	if (t.length < maxLength)
		return parseTimeImpl!(fmt, true )(t, tz);
	else
		return parseTimeImpl!(fmt, false)(t, tz);
}

/// Parse the given string into a SysTime, using the format spec fmt.
/// This version parses fmt at runtime.
SysTime parseTimeUsing(C)(C[] t, in char[] fmt)
{
	return parseTimeImpl!(fmt, true)(t);
}

deprecated SysTime parseTime(C)(const(char)[] fmt, C[] t)
{
	return t.parseTimeUsing(fmt);
}

version(unittest) import ae.utils.time.format;

unittest
{
	const s0 = "Tue Jun 07 13:23:19 GMT+0100 2011";
	//enum t = s0.parseTime!(TimeFormats.STD_DATE); // https://d.puremagic.com/issues/show_bug.cgi?id=12042
	auto t = s0.parseTime!(TimeFormats.STD_DATE);
	auto s1 = t.formatTime(TimeFormats.STD_DATE);
	assert(s0 == s1, s0 ~ "/" ~ s1);
	auto t1 = s0.parseTimeUsing(TimeFormats.STD_DATE);
	assert(t == t1);
}

unittest
{
	"Tue, 21 Nov 2006 21:19:46 +0000".parseTime!(TimeFormats.RFC2822);
	"Tue, 21 Nov 2006 21:19:46 +0000".parseTimeUsing(TimeFormats.RFC2822);
}

unittest
{
	const char[] s = "Tue, 21 Nov 2006 21:19:46 +0000";
	s.parseTime!(TimeFormats.RFC2822);
}

unittest
{
	__TIMESTAMP__.parseTime!(TimeFormats.CTIME);
}

/// Parse log timestamps generated by ae.sys.log,
/// including all previous versions of it.
SysTime parseLogTimestamp(string s)
{
	enforce(s.length, "Empty line");

	if (s[0] == '[') // Input is an entire line
	{
		auto i = s.indexOf(']');
		enforce(i > 0, "Unmatched [");
		s = s[1..i];
	}

	switch (s.length)
	{
		case 33: // Fri Jun 29 05:44:13 GMT+0300 2007
			return s.parseTime!(TimeFormats.STD_DATE)(UTC());
		case 23:
			if (s[4] == '.') // 2015.02.24 21:03:01.868
				return s.parseTime!"Y.m.d H:i:s.E"(UTC());
			else // 2015-11-04 00:00:45.964
				return s.parseTime!"Y-m-d H:i:s.E"(UTC());
		case 26: // 2015-11-04 00:00:45.964983
			return s.parseTime!"Y-m-d H:i:s.u"(UTC());
		default:
			throw new Exception("Unknown log timestamp format: " ~ s);
	}
}
