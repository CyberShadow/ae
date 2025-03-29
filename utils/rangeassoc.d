/**
 * ae.utils.rangeassoc
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

module ae.utils.rangeassoc;

import std.algorithm.comparison : min, max;
import std.algorithm.searching;
import std.algorithm.sorting : sort;

/**
   Implements an associative array like type, which allows associating
   a value with a continuous range instead of a single key.
*/
struct IntervalAssocArray(K, V)
{
private:
	struct Interval { K start, end; }

	// TODO: Use a tree or another better data structure
	struct Span
	{
		K start, end;
		V value;
	}
	Span[] spans;

	invariant
	{
		foreach (i, ref span; spans)
		{
			assert(span.start < span.end);
			if (i > 0)
				assert(spans[i - 1].end <= span.start);
		}
	}

public:
	// Reading

	private int opApplyImpl(Dg)(scope Dg dg)
	{
		foreach (ref span; spans)
		{
			auto res = dg(span.start, span.end, span.value);
			if (res != 0)
				return res;
		}
		return 0;
	}

	int opApply(scope int delegate(K start, K end, ref V value)                          dg)                          { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)                    @nogc dg)                    @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)            nothrow       dg)            nothrow       { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)            nothrow @nogc dg)            nothrow @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)      @safe               dg)      @safe               { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)      @safe         @nogc dg)      @safe         @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)      @safe nothrow       dg)      @safe nothrow       { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value)      @safe nothrow @nogc dg)      @safe nothrow @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure                     dg) pure                     { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure               @nogc dg) pure               @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure       nothrow       dg) pure       nothrow       { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure       nothrow @nogc dg) pure       nothrow @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure @safe               dg) pure @safe               { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure @safe         @nogc dg) pure @safe         @nogc { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure @safe nothrow       dg) pure @safe nothrow       { return opApplyImpl(dg); }
	int opApply(scope int delegate(K start, K end, ref V value) pure @safe nothrow @nogc dg) pure @safe nothrow @nogc { return opApplyImpl(dg); }

	ref V opIndex(K point) pure @safe nothrow @nogc
	{
		foreach (ref span; spans)
			if (span.start <= point && point < span.end)
				return span.value;
		assert(false, "Point not found in span");
	}

	V* opBinaryRight(string op : "in")(K key) pure @safe nothrow @nogc
	{
		foreach (ref span; spans)
			if (span.start <= key && key < span.end)
				return &span.value;
		return null;
	}

	Interval opSlice(size_t dim: 0)(K start, K end) pure @safe nothrow @nogc
	in (start <= end)
	{
		return Interval(start, end);
	}

	/// Returns a subset of this array over the given range.
	IntervalAssocArray opIndex(Interval slice) pure @safe nothrow
	{
		IntervalAssocArray result;
		foreach (ref span; spans)
		{
			auto r = Span(
				max(span.start, slice.start),
				min(span.end, slice.end),
				span.value
			);
			if (r.start < r.end)
				result.spans ~= r;
		}
		return result;
	}

	private void scanImpl(Dg)(
		K start, K end,
		scope Dg callback,
	) const {
		foreach (ref span; spans)
		{
			auto spanStart = max(span.start, start);
			auto spanEnd = min(span.end, end);
			if (spanStart < spanEnd)
				callback(spanStart, spanEnd, span.value);
		}
	}

	/// Iterates over a subset of this array, without allocating a copy.
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value)                    dg) const                    { return scanImpl(start, end, dg); }
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value)            nothrow dg) const            nothrow { return scanImpl(start, end, dg); } /// ditto
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value)      @safe         dg) const      @safe         { return scanImpl(start, end, dg); } /// ditto
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value)      @safe nothrow dg) const      @safe nothrow { return scanImpl(start, end, dg); } /// ditto
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value) pure               dg) const pure               { return scanImpl(start, end, dg); } /// ditto
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value) pure       nothrow dg) const pure       nothrow { return scanImpl(start, end, dg); } /// ditto
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value) pure @safe         dg) const pure @safe         { return scanImpl(start, end, dg); } /// ditto
	void scan(K start, K end, scope void delegate(K start, K end, const ref V value) pure @safe nothrow dg) const pure @safe nothrow { return scanImpl(start, end, dg); } /// ditto

	// Writing

	void remove(K start, K end) pure @safe nothrow
	in (start <= end)
	{
		if (start == end)
			return;

		Span[] newSpans;
		foreach (ref span; spans)
		{
			auto r1 = Span(
				span.start,
				min(span.end, start),
				span.value
			);
			if (r1.start < r1.end)
				newSpans ~= r1;
			auto r2 = Span(
				max(span.start, end),
				span.end,
				span.value
			);
			if (r2.start < r2.end)
				newSpans ~= r2;
		}
		spans = newSpans;
	}

	private void updateImpl(Dg)(
		K start, K end,
		scope Dg updateExisting,
	) {
		Span[] newSpans;
		foreach (ref span; spans)
		{
			auto r1 = Span(
				span.start,
				min(span.end, start),
				span.value
			);
			if (r1.start < r1.end)
				newSpans ~= r1;
			auto r2 = Span(
				max(span.start, start),
				min(span.end, end),
				span.value
			);
			if (r2.start < r2.end)
			{
				updateExisting(r2.start, r2.end, r2.value);
				newSpans ~= r2;
			}
			auto r3 = Span(
				max(span.start, end),
				span.end,
				span.value
			);
			if (r3.start < r3.end)
				newSpans ~= r3;
		}
		this.spans = newSpans;
	}

	void update(K start, K end, scope void delegate(K start, K end, ref V value)                    dg)                    { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value)            nothrow dg)            nothrow { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value)      @safe         dg)      @safe         { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value)      @safe nothrow dg)      @safe nothrow { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value) pure               dg) pure               { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value) pure       nothrow dg) pure       nothrow { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value) pure @safe         dg) pure @safe         { return updateImpl(start, end, dg); }
	void update(K start, K end, scope void delegate(K start, K end, ref V value) pure @safe nothrow dg) pure @safe nothrow { return updateImpl(start, end, dg); }

	void opIndexAssign(V value, Interval slice) pure @safe nothrow
	{
		if (slice.start == slice.end)
			return;

		remove(slice.start, slice.end);
		auto i = spans.length - spans.find!((ref span) => span.start >= slice.start).length;
		spans = spans[0 .. i] ~ Span(slice.start, slice.end, value) ~ spans[i .. $];
	}

	void opIndexOpAssign(string op, T)(T value, Interval slice)
	if (is(typeof({ V v; mixin("v" ~ op ~ "= value;"); })))
	{
		update(
			slice.start, slice.end,
			(start, end, ref v) { mixin("v" ~ op ~ "= value;"); }
		);
	}

	void clear() pure @safe nothrow @nogc
	{
		spans.length = 0;
	}
}

debug(ae_unittest) pure @safe nothrow unittest
{
	IntervalAssocArray!(int, string) a;

	// Test basic assignment and retrieval
	a[0..5] = "hello";
	assert(a[2] == "hello");
	assert(a[0..5][3] == "hello");

	// Test overlapping assignment
	a[2..7] = "world";
	assert(a[1] == "hello");
	assert(a[3] == "world");
	assert(a[6] == "world");

	// Test non-overlapping assignment
	a[10..15] = "test";
	assert(a[12] == "test");

	// Test 'in' operator
	assert(5 in a);
	assert(8 !in a);

	// Test iteration
	int count = 0;
	foreach (start, end, ref value; a)
	{
		count++;
		assert(start < end);
	}
	assert(count == 3);

	// Test clear
	a.clear();
	assert(0 !in a);
	assert(5 !in a);
	assert(12 !in a);

	// Test complex overlapping assignments
	a[0..10] = "A";
	a[5..15] = "B";
	a[2..7] = "C";
	assert(a[1] == "A");
	assert(a[3] == "C");
	assert(a[6] == "C");
	assert(a[8] == "B");
	assert(a[12] == "B");

	// Test slice retrieval
	auto slice = a[4..9];
	assert(slice[4] == "C");
	assert(slice[8] == "B");
	assert(3 !in slice);

	// Test slice op-assign
	a[4..9] ~= "D";
	assert(a[1] == "A");
	assert(a[3] == "C");
	assert(a[4] == "CD");
	assert(a[8] == "BD");
	assert(a[9] == "B");
}

debug(ae_unittest) @nogc unittest
{
	IntervalAssocArray!(int, string) a;
	foreach (start, end, ref value; a)
		assert(start < end);
}
