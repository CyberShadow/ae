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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.time.parse;

import core.stdc.time : time_t;
import core.time : minutes, seconds, dur;

import std.exception : enforce;
import std.conv : to;
import std.ascii : isDigit, isWhite;
import std.datetime;
import std.string : indexOf;
import std.string : strip, startsWith;

import ae.utils.time.common;
import ae.utils.time.types : AbsTime;

private struct ParseContext(Char, bool checked)
{
	int year=0, month=1, day=1, hour=0, minute=0, second=0, nsecs=0;
	int hour12 = 0; bool pm;
	TimeZone tz_;
	int dow = -1;
	Char[] t;
	bool escaping;

	// CTFE-compatible alternative to Rebindable
	@property immutable(TimeZone) tz() { return cast(immutable)tz_; }
	@property void tz(immutable(TimeZone) tz) { tz_ = cast()tz; }

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
			case TimeFormatElement.dayOfMonthZeroPadded:
				day = takeNumber!(2)();
				break;
			case TimeFormatElement.dayOfWeekNameShort:
				dow = takeWord(WeekdayShortNames, "Weekday");
				break;
			case TimeFormatElement.dayOfMonth:
				day = takeNumber!(1, 2);
				break;
			case TimeFormatElement.dayOfWeekName:
				dow = takeWord(WeekdayLongNames, "Weekday");
				break;
			case TimeFormatElement.dayOfWeekIndexISO8601:
				dow = takeNumber!1 % 7;
				break;
			case TimeFormatElement.dayOfMonthOrdinalSuffix: // ordinal suffix
				take!2;
				break;
			case TimeFormatElement.dayOfWeekIndex:
				dow = takeNumber!1;
				break;
			//case TimeFormatElement.dayOfYear: TODO

			// Week
			//case TimeFormatElement.weekOfYear: TODO

			// Month
			case TimeFormatElement.monthName:
				month = takeWord(MonthLongNames, "Month") + 1;
				break;
			case TimeFormatElement.monthZeroPadded:
				month = takeNumber!2;
				break;
			case TimeFormatElement.monthNameShort:
				month = takeWord(MonthShortNames, "Month") + 1;
				break;
			case TimeFormatElement.month:
				month = takeNumber!(1, 2);
				break;
			case TimeFormatElement.daysInMonth:
				takeNumber!(1, 2); // TODO: validate DIM?
				break;

			// Year
			case TimeFormatElement.yearIsLeapYear:
				takeNumber!1; // TODO: validate leapness?
				break;
			// case TimeFormatElement.yearForWeekNumbering: TODO (ISO 8601 year number)
			case TimeFormatElement.year:
				year = takeNumber!4;
				break;
			case TimeFormatElement.yearOfCentury:
				year = takeNumber!2;
				if (year > 50) // TODO: find correct logic for this
					year += 1900;
				else
					year += 2000;
				break;

			// Time
			case TimeFormatElement.ampmLower:
				pm = takeWord(["am", "pm"], "am/pm")==1;
				break;
			case TimeFormatElement.ampmUpper:
				pm = takeWord(["AM", "PM"], "AM/PM")==1;
				break;
			// case TimeFormatElement.swatchInternetTime: TODO (Swatch Internet time)
			case TimeFormatElement.hour12:
				hour12 = takeNumber!(1, 2);
				break;
			case TimeFormatElement.hour:
				hour = takeNumber!(1, 2);
				break;
			case TimeFormatElement.hour12ZeroPadded:
				hour12 = takeNumber!2;
				break;
			case TimeFormatElement.hourZeroPadded:
				hour = takeNumber!2;
				break;
			case TimeFormatElement.minute:
				minute = takeNumber!2;
				break;
			case TimeFormatElement.second:
				second = takeNumber!2;
				break;
			case TimeFormatElement.milliseconds:
			case TimeFormatElement.millisecondsAlt: // not standard
				nsecs = takeNumber!3 * 1_000_000;
				break;
			case TimeFormatElement.microseconds:
				nsecs = takeNumber!6 * 1_000;
				break;
			case TimeFormatElement.nanoseconds: // not standard
				nsecs = takeNumber!9;
				break;

			// Timezone
			// case TimeFormatElement.timezoneName: ???
			case TimeFormatElement.isDST:
				takeNumber!1;
				break;
			case TimeFormatElement.timezoneOffsetWithoutColon:
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
			case TimeFormatElement.timezoneOffsetWithColon:
			{
				auto tzStr = take!6();
				enforce(tzStr[0]=='-' || tzStr[0]=='+', "- / + expected");
				enforce(tzStr[3]==':', ": expected");
				auto n = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[4..6])) * (tzStr[0]=='-' ? -1 : 1);
				tz = new immutable(SimpleTimeZone)(minutes(n));
				break;
			}
			case TimeFormatElement.timezoneAbbreviation:
				version(Posix)
					tz = PosixTimeZone.getTimeZone(t.idup);
				else
				version(Windows)
					tz = WindowsTimeZone.getTimeZone(t.idup);

				t = null;
				break;
			case TimeFormatElement.timezoneOffsetSeconds:
			{
				// TODO: is this correct?
				auto n = takeNumber!(1, 6);
				tz = new immutable(SimpleTimeZone)(seconds(n));
				break;
			}

			// Full date/time
			//case TimeFormatElement.dateTimeISO8601: TODO
			//case TimeFormatElement.dateTimeRFC2822: TODO
			case TimeFormatElement.dateTimeUNIX:
			{
				auto unixTime = takeNumber!(1, 20, time_t);
				auto d = SysTime.fromUnixTime(unixTime, UTC()).to!DateTime;
				year = d.year;
				month = d.month;
				day = d.day;
				hour = d.hour;
				minute = d.minute;
				second = d.second;
				break;
			}

			// Escape next character
			case TimeFormatElement.escapeNextCharacter:
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

private T parseTimeImpl(alias fmt, T, bool checked, C)(C[] t, immutable TimeZone defaultTZ = null)
{
	ParseContext!(C, checked) context;
	context.t = t;
	context.tz = defaultTZ;
	if (__ctfe && context.tz is null)
		context.tz = UTC();

	foreach (c; CTIterate!fmt)
		parseToken!(c, context)();

	enforce(context.t.length == 0, "Left-over characters: " ~ context.t);

	with (context)
	{
		if (hour12)
			hour = hour12 % 12 + (pm ? 12 : 0);

		static if (is(T == SysTime))
		{
			// Compatibility with both <=2.066 and >=2.067
			static if (__traits(hasMember, SysTime, "fracSecs"))
				auto frac = dur!"nsecs"(nsecs);
			else
				auto frac = FracSec.from!"hnsecs"(nsecs / 100);

			SysTime result = SysTime(
				DateTime(year, month, day, hour, minute, second),
				frac,
				tz);

			if (dow >= 0 && !__ctfe)
				enforce(result.dayOfWeek == dow, "Mismatching weekday");

			return result;
		}
		else
		static if (is(T == AbsTime))
		{
			auto frac = dur!"nsecs"(nsecs);

			auto dt = DateTime(year, month, day, hour, minute, second);
			AbsTime result = AbsTime(dt, frac);

			if (dow >= 0 && !__ctfe)
				enforce(dt.dayOfWeek == dow, "Mismatching weekday");

			return result;
		}
		else
		static if (is(T == Date))
		{
			enforce(defaultTZ is null, "Date has no concept of time zone");
			return Date(year, month, day);
		}
		else
		static if (is(T == TimeOfDay))
		{
			enforce(defaultTZ is null, "TimeOfDay has no concept of time zone");
			return TimeOfDay(hour, minute, second);
		}
		else
		static if (is(T == DateTime))
		{
			enforce(defaultTZ is null, "DateTime has no concept of time zone");
			return DateTime(year, month, day, hour, minute, second);
		}
	}
}

/*private*/ template parseTimeLike(T)
{
	// Compile-time format string parsing
	/*private*/ T parseTimeLike(string fmt, C)(C[] str, immutable TimeZone tz = null)
	{
		// Omit length checks if we know the input string is long enough
		enum maxLength = timeFormatSize(fmt);
		if (str.length < maxLength)
			return parseTimeImpl!(fmt, T, true )(str, tz);
		else
			return parseTimeImpl!(fmt, T, false)(str, tz);
	}

	// Run-time format string parsing
	// Deprecated because the argument order is confusing for UFCS;
	// use the parseTimeLikeUsing aliases instead.
	/*private*/ deprecated T parseTimeLike(C)(in char[] fmt, C[] str, immutable TimeZone tz = null)
	{
		return parseTimeImpl!(fmt, T, true)(str, tz);
	}
}

/*private*/ template parseTimeLikeUsing(T)
{
	// Run-time format string parsing
	/*private*/ T parseTimeLikeUsing(C)(C[] str, in char[] fmt, immutable TimeZone tz = null)
	{
		return parseTimeImpl!(fmt, T, true)(str, tz);
	}
}

/// Parse the given string into a SysTime, using the format spec fmt.
/// This version generates specialized code for the given fmt.
alias parseTime = parseTimeLike!SysTime;

/// Parse the given string into a SysTime, using the format spec fmt.
/// This version parses fmt at runtime.
alias parseTimeUsing = parseTimeLikeUsing!SysTime;

debug(ae_unittest) import ae.utils.time.format;

debug(ae_unittest) unittest
{
	const s0 = "Tue Jun 07 13:23:19 GMT+0100 2011";
	//enum t = s0.parseTime!(TimeFormats.STD_DATE); // https://issues.dlang.org/show_bug.cgi?id=12042
	auto t = s0.parseTime!(TimeFormats.STD_DATE);
	auto s1 = t.formatTime(TimeFormats.STD_DATE);
	assert(s0 == s1, s0 ~ "/" ~ s1);
	auto t1 = s0.parseTimeUsing(TimeFormats.STD_DATE);
	assert(t == t1);
}

debug(ae_unittest) unittest
{
	"Tue, 21 Nov 2006 21:19:46 +0000".parseTime!(TimeFormats.RFC2822);
	"Tue, 21 Nov 2006 21:19:46 +0000".parseTimeUsing(TimeFormats.RFC2822);
}

debug(ae_unittest) unittest
{
	const char[] s = "Tue, 21 Nov 2006 21:19:46 +0000";
	auto d = s.parseTime!(TimeFormats.RFC2822);
	assert(d.stdTime == d.formatTime!"U".parseTime!"U".stdTime);
}

///
debug(ae_unittest) unittest
{
	enum buildTime = __TIMESTAMP__.parseTime!(TimeFormats.CTIME).stdTime;
}

/// Parse log timestamps generated by `ae.sys.log`,
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

/// Parse the given string into a DateTime, using the format spec fmt.
/// This version generates specialized code for the given fmt.
/// Fields which are not representable in a DateTime, such as timezone
/// or milliseconds, are parsed but silently discarded.
alias parseDateTime = parseTimeLike!DateTime;

/// Parse the given string into a DateTime, using the format spec fmt.
/// This version parses fmt at runtime.
/// Fields which are not representable in a DateTime, such as timezone
/// or milliseconds, are parsed but silently discarded.
alias parseDateTimeUsing = parseTimeLikeUsing!DateTime;

debug(ae_unittest) unittest
{
	const char[] s = "Tue, 21 Nov 2006 21:19:46 +0000";
	auto d = s.parseDateTime!(TimeFormats.RFC2822);
	assert(d.year == 2006 && d.second == 46);
}

/// Parse the given string into a Date, using the format spec fmt.
/// This version generates specialized code for the given fmt.
/// Fields which are not representable in a Date, such as timezone
/// or time of day, are parsed but silently discarded.
alias parseDate = parseTimeLike!Date;

/// Parse the given string into a Date, using the format spec fmt.
/// This version parses fmt at runtime.
/// Fields which are not representable in a Date, such as timezone
/// or time of day, are parsed but silently discarded.
alias parseDateUsing = parseTimeLikeUsing!Date;

debug(ae_unittest) unittest
{
	const char[] s = "Tue, 21 Nov 2006 21:19:46 +0000";
	auto d = s.parseDate!(TimeFormats.RFC2822);
	assert(d.year == 2006 && d.month == Month.nov);
}

/// Parse the given string into a TimeOfDay, using the format spec fmt.
/// This version generates specialized code for the given fmt.
/// Fields which are not representable in a TimeOfDay, such as
/// year/month/day or timezone, are parsed but silently discarded.
alias parseTimeOfDay = parseTimeLike!TimeOfDay;

/// Parse the given string into a TimeOfDay, using the format spec fmt.
/// This version parses fmt at runtime.
/// Fields which are not representable in a TimeOfDay, such as
/// year/month/day or timezone, are parsed but silently discarded.
alias parseTimeOfDayUsing = parseTimeLikeUsing!TimeOfDay;

debug(ae_unittest) unittest
{
	const char[] s = "Tue, 21 Nov 2006 21:19:46 +0000";
	auto d = s.parseTimeOfDay!(TimeFormats.RFC2822);
	assert(d.hour == 21 && d.second == 46);
}

/// Parse the given string into an AbsTime, using the format spec fmt.
/// This version generates specialized code for the given fmt.
/// Fields which are not representable in an AbsTime, such as timezone,
/// are parsed but silently discarded.
alias parseAbsTime = parseTimeLike!AbsTime;

/// Parse the given string into an AbsTime, using the format spec fmt.
/// This version parses fmt at runtime.
/// Fields which are not representable in an AbsTime, such as timezone,
/// are parsed but silently discarded.
alias parseAbsTimeUsing = parseTimeLikeUsing!AbsTime;

debug(ae_unittest) unittest
{
	const char[] s = "Tue, 21 Nov 2006 21:19:46 +0000";
	auto d = s.parseAbsTime!(TimeFormats.RFC2822);
	assert(d.sysTime.year == 2006 && d.sysTime.second == 46);
}
