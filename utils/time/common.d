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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.time.common;

import ae.utils.text;

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

/// We assume that no timezone will have a name longer than this.
/// If one does, it is truncated to this length.
enum MaxTimezoneNameLength = 256;

/// Calculate the maximum amount of characters needed to store a time in this format.
/// Can be evaluated at compile-time.
size_t timeFormatSize(string fmt)
{
	import std.algorithm.iteration : map, reduce;
	import std.algorithm.comparison : max;

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

// ***************************************************************************

const WeekdayShortNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const WeekdayLongNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
const MonthShortNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const MonthLongNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

