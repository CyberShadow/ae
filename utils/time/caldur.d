/**
 * Calendar durations.
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

module ae.utils.time.caldur;

import core.time : Duration;

import std.exception : enforce;
import std.format : format;

struct CalendarDuration
{
	/// Calendar time component.
	int months;

	/// Fixed-length time component.
	Duration duration;

	CalendarDuration opBinary(string op)(CalendarDuration other) const
	if (op == "+" || op == "-")
	{
		return mixin("CalendarDuration(this.months " ~ op ~ " other.months, this.duration " ~ op ~ " other.duration)");
	}

	CalendarDuration opBinary(string op)(Duration other) const
	if (op == "+" || op == "-")
	{
		return opBinary!op(CalendarDuration(0, other));
	}

	CalendarDuration opBinaryRight(string op)(Duration other) const
	if (op == "+" || op == "-")
	{
		return CalendarDuration(0, other).opBinary!op(this);
	}

	// https://github.com/dlang/phobos/issues/10783
	// D opBinary(string op, D)(D d) const
	// if ((op == "+") && is(typeof((D d) { d.add!"months"(1); })))
	// {
	// 	d.add!"months"(mixin(op ~ " months"));
	// 	return mixin("duration " ~ op ~ " d");
	// }

	D opBinaryRight(string op, D)(D d) const
	if ((op == "+" || op == "-") && is(typeof((D d) { d.add!"months"(1); })))
	{
		d.add!"months"(mixin(op ~ "months"));
		return mixin("d " ~ op ~ " duration");
	}

	CalendarDuration opBinary(string op)(int scalar) const
	if (op == "*")
	{
		return mixin("CalendarDuration(this.months " ~ op ~ " scalar, this.duration " ~ op ~ " scalar)");
	}

	CalendarDuration opBinaryRight(string op)(int scalar) const
	if (op == "*")
	{
		return mixin("CalendarDuration(scalar " ~ op ~ " this.months, scalar " ~ op ~ " this.duration)");
	}

	void toString(scope void delegate(const(char)[]) sink) const
	{
		import std.format : formattedWrite;

		if (months)
			formattedWrite(sink, "%d months, ", months);
		static if (is(typeof(duration.toString(sink))))
			duration.toString(sink);
		else
			sink(duration.toString());
	}
}


CalendarDuration months(int m) { return CalendarDuration(m); }
CalendarDuration years(int y) { return CalendarDuration(y * 12); }

debug(ae_unittest) unittest
{
	import std.datetime.date : Date;
	auto d = Date(2020, 01, 01);
	assert(d + 1.months == Date(2020, 02, 01));
	assert(d + 1.years == Date(2021, 01, 01));
	assert(d - 1.months == Date(2019, 12, 01));
	assert(d - 1.years == Date(2019, 01, 01));
}

debug(ae_unittest) unittest // For CalendarDuration op CalendarDuration
{
	import core.time : days, hours;
	import std.datetime.date : Date;

	auto cd1 = CalendarDuration(1, 1.days);
	auto cd2 = CalendarDuration(2, 2.hours);

	auto sum = cd1 + cd2;
	assert(sum.months == 3);
	assert(sum.duration == 1.days + 2.hours);

	auto diff = cd1 - cd2;
	assert(diff.months == -1);
	assert(diff.duration == 1.days - 2.hours);

	assert(CalendarDuration(1) + 1.days == CalendarDuration(1, 1.days));
	assert(CalendarDuration(1) - 1.days == CalendarDuration(1, -1.days));
	assert(1.days + CalendarDuration(1) == CalendarDuration(1, 1.days));
}

debug(ae_unittest) unittest // For CalendarDuration op int
{
	import core.time : days, hours;
	import std.datetime.date : Date;

	auto cd = CalendarDuration(2, 3.hours);

	auto mul_cd_int = cd * 3;
	assert(mul_cd_int.months == 6);
	assert(mul_cd_int.duration == 9.hours);

	auto mul_int_cd = 3 * cd; // Test opBinaryRight
	assert(mul_int_cd.months == 6);
	assert(mul_int_cd.duration == 9.hours);

	// auto div_cd_int = cd / 2;
	// assert(div_cd_int.months == 1);
	// assert(div_cd_int.duration == (3.hours / 2));

	// import std.exception : assertThrown;
	// assertThrown!Exception(cd / 0);
}

debug(ae_unittest) unittest
{
	import core.time : days;
	import std.datetime.date : Date, DateTime;
	import std.datetime.systime : SysTime;
	import std.datetime.timezone : UTC; // For SysTime creation
	import ae.utils.time.types : AbsTime;

	auto cd = CalendarDuration(1, 2.days); // 1 month, 2 days

	// Date
	auto date = Date(2020, 1, 15);
	assert(date + cd == Date(2020, 2, 17), "Date + CD");
	// assert(cd + date == Date(2020, 2, 17), "CD + Date");
	assert(date - cd == Date(2019, 12, 13), "Date - CD");

	// DateTime
	auto dt = DateTime(2020, 1, 15, 10, 0, 0);
	auto expected_dt_plus = DateTime(2020, 2, 17, 10, 0, 0);
	assert(dt + cd == expected_dt_plus, "DateTime + CD");
	// assert(cd + dt == expected_dt_plus, "CD + DateTime");

	// SysTime
	auto st = SysTime(DateTime(2020, 1, 15, 10, 0, 0), UTC());
	auto expected_st_plus_dt = SysTime(DateTime(2020, 2, 17, 10, 0, 0), UTC());
	assert((st + cd).toUTC() == expected_st_plus_dt, "SysTime + CD");
	// assert((cd + st).toUTC() == expected_st_plus_dt, "CD + SysTime");

	// AbsTime
	auto at_start = AbsTime(DateTime(2020, 1, 15, 10, 0, 0));

	auto expected_at_plus_dt = AbsTime(DateTime(2020, 2, 17, 10, 0, 0));
	assert((at_start + cd) == expected_at_plus_dt, "AbsTime + CD");
	// assert((cd + at_start) == expected_at_plus_dt, "CD + AbsTime");
}

debug(ae_unittest) unittest
{
	import core.time : days, hours, seconds;
	import std.datetime.date : Date;
	import std.conv : text;

	assert(CalendarDuration(1, 2.days + 3.hours).text == "1 months, " ~ (2.days + 3.hours).text);
}
