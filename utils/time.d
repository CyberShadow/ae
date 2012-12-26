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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.time;

import std.datetime;
import std.string;
import std.conv : text;
import std.utf : decode, stride;
import std.math : abs;
import ae.utils.textout;

struct TimeFormats
{
static:
	const ATOM = `Y-m-d\TH:i:sP`;
	const COOKIE = `l, d-M-y H:i:s T`;
	const ISO8601 = `Y-m-d\TH:i:sO`;
	const RFC822 = `D, d M y H:i:s O`;
	const RFC850 = `l, d-M-y H:i:s T`;
	const RFC1036 = `D, d M y H:i:s O`;
	const RFC1123 = `D, d M Y H:i:s O`;
	const RFC2822 = `D, d M Y H:i:s O`;
	const RFC3339 = `Y-m-d\TH:i:sP`;
	const RSS = `D, d M Y H:i:s O`;
	const W3C = `Y-m-d\TH:i:sP`;

	const HTML5DATE = `Y-m-d`;

	/// Format produced by std.date.toString, e.g. "Tue Jun 07 13:23:19 GMT+0100 2011"
	const STD_DATE = `D M d H:i:s \G\M\TO Y`;
}

private const WeekdayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
private const WeekdayLongNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
private const MonthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
private const MonthLongNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

// TODO: format time should be parsed at compile-time;
// then, we can preallocate StringBuilder space and use uncheckedPut

/// Format a SysTime using a PHP date() format string.
string formatTime(string fmt, SysTime t = Clock.currTime())
{
	auto result = StringBuilder(48);
	putTime(result, fmt, t);
	return result.get();
}

/// ditto
void putTime(S)(ref S sink, string fmt, SysTime t = Clock.currTime())
//	if (IsStringSink!S)
{
	auto dt = cast(DateTime)t;
	auto date = dt.date;

	static char oneDigit(uint i)
	{
		debug assert(i < 10);
		return cast(char)('0' + i);
	}

	static char[2] twoDigits(uint i)
	{
		debug assert(i < 100);
		char[2] result;
		result[0] = cast(char)('0' + i / 10);
		result[1] = cast(char)('0' + i % 10);
		return result;
	}

	static string oneOrTwoDigits(uint i)
	{
		debug assert(i < 100);
		if (i < 10)
			return [cast(char)('0' + i)];
		else
			return twoDigits(i).idup;
	}

	static char[4] fourDigits(uint i)
	{
		debug assert(i < 10000);
		char[4] result;
		result[0] = cast(char)('0' + i / 1000     );
		result[1] = cast(char)('0' + i / 100  % 10);
		result[2] = cast(char)('0' + i / 10   % 10);
		result[3] = cast(char)('0' + i        % 10);
		return result;
	}

	string timezoneFallback(string tzStr, string fallbackFormat)
	{
		if (tzStr.length)
			return tzStr;
		else
		if (t.timezone.utcToTZ(t.stdTime) == t.stdTime)
			return "UTC";
		else
			return formatTime(fallbackFormat, t);
	}

	size_t idx = 0;
	dchar c;
	while (idx < fmt.length)
		switch (c = decode(fmt, idx))
		{
			// Day
			case 'd':
				sink.put(twoDigits(dt.day));
				break;
			case 'D':
				sink.put(WeekdayShortNames[dt.dayOfWeek]);
				break;
			case 'j':
				sink.put(oneOrTwoDigits(dt.day));
				break;
			case 'l':
				sink.put(WeekdayLongNames[dt.dayOfWeek]);
				break;
			case 'N':
				sink.put(oneDigit((dt.dayOfWeek+6)%7 + 1));
				break;
			case 'S':
				switch (dt.day)
				{
					case 1:
					case 21:
					case 31:
						sink.put("st");
						break;
					case 2:
					case 22:
						sink.put("nd");
						break;
					case 3:
					case 23:
						sink.put("rd");
						break;
					default:
						sink.put("th");
				}
				break;
			case 'w':
				sink.put(oneDigit(cast(int)dt.dayOfWeek));
				break;
			case 'z':
				sink.put(text(dt.dayOfYear-1));
				break;

			// Week
			case 'W':
				sink.put(twoDigits(dt.isoWeek));
				break;

			// Month
			case 'F':
				sink.put(MonthLongNames[dt.month-1]);
				break;
			case 'm':
				sink.put(twoDigits(dt.month));
				break;
			case 'M':
				sink.put(MonthShortNames[dt.month-1]);
				break;
			case 'n':
				sink.put(oneOrTwoDigits(dt.month));
				break;
			case 't':
				sink.put(oneOrTwoDigits(dt.daysInMonth));
				break;

			// Year
			case 'L':
				sink.put(dt.isLeapYear ? '1' : '0');
				break;
			// case 'o': TODO (ISO 8601 year number)
			case 'Y':
				sink.put(fourDigits(dt.year));
				break;
			case 'y':
				sink.put(twoDigits(dt.year % 100));
				break;

			// Time
			case 'a':
				sink.put(dt.hour < 12 ? "am" : "pm");
				break;
			case 'A':
				sink.put(dt.hour < 12 ? "AM" : "PM");
				break;
			// case 'B': TODO (Swatch Internet time)
			case 'g':
				sink.put(oneOrTwoDigits((dt.hour+11)%12 + 1));
				break;
			case 'G':
				sink.put(oneOrTwoDigits(dt.hour));
				break;
			case 'h':
				sink.put(twoDigits((dt.hour+11)%12 + 1));
				break;
			case 'H':
				sink.put(twoDigits(dt.hour));
				break;
			case 'i':
				sink.put(twoDigits(dt.minute));
				break;
			case 's':
				sink.put(twoDigits(dt.second));
				break;
			case 'u':
				sink.put(format("%06d", t.fracSec.usecs));
				break;
			case 'E': // not standard
				sink.put(format("%03d", t.fracSec.msecs));
				break;

			// Timezone
			case 'e':
				sink.put(timezoneFallback(t.timezone.name, "P"));
				break;
			case 'I':
				sink.put(t.dstInEffect ? '1': '0');
				break;
			case 'O':
			{
				auto minutes = (t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000 / 60;
				sink.put(format("%+03d%02d", minutes/60, abs(minutes%60)));
				break;
			}
			case 'P':
			{
				auto minutes = (t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000 / 60;
				sink.put(format("%+03d:%02d", minutes/60, abs(minutes%60)));
				break;
			}
			case 'T':
				sink.put(timezoneFallback(t.timezone.stdName, "P"));
				break;
			case 'Z':
				sink.put(text((t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000));
				break;

			// Full date/time
			case 'c':
				sink.put(dt.toISOExtString());
				break;
			case 'r':
				sink.put(formatTime(TimeFormats.RFC2822, t));
				break;
			case 'U':
				sink.put(text(t.toUnixTime()));
				break;

			// Escape next character
			case '\\':
				put(sink, decode(fmt, idx));
				break;

			// Other characters (whitespace, delimiters)
			default:
				put(sink, c);
		}
}

import std.exception : enforce;
import std.conv : to;
import std.ascii : isDigit, isWhite;

/// Attempt to parse a time string using a PHP date() format string.
/// Supports only a small subset of format characters.
SysTime parseTime(string fmt, string t)
{
	string take(size_t n)
	{
		enforce(t.length >= n, "Not enough characters in date string");
		auto result = t[0..n];
		t = t[n..$];
		return result;
	}

	int takeNumber(size_t n, sizediff_t max = -1)
	{
		if (max==-1) max=n;
		enforce(t.length >= n, "Not enough characters in date string");
		foreach (i, c; t[0..n])
			enforce((i==0 && c=='-') || isDigit(c) || isWhite(c), "Number expected");
		while (n < max && t.length > n && isDigit(t[n]))
			n++;
		return to!int(strip(take(n)));
	}

	int takeWord(in string[] words, string name)
	{
		foreach (idx, string word; words)
			if (t.startsWith(word))
			{
				t = t[word.length..$];
				return cast(int)idx;
			}
		throw new Exception(name ~ " expected");
	}

	int year=0, month=1, day=1, hour=0, minute=0, second=0, usecs=0;
	int hour12 = 0; bool pm;
	immutable(TimeZone)* tz = null;
	int dow = -1;

	size_t idx = 0;
	dchar c;
	while (idx < fmt.length)
		switch (c = decode(fmt, idx))
		{
			// Day
			case 'd':
				day = takeNumber(2);
				break;
			case 'D':
				dow = takeWord(WeekdayShortNames, "Weekday");
				break;
			case 'j':
				day = takeNumber(1, 2);
				break;
			case 'l':
				dow = takeWord(WeekdayLongNames, "Weekday");
				break;
			case 'N':
				dow = takeNumber(1) % 7;
				break;
			case 'S': // ordinal suffix
				take(2);
				break;
			case 'w':
				dow = takeNumber(1);
				break;
			//case 'z': TODO

			// Week
			//case 'W': TODO

			// Month
			case 'F':
				month = takeWord(MonthLongNames, "Month") + 1;
				break;
			case 'm':
				month = takeNumber(2);
				break;
			case 'M':
				month = takeWord(MonthShortNames, "Month") + 1;
				break;
			case 'n':
				month = takeNumber(1, 2);
				break;
			case 't':
				takeNumber(1, 2); // TODO: validate DIM?
				break;

			// Year
			case 'L':
				takeNumber(1); // TODO: validate leapness?
				break;
			// case 'o': TODO (ISO 8601 year number)
			case 'Y':
				year = takeNumber(4);
				break;
			case 'y':
				year = takeNumber(2);
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
				hour12 = takeNumber(1, 2);
				break;
			case 'G':
				hour = takeNumber(1, 2);
				break;
			case 'h':
				hour12 = takeNumber(2);
				break;
			case 'H':
				hour = takeNumber(2);
				break;
			case 'i':
				minute = takeNumber(2);
				break;
			case 's':
				second = takeNumber(2);
				break;
			case 'u':
				usecs = takeNumber(6);
				break;
			case 'E': // not standard
				usecs = 1000 * takeNumber(3);
				break;

			// Timezone
			// case 'e': ???
			case 'I':
				takeNumber(1);
				break;
			case 'O':
			{
				if (t.length && *t.ptr == 'Z')
				{
					t = t[1..$];
					tz = [UTC()].ptr;
				}
				else
				{
					auto tzStr = take(5);
					enforce(tzStr[0]=='-' || tzStr[0]=='+', "-/+ expected");
					auto minutes = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[3..5])) * (tzStr[0]=='-' ? -1 : 1);
					tz = [new SimpleTimeZone(minutes)].ptr; // work around lack of class tailconst
				}
				break;
			}
			case 'P':
			{
				auto tzStr = take(6);
				enforce(tzStr[0]=='-' || tzStr[0]=='+', "-/+ expected");
				enforce(tzStr[3]==':', ": expected");
				auto minutes = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[4..6])) * (tzStr[0]=='-' ? -1 : 1);
				tz = [new SimpleTimeZone(minutes)].ptr; // work around lack of class tailconst
				break;
			}
			case 'T':
				tz = [TimeZone.getTimeZone(take(t.length))].ptr; // work around lack of class tailconst
				break;
			case 'Z':
			{
				// TODO: is this correct?
				auto seconds = takeNumber(1, 6);
				enforce(seconds % 60 == 0, "Timezone granularity lower than minutes not supported");
				tz = [new SimpleTimeZone(seconds / 60)].ptr; // work around lack of class tailconst
				break;
			}

			// Full date/time
			//case 'c': TODO
			//case 'r': TODO
			//case 'U': TODO

			// Escape next character
			case '\\':
			{
				// Ugh
				string next = fmt[idx..idx+stride(fmt, idx)];
				idx += next.length;
				enforce(t.length, next ~ " expected");
				enforce(take(stride(t, 0)) == next, next ~ " expected");
				break;
			}

			// Other characters (whitespace, delimiters)
			default:
			{
				enforce(t.length, to!string([c]) ~ " expected or unsupported format character");
				size_t stride = 0;
				enforce(decode(t, stride) == c, to!string([c]) ~ " expected or unsupported format character");
				t = t[stride..$];
			}
		}

	if (hour12)
		hour = hour12%12 + (pm ? 12 : 0);

	auto result = SysTime(
		DateTime(year, month, day, hour, minute, second),
		FracSec.from!"usecs"(usecs),
		tz ? *tz : null);

	if (dow >= 0)
		enforce(result.dayOfWeek == dow, "Mismatching weekday");

	return result;
}

// ***************************************************************************

@property bool empty(Duration d)
{
	return !d.total!"hnsecs"();
}
