/**
 * ae.utils.range
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

module ae.utils.range;

import std.range.primitives;
import std.typecons;

import ae.utils.meta : isDebug;
import ae.utils.text.ascii : toDec;

/// An equivalent of an array range, but which maintains
/// a start and end pointer instead of a start pointer
/// and length. This allows .popFront to be faster.
/// Optionally, omits bounds checking for even more speed.
// TODO: Can we make CHECKED implicit, controlled by
//       -release, like regular arrays?
// TODO: Does this actually make a difference in practice?
//       Run some benchmarks...
struct FastArrayRange(T, bool CHECKED=isDebug)
{
	/// Current head and end.
	T* ptr, end;

	this(T[] arr)
	{
		ptr = arr.ptr;
		end = ptr + arr.length;
	} ///

	@property T front()
	{
		static if (CHECKED)
			assert(!empty);
		return *ptr;
	} ///

	void popFront()
	{
		static if (CHECKED)
			assert(!empty);
		ptr++;
	} ///

	@property bool empty() { return ptr==end; } ///

	@property ref typeof(this) save() { return this; } ///

	T opIndex(size_t index)
	{
		static if (CHECKED)
			assert(index < end-ptr);
		return ptr[index];
	} ///

	T[] opSlice()
	{
		return ptrSlice(ptr, end);
	} ///

	T[] opSlice(size_t from, size_t to)
	{
		static if (CHECKED)
			assert(from <= to && to <= end-ptr);
		return ptr[from..to];
	} ///
}

auto fastArrayRange(T)(T[] arr) { return FastArrayRange!T(arr); } /// ditto

// TODO move to ae.utils.array
/// Returns a slice for the memory from `a` to `b`.
T[] ptrSlice(T)(T* a, T* b)
{
	return a[0..b-a];
}

unittest
{
	FastArrayRange!ubyte r;
	auto x = r.save;
}

// ************************************************************************

/// Presents a null-terminated pointer (C-like string) as a range.
struct NullTerminatedPtrRange(E)
{
	E* ptr; /// Current head.
	bool empty() { return !*ptr; } ///
	ref E front() { return *ptr; } ///
	void popFront() { ptr++; } ///
	auto save() { return this; } ///
}
auto nullTerminatedPtrRange(E)(E* ptr)
{
	return NullTerminatedPtrRange!E(ptr);
} /// ditto

///
unittest
{
	void test(S)(S s)
	{
		import std.utf : byCodeUnit;
		import std.algorithm.comparison : equal;
		assert(equal(s.byCodeUnit, s.ptr.nullTerminatedPtrRange));
	}
	// String literals are null-terminated
	test("foo");
	test("foo"w);
	test("foo"d);
}

deprecated alias NullTerminated = NullTerminatedPtrRange;
deprecated alias nullTerminated = nullTerminatedPtrRange;

// ************************************************************************

/// Apply a predicate over each consecutive pair.
template pairwise(alias pred)
{
	import std.range : zip, dropOne;
	import std.algorithm.iteration : map;
	import std.functional : binaryFun;

	auto pairwise(R)(R r)
	{
		return zip(r, r.dropOne).map!(pair => binaryFun!pred(pair[0], pair[1]));
	}
}

///
unittest
{
	import std.algorithm.comparison : equal;
	assert(equal(pairwise!"a+b"([1, 2, 3]), [3, 5]));
	assert(equal(pairwise!"b-a"([1, 2, 3]), [1, 1]));
}

// ************************************************************************

/// An infinite variant of `iota`.
struct InfiniteIota(T)
{
	T front; ///
	enum empty = false; ///
	void popFront() { front++; } ///
	T opIndex(T offset) { return front + offset; } ///
	InfiniteIota save() { return this; } ///
}
InfiniteIota!T infiniteIota(T)() { return InfiniteIota!T.init; } /// ditto

// ************************************************************************

/// Empty range of type E.
struct EmptyRange(E)
{
	@property E front() { assert(false); } ///
	void popFront() { assert(false); } ///
	@property E back() { assert(false); } ///
	void popBack() { assert(false); } ///
	E opIndex(size_t) { assert(false); } ///
	enum empty = true; ///
	enum save = typeof(this).init; ///
	enum size_t length = 0; ///
}

EmptyRange!E emptyRange(E)() { return EmptyRange!E.init; } /// ditto

static assert(isInputRange!(EmptyRange!uint));
static assert(isForwardRange!(EmptyRange!uint));
static assert(isBidirectionalRange!(EmptyRange!uint));
static assert(isRandomAccessRange!(EmptyRange!uint));

// ************************************************************************

/// Like `only`, but evaluates the argument lazily, i.e. when the
/// range's "front" is evaluated.
/// DO NOT USE before this bug is fixed:
/// https://issues.dlang.org/show_bug.cgi?id=11044
auto onlyLazy(E)(lazy E value)
{
	struct Lazy
	{
		bool empty = false;
		@property E front() { assert(!empty); return value; }
		void popFront() { assert(!empty); empty = true; }
		alias back = front;
		alias popBack = popFront;
		@property size_t length() { return empty ? 0 : 1; }
		E opIndex(size_t i) { assert(!empty); assert(i == 0); return value; }
		@property typeof(this) save() { return this; }
	}
	return Lazy();
}

static assert(isInputRange!(typeof(onlyLazy(1))));
static assert(isForwardRange!(typeof(onlyLazy(1))));
static assert(isBidirectionalRange!(typeof(onlyLazy(1))));
static assert(isRandomAccessRange!(typeof(onlyLazy(1))));

unittest
{
	import std.algorithm.comparison;
	import std.range;

	int i;
	auto r = onlyLazy(i);
	i = 1; assert(equal(r, 1.only));
	i = 2; assert(equal(r, 2.only));
}

// ************************************************************************

/// Defer range construction until first empty/front call.
auto lazyInitRange(R)(R delegate() constructor)
{
	bool initialized;
	R r = void;

	ref R getRange()
	{
		if (!initialized)
		{
			r = constructor();
			initialized = true;
		}
		return r;
	}

	struct LazyRange
	{
		bool empty() { return getRange().empty; }
		auto ref front() { return getRange().front; }
		void popFront() { return getRange().popFront; }
	}
	return LazyRange();
}

///
unittest
{
	import std.algorithm.iteration;
	import std.range;

	int[] todo, done;
	chain(
		only({ todo = [1, 2, 3]; }),
		// eager will fail: todo.map!(n => (){ done ~= n; }),
		lazyInitRange(() => todo.map!(n => (){ done ~= n; })),
	).each!(dg => dg());
	assert(done == [1, 2, 3]);
}

// ************************************************************************

/// A faster, random-access version of `cartesianProduct`.
auto fastCartesianProduct(R...)(R ranges)
{
	struct Product
	{
		size_t start, end;
		R ranges;
		auto front() { return this[0]; }
		void popFront() { start++; }
		auto back() { return this[$-1]; }
		void popBack() { end--; }
		bool empty() const { return start == end; }
		size_t length() { return end - start; }
		alias opDollar = length;

		auto opIndex(size_t index)
		{
			auto p = start + index;
			size_t[R.length] positions;
			foreach (i, r; ranges)
			{
				auto l = r.length;
				positions[i] = p % l;
				p /= l;
			}
			assert(p == 0, "Out of bounds");
			mixin({
				string s;
				foreach (i; 0 .. R.length)
					s ~= `ranges[` ~ toDec(i) ~ `][positions[` ~ toDec(i) ~ `]], `;
				return `return tuple(` ~ s ~ `);`;
			}());
		}
	}
	size_t end = 1;
	foreach (r; ranges)
		end *= r.length;
	return Product(0, end, ranges);
}

unittest
{
	import std.algorithm.comparison : equal;
	assert(fastCartesianProduct().length == 1);
	assert(fastCartesianProduct([1, 2, 3]).equal([tuple(1), tuple(2), tuple(3)]));
	assert(fastCartesianProduct([1, 2], [3, 4, 5]).equal([
		tuple(1, 3), tuple(2, 3),
		tuple(1, 4), tuple(2, 4),
		tuple(1, 5), tuple(2, 5),
	]));
}

// ************************************************************************

/// Calculate the mean value of the range's elements (sum divided by length).
/// The range must obviously be non-empty.
auto average(R)(R range) if (hasLength!R)
{
	import std.algorithm.iteration : sum;
	return sum(range) / range.length;
}

unittest
{
	assert([1, 2, 3].average == 2);
}

// ************************************************************************

static import ae.utils.functor.algorithm;
deprecated alias pmap = ae.utils.functor.algorithm.map;
