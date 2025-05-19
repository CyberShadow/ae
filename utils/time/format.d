/**
 * Time formatting functions.
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

module ae.utils.time.format;

import std.algorithm.comparison;
import std.conv : text;
import std.datetime;
import std.format;
import std.math : abs;

import ae.utils.meta;
import ae.utils.text;
import ae.utils.textout;
import ae.utils.time.common;
import ae.utils.time.types : AbsTime;

private struct FormatContext
{
	SysTime t;
	DateTime dt;
	bool escaping;
}

private FormatContext makeContext(SysTime t) { return FormatContext(t, cast(DateTime)t); }
private FormatContext makeContext(DateTime t) { return FormatContext(SysTime(t), t); }
private FormatContext makeContext(Date t) { return FormatContext(SysTime(t), DateTime(t)); }
private FormatContext makeContext(AbsTime t) { auto s = t.sysTime(UTC()); return FormatContext(s, cast(DateTime)s); }
// TODO: TimeOfDay support

private string enumMemberNameByValue(E, T)(T value)
{
	foreach (member; __traits(allMembers, E))
		if (__traits(getMember, E, member) == value)
			return member;
	return null;
}

debug(ae_unittest) @safe unittest
{
	static assert(enumMemberNameByValue!TimeFormatElement(TimeFormatElement.hour) == "hour");
	static assert(enumMemberNameByValue!TimeFormatElement(':') is null);
}


template putToken(alias c, alias context, alias sink)
{
	template Putters()
	{
		// Templated functions to work around recursive attribute inference issues

		void putOneDigit()(uint i)
		{
			debug assert(i < 10);
			sink.put(cast(char)('0' + i));
		}

		void putOneOrTwoDigits()(uint i)
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

		void putTimezoneName()(string tzStr)
		{
			if (tzStr.length)
				sink.put(tzStr[0..min($, MaxTimezoneNameLength)]);
			else
		//	if (t.timezone.utcToTZ(t.stdTime) == t.stdTime)
		//		sink.put("UTC");
		//	else
			{
				enum fmt = TimeFormatElement.timezoneOffsetWithColon;
				.putToken!(fmt, context, sink)();
			}
		}

		// Day

		void dayOfMonthZeroPadded()()
		{
			sink.put(toDecFixed!2(context.dt.day));
		}

		void dayOfWeekNameShort()()
		{
			sink.put(WeekdayShortNames[context.dt.dayOfWeek]);
		}

		void dayOfMonth()()
		{
			putOneOrTwoDigits(context.dt.day);
		}

		void dayOfWeekName()()
		{
			sink.put(WeekdayLongNames[context.dt.dayOfWeek]);
		}

		void dayOfWeekIndexISO8601()()
		{
			putOneDigit((context.dt.dayOfWeek+6)%7 + 1);
		}

		void dayOfMonthOrdinalSuffix()()
		{
			switch (context.dt.day)
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
		}

		void dayOfWeekIndex()()
		{
			putOneDigit(cast(int)context.dt.dayOfWeek);
		}

		void dayOfYear()()
		{
			sink.put(text(context.dt.dayOfYear-1));
		}

		// Week

		void weekOfYear()()
		{
			sink.put(toDecFixed!2(context.dt.isoWeek));
		}

		// Month

		void monthName()()
		{
			sink.put(MonthLongNames[context.dt.month-1]);
		}

		void monthZeroPadded()()
		{
			sink.put(toDecFixed!2(context.dt.month));
		}

		void monthNameShort()()
		{
			sink.put(MonthShortNames[context.dt.month-1]);
		}

		void month()()
		{
			putOneOrTwoDigits(context.dt.month);
		}

		void daysInMonth()()
		{
			putOneOrTwoDigits(context.dt.daysInMonth);
		}

		// Year

		void yearIsLeapYear()()
		{
			sink.put(context.dt.isLeapYear ? '1' : '0');
		}

		// void yearForWeekNumbering()()
		// {
		// 	// TODO (ISO 8601 year number)
		// }

		void year()()
		{
			sink.put(toDecFixed!4(cast(uint)context.dt.year)); // Hack? Assumes years are in 1000-9999 AD range
		}

		void yearOfCentury()()
		{
			sink.put(toDecFixed!2(cast(uint)context.dt.year % 100));
		}

		// Time

		void ampmLower()()
		{
			sink.put(context.dt.hour < 12 ? "am" : "pm");
		}

		void ampmUpper()()
		{
			sink.put(context.dt.hour < 12 ? "AM" : "PM");
		}

		// void swatchInternetTime()()
		// {
		// 	// TODO (Swatch Internet time)
		// }

		void hour12()()
		{
			putOneOrTwoDigits((context.dt.hour+11)%12 + 1);
		}

		void hour()()
		{
			putOneOrTwoDigits(context.dt.hour);
		}

		void hour12ZeroPadded()()
		{
			sink.put(toDecFixed!2(cast(uint)(context.dt.hour+11)%12 + 1));
		}

		void hourZeroPadded()()
		{
			sink.put(toDecFixed!2(context.dt.hour));
		}

		void minute()()
		{
			sink.put(toDecFixed!2(context.dt.minute));
		}

		void second()()
		{
			sink.put(toDecFixed!2(context.dt.second));
		}

		void microseconds()()
		{
			sink.put(toDecFixed!6(cast(uint)context.t.fracSecs.split!"usecs".usecs));
		}

		void milliseconds()()
		{
			sink.put(toDecFixed!3(cast(uint)context.t.fracSecs.split!"msecs".msecs));
		}

		alias millisecondsAlt = milliseconds; // not standard

		void nanoseconds()() // not standard
		{
			sink.put(toDecFixed!9(cast(uint)context.t.fracSecs.split!"nsecs".nsecs));
		}

		// Timezone

		void timezoneName()()
		{
			putTimezoneName(context.t.timezone.name);
		}

		void isDST()()
		{
			sink.put(context.t.dstInEffect ? '1': '0');
		}

		void timezoneOffsetWithoutColon()()
		{
			auto minutes = (context.t.timezone.utcToTZ(context.t.stdTime) - context.t.stdTime) / 10_000_000 / 60;
			sink/*.reference*/.formattedWrite("%+03d%02d", minutes/60, abs(minutes%60));
		}

		void timezoneOffsetWithColon()()
		{
			auto minutes = (context.t.timezone.utcToTZ(context.t.stdTime) - context.t.stdTime) / 10_000_000 / 60;
			sink/*.reference*/.formattedWrite("%+03d:%02d", minutes/60, abs(minutes%60));
		}

		void timezoneAbbreviation()()
		{
			putTimezoneName(context.t.timezone.stdName);
		}

		void timezoneOffsetSeconds()()
		{
			sink.putDecimal((context.t.timezone.utcToTZ(context.t.stdTime) - context.t.stdTime) / 10_000_000);
		}

		// Full date/time

		void dateTimeISO8601()()
		{
			sink.put(context.dt.toISOExtString());
		}

		void dateTimeRFC2822()()
		{
			// putTime(sink, context.t, TimeFormats.RFC2822);
			static foreach (c; TimeFormats.RFC2822)
				.putToken!(c, context, sink)();
		}

		void dateTimeUNIX()()
		{
			sink.putDecimal(context.t.toUnixTime());
		}

		// Escape next character

		void escapeNextCharacter()()
		{
			context.escaping = true;
		}
	}

	void putToken()
	{
		if (context.escaping)
		{
			sink.put(c);
			context.escaping = false;
		}
		else
		{
			static if (is(typeof({ enum token = c; })))
			{
				// token is known at compile time
				enum timeFormatElementName = enumMemberNameByValue!TimeFormatElement(c);
				static if (timeFormatElementName)
				{
					alias putter = __traits(getMember, Putters!(), timeFormatElementName);
					putter!()();
				}
				else
					put(sink, c);  // Other characters (whitespace, delimiters)
			}
			else
			{
				// token is unknown at compile time
			tokenSwitch:
				switch (c)
				{
					static foreach (member; __traits(allMembers, TimeFormatElement))
					{
						case __traits(getMember, TimeFormatElement, member):
							alias putter = __traits(getMember, Putters!(), member);
							putter!()();
							break tokenSwitch;
					}

					// Other characters (whitespace, delimiters)
					default:
						put(sink, c);
				}
			}
		}
	}
}

enum isFormattableTime(T) = is(typeof({ T t = void; return makeContext(t); }));

/// Format a time value using the format spec fmt.
/// This version generates specialized code for the given fmt.
string formatTime(string fmt, Time)(Time t)
if (isFormattableTime!Time)
{
	enum maxSize = timeFormatSize(fmt);
	auto result = StringBuilder(maxSize);
	putTime!fmt(result, t);
	return result.get();
}

/// ditto
void putTime(string fmt, S, Time)(ref S sink, Time t)
if (isStringSink!S && isFormattableTime!Time)
{
	putTimeImpl!fmt(sink, t);
}

/// Format a time value using the format spec fmt.
/// This version parses fmt at runtime.
string formatTime(Time)(Time t, string fmt)
if (isFormattableTime!Time)
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
void putTime(S, Time)(ref S sink, Time t, string fmt)
if (isStringSink!S && isFormattableTime!Time)
{
	putTimeImpl!fmt(sink, t);
}

/// ditto
deprecated void putTime(S)(ref S sink, string fmt, SysTime t = Clock.currTime())
if (isStringSink!S)
{
	putTimeImpl!fmt(sink, t);
}

private void putTimeImpl(alias fmt, S, Time)(ref S sink, Time t)
if (isFormattableTime!Time)
{
	auto context = makeContext(t);
	foreach (c; CTIterate!fmt)
		putToken!(c, context, sink)();
}

debug(ae_unittest) unittest
{
	assert(SysTime.fromUnixTime(0, UTC()).formatTime!(TimeFormats.STD_DATE) == "Thu Jan 01 00:00:00 GMT+0000 1970");
	assert(SysTime(0, new immutable(SimpleTimeZone)(Duration.zero)).formatTime!"T" == "+00:00");

	assert((cast(DateTime)SysTime.fromUnixTime(0, UTC())).formatTime!(TimeFormats.HTML5DATE) == "1970-01-01");

	assert(AbsTime(1).formatTime!(TimeFormats.HTML5DATE) == "0001-01-01");
}
