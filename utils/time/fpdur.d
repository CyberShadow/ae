/**
 * Duration functions.
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

module ae.utils.time.fpdur;

import core.time;

/// A variant of core.time.dur which accepts floating-point values.
/// Useful for parsing command-line arguments.
/// Beware of rounding / floating-point errors! Do not use where precision matters.
template dur(string units)
if (units == "weeks" ||
	units == "days" ||
	units == "hours" ||
	units == "minutes" ||
	units == "seconds" ||
	units == "msecs" ||
	units == "usecs" ||
	units == "hnsecs" ||
	units == "nsecs")
{
	Duration dur(T)(T length) @safe pure nothrow @nogc
	if (is(T : real) && !is(T : ulong))
	{
		auto hnsecs = length * convert!(units, "hnsecs")(1);
		// https://issues.dlang.org/show_bug.cgi?id=15900
		static import core.time;
		return core.time.hnsecs(cast(long)hnsecs);
	}
}

alias weeks   = dur!"weeks";   /// Ditto
alias days    = dur!"days";    /// Ditto
alias hours   = dur!"hours";   /// Ditto
alias minutes = dur!"minutes"; /// Ditto
alias seconds = dur!"seconds"; /// Ditto
alias msecs   = dur!"msecs";   /// Ditto
alias usecs   = dur!"usecs";   /// Ditto
alias hnsecs  = dur!"hnsecs";  /// Ditto
alias nsecs   = dur!"nsecs";   /// Ditto

unittest
{
	import core.time : msecs;
	//static assert(1.5.seconds == 1500.msecs);
	static assert(1.5.seconds == 1500.msecs);
}

/// Multiply a duration by a floating-point number.
Duration durScale(F)(Duration d, F f)
if (is(F : real))
{
	return hnsecs(d.total!"hnsecs" * f);
}

unittest
{
	import core.time : seconds, msecs;
	assert(durScale(1.seconds, 1.5) == 1500.msecs);
}
