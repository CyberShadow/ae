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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
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
				enum fmt = 'P';
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
					sink.put(toDecFixed!6(cast(uint)t.fracSecs.split!"usecs".usecs));
					break;
				case 'E': // not standard
					sink.put(toDecFixed!3(cast(uint)t.fracSecs.split!"msecs".msecs));
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
					sink.reference.formattedWrite("%+03d%02d", minutes/60, abs(minutes%60));
					break;
				}
				case 'P':
				{
					auto minutes = (t.timezone.utcToTZ(t.stdTime) - t.stdTime) / 10_000_000 / 60;
					sink.reference.formattedWrite("%+03d:%02d", minutes/60, abs(minutes%60));
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
string formatTime(string fmt)(SysTime t)
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
string formatTime(SysTime t, string fmt)
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

unittest
{
	assert(SysTime.fromUnixTime(0, UTC()).formatTime!(TimeFormats.STD_DATE) == "Thu Jan 01 00:00:00 GMT+0000 1970");
	assert(SysTime(0, new immutable(SimpleTimeZone)(Duration.zero)).formatTime!"T" == "+00:00");
}
