/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Time string formatting and such.
module ae.utils.time;

import std.datetime;
import std.string;
import std.utf : decode, stride;
import std.math : abs;

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

/// Format a SysTime using a PHP date() format string.
string formatTime(string fmt, SysTime t = Clock.currTime)
{
	string result = null;
	size_t idx = 0;
	dchar c;
	while (idx < fmt.length)
		switch (c = decode(fmt, idx))
		{
			// Day
			case 'd':
				result ~= format("%02d", t.day);
				break;
			case 'D':
				result ~= WeekdayShortNames[t.dayOfWeek];
				break;
			case 'j':
				result ~= format("%d", t.day);
				break;
			case 'l':
				result ~= WeekdayLongNames[t.dayOfWeek];
				break;
			case 'N':
				result ~= format("%d", (t.dayOfWeek+6)%7 + 1);
				break;
			case 'S':
				switch (t.day)
				{
					case 1:
					case 21:
					case 31:
						result ~= "st";
						break;
					case 2:
					case 22:
						result ~= "nd";
						break;
					case 3:
					case 23:
						result ~= "rd";
						break;
					default:
						result ~= "th";
				}
				break;
			case 'w':
				result ~= format("%d", cast(int)t.dayOfWeek);
				break;
			case 'z':
				result ~= format("%d", t.dayOfYear-1);
				break;

			// Week
			case 'W':
				result ~= format("%02d", t.isoWeek);
				break;

			// Month
			case 'F':
				result ~= MonthLongNames[t.month-1];
				break;
			case 'm':
				result ~= format("%02d", t.month);
				break;
			case 'M':
				result ~= MonthShortNames[t.month-1];
				break;
			case 'n':
				result ~= format("%d", t.month);
				break;
			case 't':
				result ~= format("%d", t.daysInMonth);
				break;

			// Year
			case 'L':
				result ~= t.isLeapYear ? '1' : '0';
				break;
			// case 'o': TODO (ISO 8601 year number)
			case 'Y':
				result ~= format("%04d", t.year);
				break;
			case 'y':
				result ~= format("%02d", t.year % 100);
				break;

			// Time
			case 'a':
				result ~= t.hour < 12 ? "am" : "pm";
				break;
			case 'A':
				result ~= t.hour < 12 ? "AM" : "PM";
				break;
			// case 'B': TODO (Swatch Internet time)
			case 'g':
				result ~= format("%d", (t.hour+11)%12 + 1);
				break;
			case 'G':
				result ~= format("%d", t.hour);
				break;
			case 'h':
				result ~= format("%02d", (t.hour+11)%12 + 1);
				break;
			case 'H':
				result ~= format("%02d", t.hour);
				break;
			case 'i':
				result ~= format("%02d", t.minute);
				break;
			case 's':
				result ~= format("%02d", t.second);
				break;
			case 'u':
				result ~= format("%06d", t.fracSec.usecs);
				break;
			case 'E': // not standard
				result ~= format("%03d", t.fracSec.msecs);
				break;

			// Timezone
			case 'e':
				result ~= t.timezone.name;
				break;
			case 'I':
				result ~= t.dstInEffect ? '1': '0';
				break;
			case 'O':
			{
				// TODO: is this correct?
				auto minutes = (t.stdTime - t.timezone.utcToTZ(t.stdTime)) / 10_000_000 / 60;
				result ~= format("%+03d%02d", minutes/60, abs(minutes%60));
				break;
			}
			case 'P':
			{
				// TODO: is this correct?
				auto minutes = (t.stdTime - t.timezone.utcToTZ(t.stdTime)) / 10_000_000 / 60;
				result ~= format("%+03d:%02d", minutes/60, abs(minutes%60));
				break;
			}
			case 'T':
				result ~= t.timezone.stdName;
				break;
			case 'Z':
				// TODO: is this correct?
				result ~= format("%d", (t.stdTime - t.timezone.utcToTZ(t.stdTime)) / 10_000_000);
				break;

			// Full date/time
			case 'c':
				result ~= t.toISOExtString();
				break;
			case 'r':
				result ~= formatTime(TimeFormats.RFC2822, t);
				break;
			case 'U':
				result ~= format("%d", t.toUnixTime);
				break;

			// Escape next character
			case '\\':
				result ~= decode(fmt, idx);
				break;

			// Other characters (whitespace, delimiters)
			default:
				result ~= c;
		}
	return result;
}

import std.exception : enforce;
import std.conv : to;
import std.ascii : isDigit, isWhite;

/// Attempt to parse a time string using a PHP date() format string.
/// Supports only a small subset of format characters.
SysTime parseTime(string fmt, string t)
{
	string take(int n)
	{
		enforce(t.length >= n, "Not enough characters in date string");
		auto result = t[0..n];
		t = t[n..$];
		return result;
	}

	int takeNumber(int n, int max = -1)
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
	TimeZone tz = null;
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
				// TODO: is this correct?
				auto tzStr = take(5);
				enforce(tzStr[0]=='-' || tzStr[0]=='+', "-/+ expected");
				auto minutes = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[3..5])) * (tzStr[0]=='-' ? -1 : 1);
				tz = new SimpleTimeZone(minutes);
				break;
			}
			case 'P':
			{
				// TODO: is this correct?
				auto tzStr = take(6);
				enforce(tzStr[0]=='-' || tzStr[0]=='+', "-/+ expected");
				enforce(tzStr[3]==':', ": expected");
				auto minutes = (to!int(tzStr[1..3]) * 60 + to!int(tzStr[4..6])) * (tzStr[0]=='-' ? -1 : 1);
				tz = new SimpleTimeZone(minutes);
				break;
			}
			case 'T':
				tz = cast(TimeZone)TimeZone.getTimeZone(take(3)); // $!#%!$# constness
				break;
			case 'Z':
			{
				// TODO: is this correct?
				auto seconds = takeNumber(1, 6);
				enforce(seconds % 60 == 0, "Timezone granularity lower than minutes not supported");
				tz = new SimpleTimeZone(seconds / 60);
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
		cast(immutable(TimeZone))tz);

	if (dow >= 0)
		enforce(result.dayOfWeek == dow, "Mismatching weekday");

	return result;
}
