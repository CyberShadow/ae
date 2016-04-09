/**
 * Duration parsing functions.
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

module ae.utils.time.parsedur;

import core.time;

import std.algorithm.iteration : filter;
import std.array;
import std.ascii;
import std.conv;
import std.exception;
import std.string;

/// Parse a duration string in the form returned by Duration.toString
/// (e.g. "1 day, 1 hour and 30 minutes")
Duration parseDuration(string s)
{
	s = s.replace(" and ", " ");
	s = s.replace(", ", " ");
	auto words = std.string.split(s).filter!(word => word.length);
	enforce(!words.empty, "No duration given");

	Duration result;

	while (!words.empty)
	{
		auto word = words.front;
		words.popFront();
		assert(word.length);
		enforce(word[0].isDigit || word[0] == '-', "Digit expected: " ~ s);

		auto amount = std.conv.parse!real(word);

		if (!word.length)
		{
			if (words.empty)
			{
				if (amount == 0)
					break;
				throw new Exception("Unit expected");
			}
			word = words.front;
			words.popFront();
		}

		Duration unit;

		word = word.toLower().replace("-", "");
		switch (word)
		{
			case "nanoseconds":
			case "nanosecond":
			case "nsecs":
			case "nsec":
				amount /= 100;
				unit = 1.hnsecs;
				break;
			case "hectananoseconds":
			case "hectananosecond":
			case "hnsecs":
			case "hns":
				unit = 1.hnsecs;
				break;
			case "microseconds":
			case "microsecond":
			case "usecs":
			case "usec":
			case "us":
			case "μsecs":
			case "μsec":
			case "μs":
				unit = 1.usecs;
				break;
			case "milliseconds":
			case "millisecond":
			case "msecs":
			case "msec":
			case "ms":
				unit = 1.msecs;
				break;
			case "seconds":
			case "second":
			case "secs":
			case "sec":
			case "s":
				unit = 1.seconds;
				break;
			case "minutes":
			case "minute":
			case "mins":
			case "min":
			case "m":
				unit = 1.minutes;
				break;
			case "hours":
			case "hour":
			case "h":
				unit = 1.hours;
				break;
			case "days":
			case "day":
			case "d":
				unit = 1.days;
				break;
			case "weeks":
			case "week":
			case "w":
				unit = 1.weeks;
				break;
			default:
				throw new Exception("Unknown unit: " ~ word);
		}

		result += dur!"hnsecs"(cast(long)(unit.total!"hnsecs" * amount));
	}

	return result;
}

unittest
{
	assert(parseDuration("1 day, 1 hour and 30 minutes") == 1.days + 1.hours + 30.minutes);
	assert(parseDuration("0.5 hours") == 30.minutes);
	assert(parseDuration("0") == Duration.init);
}
