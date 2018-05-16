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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.range;

import ae.utils.meta : isDebug;

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
	T* ptr, end;

	this(T[] arr)
	{
		ptr = arr.ptr;
		end = ptr + arr.length;
	}

	@property T front()
	{
		static if (CHECKED)
			assert(!empty);
		return *ptr;
	}

	void popFront()
	{
		static if (CHECKED)
			assert(!empty);
		ptr++;
	}

	@property bool empty() { return ptr==end; }

	@property ref typeof(this) save() { return this; }

	T opIndex(size_t index)
	{
		static if (CHECKED)
			assert(index < end-ptr);
		return ptr[index];
	}

	T[] opSlice()
	{
		return ptrSlice(ptr, end);
	}

	T[] opSlice(size_t from, size_t to)
	{
		static if (CHECKED)
			assert(from <= to && to <= end-ptr);
		return ptr[from..to];
	}
}

auto fastArrayRange(T)(T[] arr) { return FastArrayRange!T(arr); }

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

struct InfiniteIota(T)
{
	T front;
	enum empty = false;
	void popFront() { front++; }
	T opIndex(T offset) { return front + offset; }
	InfiniteIota save() { return this; }
}
InfiniteIota!T infiniteIota(T)() { return InfiniteIota!T.init; }
