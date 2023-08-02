/**
 * Some nice "polyfills" for standard std.datetime types.
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

module ae.utils.time.types;

// ***************************************************************************

import std.datetime;

/// `typeof(SysTime.stdTime)`, the numeric type used to store absolute time in D.
alias StdTime = typeof(SysTime.init.stdTime); // long

/// Convert from `StdTime` to `Duration`.
alias stdDur = hnsecs;

/// Like `SysTime.stdTime`.
@property StdTime stdTime(Duration d) pure @safe nothrow @nogc
{
	return d.total!"hnsecs"();
}

/// `true` when the duration `d` is zero.
@property bool empty(Duration d) pure @safe nothrow @nogc
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
