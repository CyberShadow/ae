/**
 * Very basic (and probably buggy) numeric
 * distribution / probability operations.
 * WIP, do not use.
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

module ae.utils.math.distribution;

import std.algorithm.comparison;
import std.algorithm.iteration;

import ae.utils.array;
import ae.utils.math;

/// A simplified representation of some probability distribution.
/// Supports uniform distributions and basic operations on them (sum / product).
struct Range(T)
{
	/// Low, high, and average points.
	T lo, hi, avg;
	private bool uniform;

	invariant
	{
		assert(lo <= avg);
		assert(avg <= hi);
	}

	auto opBinary(string op, U)(U u) const
	if (is(U : real))
	{
		alias V = typeof(mixin("T.init " ~ op ~ " u"));
		V a   = mixin("lo "  ~ op ~ " u");
		V b   = mixin("hi "  ~ op ~ " u");
		V avg = mixin("avg " ~ op ~ " u");
		return Range!V(min(a, b), max(a, b), avg, uniform);
	} ///

	auto opBinaryRight(string op, U)(U u) const
	if (is(U : real))
	{
		alias V = typeof(mixin("u " ~ op ~ " T.init"));
		V a   = mixin("u " ~ op ~ " lo");
		V b   = mixin("u " ~ op ~ " hi");
		V avg = mixin("u " ~ op ~ " avg");
		return Range!V(min(a, b), max(a, b), avg, uniform);
	} ///

	auto opBinary(string op, R)(R r) const
	if (is(R : Range!U, U))
	{
		auto a = mixin("lo " ~ op ~ " r.lo");
		auto b = mixin("lo " ~ op ~ " r.hi");
		auto c = mixin("hi " ~ op ~ " r.lo");
		auto d = mixin("hi " ~ op ~ " r.hi");
		auto avg = mixin("avg " ~ op ~ " r.avg");
		return range(min(a, b, c, d), max(a, b, c, d), avg);
	} ///

	auto opCast(T)() const
	if (is(T : Range!U, U))
	{
		static if (is(T : Range!U, U))
			return range(cast(U)lo, cast(U)hi, cast(U)avg);
		else
			assert(false);
	} ///

	Range!U to(U)() const
	{
		return range(cast(U)lo, cast(U)hi, cast(U)avg);
	} ///

	/// Apply a `prob` chance that `this` equals `val`.
	Range!T fuzzyAssign(Range!T val, double prob = 0.5)
	{
		assert(prob >= 0 && prob <= 1);
		if (prob == 0)
			return this;
		if (prob == 1)
			return val;

		auto r = this;
		if (r.lo > val.lo)
			r.lo = val.lo;
		if (r.hi < val.hi)
			r.hi = val.hi;
		r.avg = itpl(r.avg, val.avg, prob, 0.0, 1.0);
		r.uniform = false;
		return r;
	}

	/// ditto
	Range!T fuzzyAssign(T val, double prob = 0.5)
	{
		return fuzzyAssign(range(val), prob);
	}

	string toString() const
	{
		import std.format : format;
		if (lo == hi)
			return format("%s", lo);
		else
		if (avg == (lo + hi) / 2)
			return format("%s..%s", lo, hi);
		else
			return format("%s..%s..%s", lo, avg, hi);
	} ///
}

Range!T range(T)(T lo, T hi, T avg) { return Range!T(lo, hi, avg, false); } /// ditto
Range!T range(T)(T lo, T hi) { return Range!T(lo, hi, (lo + hi) / 2, true); } /// ditto
Range!T range(T)(T val) { return Range!T(val, val, val, true); } /// ditto

///
version(ae_unittest) unittest
{
	assert(range(1, 2) + 1 == range(2, 3));
	assert(1 + range(1, 2) == range(2, 3));
}

///
version(ae_unittest) unittest
{
	auto a = range(10, 20);
	auto b = range(10, 20);
	auto c = a * b;
	assert(c.avg == 225);
}

version(ae_unittest) unittest
{
	auto a = range(10, 20);
	a = a.fuzzyAssign(25);
	assert(a == range(10, 25, 20));
}

// ****************************************************************************

/// Indicates the probability of a certain event.
struct Probability
{
	double p; /// [0,1]

	bool isImpossible() const @nogc { return p == 0; } ///
	bool isPossible() const @nogc { return p > 0; } ///
	bool isCertain() const @nogc { return p == 1; } ///
}

/// Apply `doIf` if `p` is possible.
/// `doIf` receives the probability of the event (non-zero).
void cond(alias doIf)(Probability p)
{
	if (p.p > 0)
		doIf(p.p);
}

/// Apply `doIf` if `p` is possible,
/// and/or `doElse` if `!p` is possible,
/// `doIf` and `doElse` receive the probability of their respective event (non-zero).
void cond(alias doIf, alias doElse)(Probability p)
{
	if (p.p > 0)
		doIf(p.p);
	if (p.p < 1)
		doElse(1 - p.p);
}

/// Return the probability of event `a` not occurring.
Probability not(Probability a) { return Probability(1 - a.p); }
/// Return the probability of both unrelated events `a` and `b` occurring.
Probability and(Probability a, Probability b) { return Probability(a.p * b.p); }
/// Return the probability of at least one of the unrelated events `a` and `b` occurring.
Probability or (Probability a, Probability b) { return not(and(not(a), not(b))); }

/// Return the probability that `a` `op` `b`, where `op` is `<` / `<=` / `>` / `>=`,
/// and `a` and `b` are numbers or ranges representing a uniform distribution.
template cmp(string op)
if (op.isOneOf("<", "<=", ">", ">="))
{
	// Number-to-number

	Probability cmp(A, B)(A a, B b)
	if (!is(A : Range!AV, AV) && !is(B : Range!BV, BV))
	{
		return Probability(mixin("a" ~ op ~ "b") ? 1 : 0);
	}

	// Number-to-range

	Probability cmp(A, B)(A a, B b)
	if ( is(A : Range!AV, AV) && !is(B : Range!BV, BV))
	{
		double p;

		if (a.hi < b)
			p = 1;
		else
		if (a.lo <= b)
		{
			assert(a.uniform, "Can't compare a non-uniform distribution");

			auto lo = cast()a.lo;
			auto hi = cast()a.hi;

			static if (is(typeof(lo + b) : long))
			{
				static if (op[0] == '<')
					hi++;
				else
					lo--;

				static if (op.length == 2) // >=, <=
				{
					static if (op[0] == '<')
						b++;
					else
						b--;
				}
			}
			p = itpl(0.0, 1.0, b, lo, hi);
		}
		else
			p = 0;

		static if (op[0] == '>')
			p = 1 - p;

		return Probability(p);
	}

	version(ae_unittest) unittest // int unittest
	{
		auto a = range(1, 2);
		foreach (b; 0..4)
		{
			auto p0 = cmp(a, b).p;
			double p1 = 0;
			foreach (x; a.lo .. a.hi+1)
				if (mixin("x" ~ op ~ "b"))
					p1 += 0.5;
			debug
			{
				import std.conv : text;
				assert(p0 == p1, text("a", op, b, " -> ", p0, " / ", p1));
			}
		}
	}

	// Range-to-number

	Probability cmp(A, B)(A a, B b)
	if (!is(A : Range!AV, AV) &&  is(B : Range!BV, BV))
	{
		static if (op[0] == '>')
			return .cmp!("<" ~ op[1..$])(b, a);
		else
			return .cmp!(">" ~ op[1..$])(b, a);
	}

	version(ae_unittest) unittest
	{
		auto b = range(1, 2);
		foreach (a; 0..4)
		{
			auto p0 = cmp(a, b).p;
			double p1 = 0;
			foreach (x; b.lo .. b.hi+1)
				if (mixin("a" ~ op ~ "x"))
					p1 += 0.5;
			debug
			{
				import std.conv : text;
				assert(p0 == p1, text(a, op, "b", " -> ", p0, " / ", p1));
			}
		}
	}

	// Range-to-range

	Probability cmp(A, B)(A a, B b)
	if (is(A : Range!AV, AV) &&  is(B : Range!BV, BV))
	{
		assert(a.uniform && b.uniform, "Can't compare non-uniform distributions");

		static if (op[0] == '<')
		{
			auto x0 = a.lo;
			auto x1 = a.hi;
			auto y0 = b.lo;
			auto y1 = b.hi;
		}
		else
		{
			auto x0 = b.lo;
			auto x1 = b.hi;
			auto y0 = a.lo;
			auto y1 = a.hi;
		}

		static if (is(typeof(x0 + y0) : long))
		{
			x1++, y1++;
				
			static if (op.length == 2) // >=, <=
				y0++, y1++;
		}

		double p;

		// No intersection
		if (x1 <= y0) // x0 ≤ x1 ≤ y0 ≤ y1
			p = 1;
		else
		if (y1 <= x0) // y0 ≤ y1 ≤ x0 ≤ x1
			p = 0;
		else
		if (x0 <= y0)
		{
			// y is subset of x
			if (x0 <= y0 && y1 <= x1) // x0 ≤ y0 ≤ y1 ≤ x1
				p = ((y0 - x0) + ((y1 - y0) / 2.)) / (x1 - x0);
			
			// x is mostly less than y
			else // x0 ≤ y0 ≤ x1 ≤ y1
				p = 1 - (((x1 - y0) * (x1 - y0)) / 2.) / ((x1 - x0) * (y1 - y0));
		}
		else
		if (y0 <= x0)
		{
			// x is subset of y
			if (y0 <= x0 && x1 <= y1) // y0 ≤ x0 ≤ x1 ≤ y1
				p = ((y1 - x1) + ((x1 - x0) / 2.)) / (y1 - y0);

			// y is mostly less than x
			else // y0 ≤ x0 ≤ y1 ≤ x1
				p =     (((y1 - x0) * (y1 - x0)) / 2.) / ((y1 - y0) * (x1 - x0));
		}
		else
			assert(false);

		return Probability(p);
	}
}

version(ae_unittest) unittest
{
	assert(cmp!">"(0, 1).p == 0  );
	assert(cmp!">"(1, 0).p == 1  );

	assert(cmp!"<"(1, 0).p == 0  );
	assert(cmp!"<"(0, 1).p == 1  );
}

version(ae_unittest) unittest
{
	auto a = range(1.0, 3.0);
	assert(cmp!"<"(a, 0.0).p == 0  );
	assert(cmp!"<"(a, 2.0).p == 0.5);
	assert(cmp!"<"(a, 5.0).p == 1  );

	assert(cmp!">"(a, 0.0).p == 1  );
	assert(cmp!">"(a, 2.0).p == 0.5);
	assert(cmp!">"(a, 5.0).p == 0  );
}

version(ae_unittest) unittest // number-to-range, int
{
	auto a = range(1, 2);

	assert(cmp!"<"(a, 1).p == 0  );
	assert(cmp!"<"(a, 2).p == 0.5);
	assert(cmp!"<"(a, 3).p == 1  );

	assert(cmp!">"(a, 0).p == 1  );
	assert(cmp!">"(a, 1).p == 0.5);
	assert(cmp!">"(a, 2).p == 0  );

	// instantiate template unittest
	alias le = cmp!"<=";
	alias ge = cmp!">=";
}

version(ae_unittest) unittest
{
	assert(cmp!"<" (range(0.), range(1.)).p == 1);
	assert(cmp!"<" (range(1.), range(0.)).p == 0);

	// assert(cmp!"<" (range(0.), range(0.)).p == 0);
	// assert(cmp!"<="(range(0.), range(0.)).p == 1);

	assert(cmp!"<" (range(0., 1.), range(0., 1.)).p == 0.5);
	assert(cmp!"<" (range(0., 1.), range(2., 3.)).p == 1.0);
	assert(cmp!"<" (range(2., 3.), range(0., 1.)).p == 0.0);
	assert(cmp!"<" (range(0., 1.), range(0., 2.)).p == 0.75);
	assert(cmp!"<" (range(0., 2.), range(1., 3.)).p == 7./8);
}

// ****************************************************************************

version (none)
{
	/// A quantized representation of a the probability distribution of
	/// some continuous function returning a value between 0 and 1.
	struct QuantizedDistribution(size_t numSegments, P = float, V = double)
	{
		enum V minValue = 0.0;
		enum V maxValue = 1.0;

		/// Represents the relative probability that the function will
		/// return a value in the represented interval.
		P[numSegments] buckets = 1.0;

		/// The length of one segment (of the function's return value) represented by one bucket.
		private enum V bucketSize = (maxValue - minValue) / numSegments;

		private static size_t toBucketIndex(V value)
		{
			assert(value >= minValue && value <= maxValue);
			auto bucketIndex = cast(size_t)((value - minValue) / (maxValue - minValue) * numSegments);
			assert(bucketIndex <= numSegments);
			if (bucketIndex == numSegments)
				bucketIndex = numSegments - 1; // 1.0 goes into the last bucket, together with 0.999...
			return bucketIndex;
		}

		private V bucketLowValue(size_t bucketIndex)
		{
			return minValue + ((maxValue - minValue) * bucketIndex / numSegments);
		}
		private V bucketHighValue(size_t bucketIndex)
		{
			return bucketLowValue(bucketIndex + 1);
		}

		/// Normalizes `buckets` so that they add up to 1.
		typeof(this) normalize()
		{
			typeof(this) result = this;
			P sum = result.buckets[].sum;
			result.buckets[] /= sum;
			return result;
		}

		/// Call `fun` a `numSamples` number of times, and return a distribution representing the result.
		static typeof(this) sample(V delegate() fun, size_t numSamples)
		{
			typeof(this) result;
			result.buckets[] = 0;
			foreach (_; 0 .. numSamples)
				result.buckets[toBucketIndex(fun())]++;
			return result;
		}

		Probability gt(V value)
		{
			auto bucketIndex = toBucketIndex(value);
			auto lowValue  = bucketLowValue (bucketIndex);
			auto highValue = bucketHighValue(bucketIndex);
			auto total = buckets[].sum;
			return Probability((
				buckets[0 .. bucketIndex].sum +
				itpl(0, buckets[bucketIndex], value, lowValue, highValue)
			) / total);
		}
	}

	version(ae_unittest) unittest
	{
		import std.random : Random, uniform, uniform01;
		import std.math.operations : isClose;

		auto rng = Random(0);
		{
			auto d = QuantizedDistribution!256.sample(() => uniform01!double(rng), 10_000);
			assert(d.gt(0.25).p.between(0.24, 0.26));
		}
		{
			auto d = QuantizedDistribution!256.sample(() => uniform(0, 4) == 0, 10_000);
			assert(d.gt(0.5).p.between(0.74, 0.76));
		}
	}
}
