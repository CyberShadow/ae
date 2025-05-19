/**
 * Time formats for string formatting and parsing.
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

module ae.utils.time.common;

import core.stdc.time : time_t;

import ae.utils.text;

/// Based on php.net/date
enum TimeFormatElement : char
{
	/// Year, all digits
	year                        = 'Y',
	/// Year, last 2 digits
	yearOfCentury               = 'y',
	// /// ISO-8601 week-numbering year
	// yearForWeekNumbering        = 'o',
	/// '1' if the year is a leap year, '0' otherwise
	yearIsLeapYear              = 'L',

	/// Month index, 1 or 2 digits (1 = January)
	month                       = 'n',
	/// Month index, 2 digits with leading zeroes (01 = January)
	monthZeroPadded             = 'm',
	/// Month name, full ("January", "February" ...)
	monthName                   = 'F',
	/// Month name, three letters ("Jan", "Feb" ...)
	monthNameShort              = 'M',
	/// Number of days within the month, 2 digits
	daysInMonth                 = 't',

	/// ISO-8601 week index
	weekOfYear                  = 'W',

	/// Day of year (January 1st = 0)
	dayOfYear                   = 'z',

	/// Day of month, 1 or 2 digits
	dayOfMonth                  = 'j',
	/// Day of month, 2 digits with leading zeroes
	dayOfMonthZeroPadded        = 'd',
	/// English ordinal suffix for the day of month, 2 characters
	dayOfMonthOrdinalSuffix     = 'S',

	/// Weekday index (0 = Sunday, 1 = Monday, ... 6 = Saturday)
	dayOfWeekIndex              = 'w',
	/// Weekday index, ISO-8601 numerical representation (1 = Monday, 2 = Tuesday, ... 7 = Sunday)
	dayOfWeekIndexISO8601       = 'N',
	/// Weekday name, three letters ("Mon", "Tue", ...)
	dayOfWeekNameShort          = 'D',
	/// Weekday name, full ("Monday", "Tuesday", ...)
	dayOfWeekName               = 'l',

	// /// Swatch Internet time
	// swatchInternetTime          = 'B',

	/// "am" / "pm"
	ampmLower                   = 'a',
	/// "AM" / "PM"
	ampmUpper                   = 'A',

	/// Hour (24-hour format), 1 or 2 digits
	hour                        = 'G',
	/// Hour (24-hour format), 2 digits with leading zeroes
	hourZeroPadded              = 'H',
	/// Hour (12-hour format), 1 or 2 digits (12 = midnight/noon)
	hour12                      = 'g',
	/// Hour (12-hour format), 2 digits with leading zeroes (12 = midnight/noon)
	hour12ZeroPadded            = 'h',

	/// Minute, 2 digits with leading zeroes
	minute                      = 'i',
	/// Second, 2 digits with leading zeroes
	second                      = 's',
	/// Milliseconds within second, 3 digits
	milliseconds                = 'v',
	/// Milliseconds within second, 3 digits (ae extension)
	millisecondsAlt             = 'E',
	/// Microseconds within second, 6 digits
	microseconds                = 'u',
	/// Nanoseconds within second, 9 digits (ae extension)
	nanoseconds                 = '9',

	/// Timezone identifier
	timezoneName                = 'e',
	/// Timezone abbreviation (e.g. "EST")
	timezoneAbbreviation        = 'T',
	/// Difference from GMT, with colon (e.g. "+02:00")
	timezoneOffsetWithColon     = 'P',
	/// Difference from GMT, without colon (e.g. "+0200")
	timezoneOffsetWithoutColon  = 'O',
	/// Difference from GMT in seconds
	timezoneOffsetSeconds       = 'Z',
	/// '1' if DST is in effect, '0' otherwise
	isDST                       = 'I',

	/// Full ISO 8601 date/time (e.g. "2004-02-12T15:19:21+00:00")
	dateTimeISO8601             = 'c',
	/// Full RFC 2822 date/time (e.g. "Thu, 21 Dec 2000 16:01:07 +0200")
	dateTimeRFC2822             = 'r',
	/// UNIX time (seconds since January 1 1970 00:00:00 UTC)
	dateTimeUNIX                = 'U',

	/// Treat the next character verbatim (copy when formatting, expect when parsing)
	escapeNextCharacter         = '\\',
}

/// Common time format strings.
struct TimeFormats
{
static:
	const ATOM    = `Y-m-d\TH:i:sP`   ; ///
	const COOKIE  = `l, d-M-y H:i:s T`; ///
	const ISO8601 = `Y-m-d\TH:i:sO`   ; ///
	const RFC822  = `D, d M y H:i:s O`; ///
	const RFC850  = `l, d-M-y H:i:s T`; ///
	const RFC1036 = `D, d M y H:i:s O`; ///
	const RFC1123 = `D, d M Y H:i:s O`; ///
	const RFC2822 = `D, d M Y H:i:s O`; ///
	const RFC3339 = `Y-m-d\TH:i:sP`   ; ///
	const RSS     = `D, d M Y H:i:s O`; ///
	const W3C     = `Y-m-d\TH:i:sP`   ; ///
	const HTTP    = `D, d M Y H:i:s \G\M\T`; /// https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Date

	const CTIME = `D M d H:i:s Y`; /// ctime/localtime format

	const HTML5DATE = `Y-m-d`; /// As used in HTML type="date" inputs.

	/// Format produced by std.date.toString, e.g. "Tue Jun 07 13:23:19 GMT+0100 2011"
	const STD_DATE = `D M d H:i:s \G\M\TO Y`;
}

/// We assume that no timezone will have a name longer than this.
/// If one does, it is truncated to this length.
enum MaxTimezoneNameLength = 256;

/// Calculate the maximum amount of characters needed to store a time in this format.
/// Can be evaluated at compile-time.
size_t timeFormatSize(string fmt) @safe
{
	import std.algorithm.iteration : map, reduce;
	import std.algorithm.comparison : max;

	static size_t maxLength(in string[] names) { return reduce!max(map!`a.length`(names)); }

	size_t size = 0;
	bool escaping = false;
	foreach (char c; fmt)
		if (escaping)
			size++, escaping = false;
		else
			switch (c)
			{
				case TimeFormatElement.dayOfWeekIndexISO8601:
				case TimeFormatElement.dayOfWeekIndex:
				case TimeFormatElement.yearIsLeapYear:
				case TimeFormatElement.isDST:
					size++;
					break;
				case TimeFormatElement.dayOfMonthZeroPadded:
				case TimeFormatElement.dayOfMonth:
				case TimeFormatElement.dayOfMonthOrdinalSuffix:
				case TimeFormatElement.weekOfYear:
				case TimeFormatElement.monthZeroPadded:
				case TimeFormatElement.month:
				case TimeFormatElement.daysInMonth:
				case TimeFormatElement.yearOfCentury:
				case TimeFormatElement.ampmLower:
				case TimeFormatElement.ampmUpper:
				case TimeFormatElement.hour12:
				case TimeFormatElement.hour:
				case TimeFormatElement.hour12ZeroPadded:
				case TimeFormatElement.hourZeroPadded:
				case TimeFormatElement.minute:
				case TimeFormatElement.second:
					size += 2;
					break;
				case TimeFormatElement.dayOfYear:
				case TimeFormatElement.milliseconds:
				case TimeFormatElement.millisecondsAlt: // not standard
					size += 3;
					break;
				case TimeFormatElement.year:
					size += 4;
					break;
				case TimeFormatElement.timezoneOffsetSeconds: // Timezone offset in seconds
				case TimeFormatElement.timezoneOffsetWithoutColon:
					size += 5;
					break;
				case TimeFormatElement.microseconds:
				case TimeFormatElement.timezoneOffsetWithColon:
					size += 6;
					break;
				case TimeFormatElement.nanoseconds:
					size += 9;
					break;
				case TimeFormatElement.timezoneAbbreviation:
					size += 32;
					break;

				case TimeFormatElement.dayOfWeekNameShort:
					size += maxLength(WeekdayShortNames);
					break;
				case TimeFormatElement.dayOfWeekName:
					size += maxLength(WeekdayLongNames);
					break;
				case TimeFormatElement.monthName:
					size += maxLength(MonthLongNames);
					break;
				case TimeFormatElement.monthNameShort:
					size += maxLength(MonthShortNames);
					break;

				case TimeFormatElement.timezoneName: // Timezone name
					return MaxTimezoneNameLength;

				// Full date/time
				case TimeFormatElement.dateTimeISO8601:
					enum ISOExtLength = "-0004-01-05T00:00:02.052092+10:00".length;
					size += ISOExtLength;
					break;
				case TimeFormatElement.dateTimeRFC2822:
					size += timeFormatSize(TimeFormats.RFC2822);
					break;
				case TimeFormatElement.dateTimeUNIX:
					size += decimalSize!time_t;
					break;

				// Escape next character
				case TimeFormatElement.escapeNextCharacter:
					escaping = true;
					break;

				// Other characters (whitespace, delimiters)
				default:
					size++;
			}

	return size;
}

static assert(timeFormatSize(TimeFormats.STD_DATE) == "Tue Jun 07 13:23:19 GMT+0100 2011".length);

// ***************************************************************************

/// English short and long weekday and month names, used when parsing and stringifying dates.
const WeekdayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const WeekdayLongNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]; /// ditto
const MonthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]; /// ditto
const MonthLongNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]; /// ditto

