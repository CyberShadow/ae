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

public import ae.utils.time.common;
public import ae.utils.time.format;
public import ae.utils.time.fpdur;
public import ae.utils.time.parse;
public import ae.utils.time.parsedur;

unittest
{
	enum f = `U\.9`;
	assert("123456789012.123456789".parseTime!f.formatTime!f == "123456789012.123456700");
}

// ***************************************************************************

import std.datetime;

alias StdTime = typeof(SysTime.init.stdTime); // long

/// Convert from StdTime to Duration
alias stdDur = hnsecs;

/// Like SysTime.stdTime.
@property StdTime stdTime(Duration d)
{
	return d.total!"hnsecs"();
}

@property bool empty(Duration d)
{
	return !d.stdTime;
}

/// Workaround SysTime.fracSecs only being available in 2.067,
/// and SysTime.fracSec becoming deprecated in the same version.
static if (!is(typeof(SysTime.init.fracSecs)))
@property Duration fracSecs(SysTime s)
{
	enum hnsecsPerSecond = convert!("seconds", "hnsecs")(1);
	return hnsecs(s.stdTime % hnsecsPerSecond);
}

/// As above, for Duration.split and Duration.get
static if (!is(typeof(Duration.init.split!())))
@property auto split(units...)(Duration d)
{
	static struct Result
	{
		mixin("long " ~ [units].join(", ") ~ ";");
	}

	Result result;
	foreach (unit; units)
	{
		static if (is(typeof(d.get!unit))) // unit == "msecs" || unit == "usecs" || unit == "hnsecs" || unit == "nsecs")
			long value = d.get!unit();
		else
			long value = mixin("d.fracSec." ~ unit);
		mixin("result." ~ unit ~ " = value;");
	}
	return result;
}

// ***************************************************************************

// fpdur conflict test
static assert(1.5.seconds == 1500.msecs);
