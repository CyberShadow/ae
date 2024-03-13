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

// ***************************************************************************

/// An absolute, timezone-less point in time.
/// Like `SysTime`, but does not carry timezone information.
/// Zero-overhead wrapper around `StdTime` which attempts to
/// be compatible with `std.datetime`.
struct AbsTime
{
	StdTime stdTime;

	this(StdTime stdTime) pure @safe nothrow @nogc { this.stdTime = stdTime; }
	this(SysTime sysTime) pure @safe nothrow @nogc { this.stdTime = sysTime.stdTime; }

	this(DateTime dateTime, Duration fracSecs = Duration.zero) pure @safe nothrow @nogc
	{
		assert(fracSecs >= Duration.zero && fracSecs < seconds(1), "Invalid fracSecs");

		immutable dateDiff = dateTime.date - Date.init;
		immutable todDiff = dateTime.timeOfDay - TimeOfDay.init;

		auto t = dateDiff + todDiff + fracSecs;
		this(t.stdTime);
	}

	private static immutable epochDate = Date(1, 1, 1);
	this(Date date) pure @safe nothrow @nogc { this((date - epochDate).stdTime); }

	@property SysTime sysTime(immutable TimeZone tz = null) const pure @safe nothrow /*@nogc*/ { return SysTime(stdTime, tz); }

	/// The Xth day of the Gregorian Calendar (in the UTC time zone) that this AbsTime is on.
	@property int dayOfGregorianCal() const pure @safe nothrow @nogc
	{
		// As in SysTime:
		auto days = cast(int) stdTime.stdDur.total!"days";
		if (stdTime > 0 || stdTime == days.days.stdTime)
			days++;
		return days;
	}

	version(ae_unittest) @safe unittest // As in SysTime
	{
		import std.datetime.date : DateTime;

		assert(AbsTime(DateTime(1, 1, 1, 0, 0, 0)).dayOfGregorianCal == 1);
		assert(AbsTime(DateTime(1, 12, 31, 23, 59, 59)).dayOfGregorianCal == 365);
		assert(AbsTime(DateTime(2, 1, 1, 2, 2, 2)).dayOfGregorianCal == 366);

		assert(AbsTime(DateTime(0, 12, 31, 7, 7, 7)).dayOfGregorianCal == 0);
		assert(AbsTime(DateTime(0, 1, 1, 19, 30, 0)).dayOfGregorianCal == -365);
		assert(AbsTime(DateTime(-1, 12, 31, 4, 7, 0)).dayOfGregorianCal == -366);

		assert(AbsTime(DateTime(2000, 1, 1, 9, 30, 20)).dayOfGregorianCal == 730_120);
		assert(AbsTime(DateTime(2010, 12, 31, 15, 45, 50)).dayOfGregorianCal == 734_137);
	}

	Date opCast(T : Date)() const pure @safe nothrow @nogc { return Date(dayOfGregorianCal); }

	int opCmp(const AbsTime b) const pure @safe nothrow @nogc { return this.stdTime < b.stdTime ? -1 : this.stdTime > b.stdTime ? +1 : 0; }
	int opCmp(const SysTime b) const pure @safe nothrow @nogc { return this.opCmp(AbsTime(b)); }

	Duration opBinary(string op : "-")(AbsTime b) const pure @safe nothrow @nogc { return (this.stdTime - b.stdTime).stdDur; }
	Duration opBinary(string op : "-")(SysTime b) const pure @safe nothrow @nogc { return (this.stdTime - b.stdTime).stdDur; }
	Duration opBinaryRight(string op : "-")(SysTime a) const pure @safe nothrow @nogc { return (a.stdTime - this.stdTime).stdDur; }

	AbsTime opBinary(string op : "-")(Duration d) const pure @safe nothrow @nogc { return AbsTime(this.stdTime - d.stdTime); }
	AbsTime opBinary(string op : "+")(Duration d) const pure @safe nothrow @nogc { return AbsTime(this.stdTime + d.stdTime); }
	AbsTime opBinaryRight(string op : "+")(Duration d) const pure @safe nothrow @nogc { return AbsTime(d.stdTime + this.stdTime); }

	Duration opBinary(string op : "%")(Duration d) const pure @safe nothrow @nogc { return (this.stdTime % d.stdTime).stdDur; }

	ref AbsTime opOpAssign(string op : "-")(Duration d) pure @safe nothrow @nogc { this.stdTime -= d.stdTime; return this; }
	ref AbsTime opOpAssign(string op : "+")(Duration d) pure @safe nothrow @nogc { this.stdTime += d.stdTime; return this; }

	string toString() const @safe nothrow { return sysTime.toString(); }

	static enum min = AbsTime(SysTime.min.stdTime);
	static enum max = AbsTime(SysTime.max.stdTime);
}

AbsTime absTime(StdTime stdTime) { return AbsTime(stdTime); }
AbsTime	absTime(SysTime sysTime) { return AbsTime(sysTime); }
