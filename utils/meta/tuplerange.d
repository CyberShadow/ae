/**
 * ae.utils.meta.tuplerange
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

/// Contains constructs for iterating and chaining together operations
/// on tuple ranges (range-like constructs which operate on
/// heterogeneous types).

/// To allow heterogeneous elements, iteration is internal rather than
/// external.  The range elements are functors - calling a range with
/// a function parameter "next" asks the range to iterate over its
/// members and call "next" over each one.  "next" returns a bool
/// (true if iteration should stop, false if it should continue),
/// which is propagated by the range's opCall upwards.

module ae.utils.meta.tuplerange;

///
unittest
{
	int a = 2;
	int offset = 1;
	int x;
	trOnly(0, 1., 2f)
		.trMap!(n => n + offset)
		.trFilter!(n => n > a)
		.trEach!((n) { x = cast(int)n; } );
	assert(x == 3);
}

import std.meta;

import ae.utils.meta.caps;

unittest
{
	static struct X
	{
		bool fun(int x)
		{
			return this.tupleof
				.trOnly
				.trEach!(n => n == x);
		}

		long a;
		int b;
		ubyte c;
	}

	X x;
	assert(!x.fun(5));
	x.c = 5;
	assert(x.fun(5));
}

/// Source, iterates over the given values.
auto trOnly(T...)(ref return T values)
{
	alias PointerTo(T) = T*;
	alias P = staticMap!(PointerTo, T);
	struct Result
	{
		P values; this(P values) { this.values = values; }
		bool opCall(Next)(Next next)
		{
			foreach (ref value; values)
				if (next(*value))
					return true;
			return false;
		}
	}
	P pvalues;
	foreach (i, ref value; values)
		pvalues[i] = &value;
	return Result(pvalues);
}

auto trOnly(T...)(T values) /// ditto
{
	static struct Result
	{
		T values; this(T values) { this.values = values; }
		
		bool opCall(Next)(Next next)
		{
			foreach (ref value; values)
				if (next(value))
					return true;
			return false;
		}
	}
	return Result(values);
}

unittest
{
	static int fun()
	{
		int a = 2;
		int offset = 1;
		int x;
		trOnly(0, 1., 2f)
			.trMap!(n => n + offset)
			.trFilter!(n => n > a)
			.trEach!((n) { x = cast(int)n; } );
		return x;
	}
	static assert(fun() == 3);
}

unittest
{
	static int fun()
	{
		int a = 2;
		int offset = 1;
		int result;
		int x = 0; double y = 1.; float z = 2f;
		trOnly(x, y, z)
			.trMap!(n => n + offset)
			.trFilter!(n => n > a)
			.trEach!((n) { result = cast(int)n; } );
		return result;
	}
	static assert(fun() == 3);
}

unittest
{
	struct S
	{
		int a = 1;
		long b = 2;
		ubyte c = 3;
	}
	S s;

	int[] results;
	s.tupleof
		.trOnly
		.trEach!((long n) { results ~= cast(int)n; });
	assert(results == [1, 2, 3]);
}

/// Passes only values satisfying the given predicate to the next
/// layer.
auto trFilter(alias pred, R)(auto ref R r)
{
	struct Result
	{
		R r; this(R r) { this.r = r; }

		bool opCall(Next)(Next next)
		{
			struct Handler
			{
				bool opCall(T)(auto ref T value)
				{
					if (!pred(value))
						return false; // keep going
					return next(value);
				}
			}
			Handler handler;
			return r(handler);
		}
	}
	return Result(r);
}

///
unittest
{
	int a = 2;
	int b = 3;
	int[] results;
	foreach (i; 0..10)
		(i)
			.trOnly
			.trFilter!(n => n % a == 0)
			.trFilter!(n => n % b == 0)
			.trEach!((int n) { results ~= n; });
	assert(results == [0, 6]);
}

/// Like trFilter, but evaluates pred at compile-time with each
/// element's type.
auto trCTFilter(alias pred, R)(auto ref R r)
{
	struct Result
	{
		R r; this(R r) { this.r = r; }

		bool opCall(Next)(Next next)
		{
			struct Handler
			{
				bool opCall(T)(auto ref T value)
				{
					static if (!pred!T)
						return false; // keep going
					else
						return next(value);
				}
			}
			Handler handler;
			return r(handler);
		}
	}
	return Result(r);
}

///
unittest
{
	enum isNumeric(T) = is(typeof(cast(int)T.init));
	int[] results;
	trOnly(1, 2., "3", '\x04')
		.trCTFilter!isNumeric
		.trEach!((n) { results ~= cast(int)n; });
	assert(results == [1, 2, 4]);
}

/// Transforms values using the given predicate before passing them to
/// the next layer.
auto trMap(alias pred, R)(auto ref R r)
{
	struct Result
	{
		R r; this(R r) { this.r = r; }

		bool opCall(Next)(Next next)
		{
			struct Handler
			{
				bool opCall(T)(auto ref T value)
				{
					return next(pred(value));
				}
			}
			Handler handler;
			return r(handler);
		}
	}
	return Result(r);
}

///
unittest
{
	int result;
	(2)
		.trOnly
		.trMap!(n => n+1)
		.trMap!(n => n * 2)
		.trEach!((int n) { result = n; });
	assert(result == 6);
}

/// Sink, calls predicate over each value in r.
/// If predicate returns a boolean, use that to determine whether to
/// stop or keep going.
auto trEach(alias pred, R)(auto ref R r)
{
	struct Handler
	{
		bool opCall(T)(auto ref T value)
		{
			alias R = typeof(pred(value));
			static if (is(R == bool))
				return pred(value);
			else
			static if (is(R == void))
			{
				pred(value);
				return false; // keep going
			}
			else
				static assert(false);
		}
	}
	Handler handler;
	return r(handler);
}

/// Calls predicate with only the first value in r.
auto trFront(alias pred, R)(auto ref R r)
{
	struct Handler
	{
		bool opCall(T)(auto ref T value)
		{
			pred(value);
			return true;
		}
	}
	Handler handler;
	return r(handler);
}

/// r is a tuple range of tuple ranges.
/// Process it as one big range.
auto trJoiner(R)(auto ref R r)
{
	struct Result
	{
		R r; this(R r) { this.r = r; }

		bool opCall(Next)(Next next)
		{
			struct Handler
			{
				bool opCall(T)(auto ref T value)
				{
					return value(next);
				}
			}
			Handler handler;
			return r(handler);
		}
	}
	return Result(r);
}

unittest
{
	int[] values;
	trOnly(
		trOnly(1, 2f),
		trOnly(3.0, '\x04'),
	)
		.trJoiner
		.trEach!((n) { values ~= cast(int)n; });
	assert(values == [1, 2, 3, 4]);
}

/// Convert a regular (homogeneous) range to a tuple range.
auto trIter(R)(auto ref R r)
{
	struct Result
	{
		R r; this(R r) { this.r = r; }

		bool opCall(Next)(Next next)
		{
			foreach (ref e; r)
				if (next(e))
					return true;
			return false;
		}
	}
	return Result(r);
}

unittest
{
	int[] values;
	trOnly(
		[1., 2.].trIter,
		['\x03', '\x04'].trIter,
	)
		.trJoiner
		.trEach!((n) { values ~= cast(int)n; });
	assert(values == [1, 2, 3, 4]);
	
}
