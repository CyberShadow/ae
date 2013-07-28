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

import ae.utils.meta : IsDebug;

/// An equivalent of an array range, but which maintains
/// a start and end pointer instead of a start pointer
/// and length. This allows .popFront to be faster.
/// Optionally, omits bounds checking for even more speed.
// TODO: Can we make CHECKED implicit, controlled by
//       -release, like regular arrays?
// TODO: Does this actually make a difference in practice?
//       Run some benchmarks...
struct FastArrayRange(T, bool CHECKED=IsDebug)
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

	alias this save;

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
