/**
 * Number stuff
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

module ae.utils.math;

/// Return `b` bound by `a` and `c` (i.e., `min(max(a, b), c)`).
typeof(Ta+Tb+Tc) bound(Ta, Tb, Tc)(Ta a, Tb b, Tc c) { return a<b?b:a>c?c:a; }

/// Return true if `a <= point <= b`.
bool between(T)(T point, T a, T b) { return a <= point && point <= b; }

/// Return `x*x`.
auto sqr(T)(T x) { return x*x; }

/// If `x > y`, swaps `x` and `y`.
void sort2(T)(ref T x, ref T y) { if (x > y) { T z=x; x=y; y=z; } }

/// Performs linear interpolation.
/// Returns the point between `low` and `high` corresponding to the point where `r` is between `rLow` and `rHigh`.
T itpl(T, U)(T low, T high, U r, U rLow, U rHigh)
{
	import std.traits : Signed;
	return cast(T)(low + (cast(Signed!T)high-cast(Signed!T)low) * (cast(Signed!U)r - cast(Signed!U)rLow) / (cast(Signed!U)rHigh - cast(Signed!U)rLow));
}

/// Returns the sign of `x`, i.e,
/// `-1` if `x < 0`, `+1` if `x > 0`,, or `0` if `x == 0`.
byte sign(T)(T x) { return x<0 ? -1 : x>0 ? 1 : 0; }

/// Returns the next and previous values of `v`, as defined by the ++ and -- operators.
T next(T)(T v) { return ++v; }
T prev(T)(T v) { return --v; } /// ditto

/// Returns the logical value of `sign(b - a)`
/// (but does not actually subtract to avoid overflow).
int compare(T)(T a, T b)
{
	return a<b ? -1 : a>b ? 1 : 0;
}

/// Apply a binary operation consecutively to `args`.
auto op(string OP, T...)(T args)
{
	auto result = args[0];
	foreach (arg; args[1..$])
		mixin("result" ~ OP ~ "=arg;");
	return result;
}

/// Sums `args`.
auto sum(T...)(T args) if (is(typeof(args[0] + args[0]))) { return op!"+"(args); }
/// Averages `args`.
auto average(T...)(T args) if (is(typeof(args[0] + args[0]))) { return sum(args) / args.length; }

/// Wraps a D binary operator into a function.
template binary(string op)
{
	auto binary(A, B)(auto ref A a, auto ref B b) { return mixin(`a` ~ op ~ `b`); }
}
/// Aliases of D binary operators as functions. Usable in UFCS.
alias eq = binary!"==";
alias ne = binary!"!="; /// ditto
alias lt = binary!"<" ; /// ditto
alias gt = binary!">" ; /// ditto
alias le = binary!"<="; /// ditto
alias ge = binary!">="; /// ditto

/// Length of intersection of two segments on a line,
/// or 0 if they do not intersect.
T rangeIntersection(T)(T a0, T a1, T b0, T b1)
{
	import std.algorithm.comparison : min, max;

	auto x0 = max(a0, b0);
	auto x1 = min(a1, b1);
	return x0 < x1 ? x1 - x0 : 0;
}

debug(ae_unittest) unittest
{
	assert(rangeIntersection(0, 2, 1, 3) == 1);
	assert(rangeIntersection(0, 1, 2, 3) == 0);
}

/// Wraps a D unary operator into a function.
/// Does not do integer promotion.
template unary(char op)
{
	T unary(T)(T value)
	{
		// Silence DMD 2.078.0 warning about integer promotion rules
		// https://dlang.org/changelog/2.078.0.html#fix16997
		static if ((op == '-' || op == '+' || op == '~') && is(T : int))
			alias CastT = int;
		else
			alias CastT = T;
		return mixin(`cast(T)` ~ op ~ `cast(CastT)value`);
	}
}

/// Like the ~ operator, but without int-promotion.
alias flipBits = unary!'~';

debug(ae_unittest) unittest
{
	ubyte b = 0x80;
	auto b2 = b.flipBits;
	assert(b2 == 0x7F);
	static assert(is(typeof(b2) == ubyte));
}

/// Swap the byte order in an integer value.
T swapBytes(T)(T b)
if (is(T : uint))
{
	import core.bitop : bswap;
	static if (b.sizeof == 1)
		return b;
	else
	static if (b.sizeof == 2)
		return cast(T)((b >> 8) | (b << 8));
	else
	static if (b.sizeof == 4)
		return bswap(b);
	else
		static assert(false, "Don't know how to bswap " ~ T.stringof);
}

/// True if `x` is some power of two, including `1`.
bool isPowerOfTwo(T)(T x) { return (x & (x-1)) == 0; }

/// Round up `x` to the next power of two.
/// If `x` is already a power of two, returns `x`.
T roundUpToPowerOfTwo(T)(T x) { return nextPowerOfTwo(x-1); }

/// Return the next power of two after `x`, not including it.
T nextPowerOfTwo(T)(T x)
{
	x |= x >>  1;
	x |= x >>  2;
	x |= x >>  4;
	static if (T.sizeof > 1)
		x |= x >>  8;
	static if (T.sizeof > 2)
		x |= x >> 16;
	static if (T.sizeof > 4)
		x |= x >> 32;
	return x + 1;
}

/// Integer log2.
ubyte ilog2(T)(T n)
{
	ubyte result = 0;
	while (n >>= 1)
		result++;
	return result;
}

debug(ae_unittest) unittest
{
	assert(ilog2(0) == 0);
	assert(ilog2(1) == 0);
	assert(ilog2(2) == 1);
	assert(ilog2(3) == 1);
	assert(ilog2(4) == 2);
}

/// Returns the number of bits needed to
/// store a number up to n (inclusive).
ubyte bitsFor(T)(T n)
{
	return cast(ubyte)(ilog2(n)+1);
}

debug(ae_unittest) unittest
{
	assert(bitsFor( int.max) == 31);
	assert(bitsFor(uint.max) == 32);
}

/// Get the smallest built-in unsigned integer type
/// that can store this many bits of data.
template TypeForBits(uint bits)
{
	///
	static if (bits <= 8)
		alias TypeForBits = ubyte;
	else
	static if (bits <= 16)
		alias TypeForBits = ushort;
	else
	static if (bits <= 32)
		alias TypeForBits = uint;
	else
	static if (bits <= 64)
		alias TypeForBits = ulong;
	else
		static assert(false, "No integer type big enough for " ~ bits.stringof ~ " bits");
}

static assert(is(TypeForBits!7 == ubyte));
static assert(is(TypeForBits!8 == ubyte));
static assert(is(TypeForBits!9 == ushort));
static assert(is(TypeForBits!64 == ulong));
static assert(!is(TypeForBits!65));

/// Saturate `v` to be the smallest value between itself and `args`.
void minimize(T, Args...)(ref T v, Args args)
if (is(typeof({ import std.algorithm.comparison : min; v = min(v, args); })))
{
	import std.algorithm.comparison : min;
	v = min(v, args);
}

/// Saturate `v` to be the largest value between itself and `args`.
void maximize(T, Args...)(ref T v, Args args)
if (is(typeof({ import std.algorithm.comparison : max; v = max(v, args); })))
{
	import std.algorithm.comparison : max;
	v = max(v, args);
}

debug(ae_unittest) unittest
{
	int i = 5;
	i.minimize(2); assert(i == 2);
	i.minimize(5); assert(i == 2);
	i.maximize(5); assert(i == 5);
	i.maximize(2); assert(i == 5);
}
