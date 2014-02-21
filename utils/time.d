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

import std.algorithm;
import std.conv : text;
import std.datetime;
import std.format : formattedWrite;
import std.math : abs;
import std.string;
import std.typecons;

import ae.utils.text;
import ae.utils.textout;

// ***************************************************************************

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

const WeekdayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const WeekdayLongNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MonthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MonthLongNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

// ***************************************************************************

/// We assume that no timezone will have a name longer than this.
/// If one does, it is truncated to this length.
enum MaxTimezoneNameLength = 256;

private struct FormatContext(Char)
{
	SysTime t;
	DateTime dt;
	bool escaping;
}

private void putToken(alias c, alias context, alias sink)()
{
	with (context)
	{
		void putOneDigit(uint i)
		{
			debug assert(i < 10);
			sink.put(cast(char)('0' + i));
		}

		void putOneOrTwoDigits(uint i)
		{
			debug assert(i < 100);
			if (i >= 10)
			{
				sink.put(cast(char)('0' + (i / 10)));
				sink.put(cast(char)('0' + (i % 10)));
			}
			else
				sink.put(cast(char)('0' +  i      ));
		}

		void putTimezoneName(string tzStr)
		{
			if (tzStr.length)
				sink.put(tzStr[0..min($, MaxTimezoneNameLength)]);
			else
		//	if (t.timezone.utcToTZ(t.stdTime) == t.stdTime)
		//		sink.put("UTC");
		//	else
			{
				enum fmt = 'C';
				putToken!(fmt, context, sink)();
			}
		}

		if (escaping)
			sink.put(c), escaping = false;
		else
			switch (c)
			{
				// Day
				case 'd':
					sink.put(toDecFixed!2(dt.day));
					break;
				case 'D':
					sink.put(WeekdayShortNames[dt.dayOfWeek]);
					break;
				case 'j':
					putOneOrTwoDigits(dt.day);
					break;
				case 'l':
					sink.put(WeekdayLongNames[dt.dayOfWeek]);
					break;
				case 'N':
					putOneDigit((dt.dayOfWeek+6)%7 + 1);
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
					putOneDigit(cast(int)dt.dayOfWeek);
					break;
				case 'z':
					sink.put(text(dt.dayOfYear-1));
					break;

				// Week
				case 'W':
					sink.put(toDecFixed!2(dt.isoWeek));
					break;

				// Month
				case 'F':
					sink.put(MonthLongNames[dt.month-1]);
					break;
				case 'm':
					sink.put(toDecFixed!2(dt.month));
					break;
				case 'M':
					sink.put(MonthShortNames[dt.month-1]);
					break;
				case 'n':
					putOneOrTwoDigits(dt.month);
					break;
				case 't':
					putOneOrTwoDigits(dt.daysInMonth);
					break;

				// Year
				case 'L':
					sink.put(dt.isLeapYear ? '1' : '0');
					break;
				// case 'o': TODO (ISO 8601 year number)
				case 'Y':
					sink.put(toDecFixed!4(cast(uint)dt.year)); // Hack? Assumes years are in 1000-9999 AD range
					break;
				case 'y':
					sink.put(toDecFixed!2(cast(uint)dt.year % 100));
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
					putOneOrTwoDigits((dt.hour+11)%12 + 1);
					break;
				case 'G':
					putOneOrTwoDigits(dt.hour);
					break;
				case 'h':
					sink.put(toDecFixed!2(cast(uint)(dt.hour+11)%12 + 1));
					break;
				case 'H':
					sink.put(toDecFixed!2(dt.hour));
					break;
				case 'i':
					sink.put(toDecFixed!2(dt.minute));
					break;
				case 's':
					sink.put(toDecFixed!2(dt.second));
					break;
				case 'u':
					sink.put(toDecFixed!6(cast(uint)t.fracSec.usecs));
					break;
				case 'E': // not standard
					sink.put(toDecFixed!3(cast(uint)t.fracSec.msecs));
					break;

				// Timezone
				case 'e':
					putTimezoneName(t.timezone.name);
					break;
				case 'I':
					sink.put(t.dstInEffect ? '1': '0');
					break;
				case 'O':
				{
					auto minutes = (t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000 / 60;
					reference(sink).formattedWrite("%+03d%02d", minutes/60, abs(minutes%60));
					break;
				}
				case 'P':
				{
					auto minutes = (t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000 / 60;
					reference(sink).formattedWrite("%+03d:%02d", minutes/60, abs(minutes%60));
					break;
				}
				case 'T':
					putTimezoneName(t.timezone.stdName);
					break;
				case 'Z':
					sink.putDecimal((t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000);
					break;

				// Full date/time
				case 'c':
					sink.put(dt.toISOExtString());
					break;
				case 'r':
					putTime(sink, t, TimeFormats.RFC2822);
					break;
				case 'U':
					sink.putDecimal(t.toUnixTime());
					break;

				// Escape next character
				case '\\':
					escaping = true;
					break;

				// Other characters (whitespace, delimiters)
				default:
					put(sink, c);
			}
	}
}

/// Format a SysTime using the format spec fmt.
/// This version generates specialized code for the given fmt.
string format(string fmt)(SysTime t)
{
	enum maxSize = timeFormatSize(fmt);
	auto result = StringBuilder(maxSize);
	putTime!fmt(result, t);
	return result.get();
}

/// ditto
void putTime(string fmt, S)(ref S sink, SysTime t)
	if (IsStringSink!S)
{
	putTimeImpl!fmt(sink, t);
}

/// Format a SysTime using the format spec fmt.
/// This version parses fmt at runtime.
string format(SysTime t, string fmt)
{
	auto result = StringBuilder(timeFormatSize(fmt));
	putTime(result, t, fmt);
	return result.get();
}

/// ditto
deprecated string formatTime(string fmt, SysTime t = Clock.currTime())
{
	auto result = StringBuilder(48);
	putTime(result, fmt, t);
	return result.get();
}

/// ditto
void putTime(S)(ref S sink, SysTime t, string fmt)
	if (IsStringSink!S)
{
	putTimeImpl!fmt(sink, t);
}

/// ditto
deprecated void putTime(S)(ref S sink, string fmt, SysTime t = Clock.currTime())
	if (IsStringSink!S)
{
	putTimeImpl!fmt(sink, t);
}

void putTimeImpl(alias fmt, S)(ref S sink, SysTime t)
{
	FormatContext!(char) context;
	context.t = t;
	context.dt = cast(DateTime)t;
	foreach (c; CTIterate!fmt)
		putToken!(c, context, sink)();
}

/// Calculate the maximum amount of characters needed to store a time in this format.
/// Can be evaluated at compile-time.
size_t timeFormatSize(string fmt)
{
	static size_t maxLength(in string[] names) { return reduce!max(map!`a.length`(WeekdayShortNames)); }

	size_t size = 0;
	bool escaping = false;
	foreach (char c; fmt)
		if (escaping)
			size++, escaping = false;
		else
			switch (c)
			{
				case 'N':
				case 'w':
				case 'L':
				case 'I':
					size++;
					break;
				case 'd':
				case 'j':
				case 'S':
				case 'W':
				case 'm':
				case 'n':
				case 't':
				case 'y':
				case 'a':
				case 'A':
				case 'g':
				case 'G':
				case 'h':
				case 'H':
				case 'i':
				case 's':
					size += 2;
					break;
				case 'z':
				case 'E': // not standard
					size += 3;
					break;
				case 'Y':
					size += 4;
					break;
				case 'Z': // Timezone offset in seconds
				case 'O':
					size += 5;
					break;
				case 'u':
				case 'P':
					size += 6;
					break;
				case 'T':
					size += 32;
					break;

				case 'D':
					size += maxLength(WeekdayShortNames);
					break;
				case 'l':
					size += maxLength(WeekdayLongNames);
					break;
				case 'F':
					size += maxLength(MonthLongNames);
					break;
				case 'M':
					size += maxLength(MonthShortNames);
					break;

				case 'e': // Timezone name
					return MaxTimezoneNameLength;

				// Full date/time
				case 'c':
					enum ISOExtLength = "-0004-01-05T00:00:02.052092+10:00".length;
					size += ISOExtLength;
					break;
				case 'r':
					size += timeFormatSize(TimeFormats.RFC2822);
					break;
				case 'U':
					size += DecimalSize!int;
					break;

				// Escape next character
				case '\\':
					escaping = true;
					break;

				// Other characters (whitespace, delimiters)
				default:
					size++;
			}

	return size;
}

static assert(timeFormatSize(TimeFormats.STD_DATE) == "Tue Jun 07 13:23:19 GMT+0100 2011".length);

import std.exception : enforce;
import std.conv : to;
import std.ascii : isDigit, isWhite;

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
				{
					auto tzStr = take!5();
					enforce(tzStr[0]=='-' || tzStr[0]=='+', "-/+ expected");
					auto minutes = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[3..5])) * (tzStr[0]=='-' ? -1 : 1);
					tz = new immutable(SimpleTimeZone)(minutes);
				}
				break;
			}
			case 'P':
			{
				auto tzStr = take!6();
				enforce(tzStr[0]=='-' || tzStr[0]=='+', "-/+ expected");
				enforce(tzStr[3]==':', ": expected");
				auto minutes = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[4..6])) * (tzStr[0]=='-' ? -1 : 1);
				tz = new immutable(SimpleTimeZone)(minutes);
				break;
			}
			case 'T':
				tz = TimeZone.getTimeZone(t.idup);
				t = null;
				break;
			case 'Z':
			{
				// TODO: is this correct?
				auto seconds = takeNumber!(1, 6);
				enforce(seconds % 60 == 0, "Timezone granularity lower than minutes not supported");
				tz = new immutable(SimpleTimeZone)(seconds / 60);
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

private SysTime parseTimeImpl(alias fmt, bool checked, C)(C[] t)
{
	ParseContext!(C, checked) context;
	context.t = t;

	foreach (c; CTIterate!fmt)
		parseToken!(c, context)();

	enforce(context.t.length == 0, "Left-over characters: " ~ context.t);

	SysTime result;

	with (context)
	{
		if (hour12)
			hour = hour12%12 + (pm ? 12 : 0);

		result = SysTime(
			DateTime(year, month, day, hour, minute, second),
			FracSec.from!"usecs"(usecs),
			tz);

		if (dow >= 0)
			enforce(result.dayOfWeek == dow, "Mismatching weekday");
	}

	return result;
}

/// Parse the given string into a SysTime, using the format spec fmt.
/// This version generates specialized code for the given fmt.
SysTime parseTime(string fmt, C)(C[] t)
{
	// Omit length checks if we know the input string is long enough
	enum maxLength = timeFormatSize(fmt);
	if (t.length < maxLength)
		return parseTimeImpl!(fmt, true )(t);
	else
		return parseTimeImpl!(fmt, false)(t);
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

unittest
{
	const s0 = "Tue Jun 07 13:23:19 GMT+0100 2011";
	//enum t = s0.parseTime!(TimeFormats.STD_DATE); // https://d.puremagic.com/issues/show_bug.cgi?id=12042
	auto t = s0.parseTime!(TimeFormats.STD_DATE);
	auto s1 = t.format(TimeFormats.STD_DATE);
	assert(s0 == s1);
	auto t1 = s0.parseTimeUsing(TimeFormats.STD_DATE);
	assert(t == t1);
}

// ***************************************************************************

@property bool empty(Duration d)
{
	return !d.total!"hnsecs"();
}
