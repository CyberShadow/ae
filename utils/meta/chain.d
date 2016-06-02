/**
 * ae.utils.meta.chain
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

/// Chains are a concept a bit like ranges,
/// but which operate on heterogenous types
/// (e.g. a tuple of values).

/// Composition is done by a chain of functors.
/// To allow state, each functor can be represented
/// as a struct.

/// Functors return a bool (true if iteration should
/// stop, false if it should continue).

module ae.utils.meta.chain;

///
unittest
{
	int a = 2;
	int x;
	chainIterator(chainFilter!(n => n > a)((int n) => (x = n, true)))(1, 2, 3);
	assert(x == 3);
}

// Work around egregious "cannot access frame pointer" errors
// TODO: File DMD bug
struct VoidProxy(T)
{
	void[T.sizeof] _VoidProxy_data;

	@property ref T _VoidProxy_value() { return *cast(T*)(_VoidProxy_data.ptr); }
	alias _VoidProxy_value this;
}

/// Starts the chain by iterating over a tuple.
struct ChainIterator(Next)
{
	VoidProxy!Next next;

	bool opCall(Args...)(auto ref Args args)
	{
		foreach (ref arg; args)
			if (next(arg))
				return true;
		return false;
	}
}
static template chainIterator(Next) /// ditto
{
	static auto chainIterator(Next next)
	{
		ChainIterator!Next f;
		f.next = next;
		return f;
	}
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
	chainIterator((long n) => (results ~= cast(int)n, false))(s.tupleof);
	assert(results == [1, 2, 3]);
}

/// Wraps a function template into a concrete value type functor.
struct ChainFunctor(alias fun)
{
	alias opCall = fun;
}
auto chainFunctor(alias fun)() /// ditto
{
	ChainFunctor!fun s;
	return s;
}

///
unittest
{
	int[] results;
	auto fn = chainFunctor!(n => results ~= cast(int)n);
	fn(1);
	fn(long(2));
	fn(ubyte(3));
	assert(results == [1, 2, 3]);
}

/// Calls next only if pred(value) is true.
struct ChainFilter(alias pred, Next)
{
	Next next;

	bool opCall(T)(auto ref T v)
	{
		if (pred(v))
			return next(v);
		return false;
	}
}
template chainFilter(alias pred) /// ditto
{
	auto chainFilter(Next)(Next next)
	{
		ChainFilter!(pred, Next) f;
		f.next = next;
		return f;
	}
}

///
unittest
{
	int a = 2;
	int b = 3;
	int[] results;
	foreach (i; 0..10)
		chainFilter!(n => n % a == 0)(chainFilter!(n => n % b == 0)((int n) => (results ~= n, false)))(i);
	assert(results == [0, 6]);
}

/// Calls next with pred(value).
struct ChainMap(alias pred, Next)
{
	Next next;

	bool opCall(T)(auto ref T v)
	{
		return next(pred(v));
	}
}
template chainMap(alias pred) /// ditto
{
	auto chainMap(Next)(Next next)
	{
		ChainMap!(pred, Next) f;
		f.next = next;
		return f;
	}
}

///
unittest
{
	int result;
	chainMap!(n => n+1)(chainMap!(n => n * 2)((int n) => (result = n, false)))(2);
	assert(result == 6);
}
