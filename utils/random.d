/**
 * ae.utils.random
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

module ae.utils.random;

import std.algorithm.comparison;
import std.algorithm.mutation;
import std.array;
import std.random;
import std.range.primitives;

/// Like `randomShuffle`, but returns results incrementally
/// (still copies the input, but calls `gen` only as needed).
/// Like `randomCover`, but much faster
/// (O(n) instead of O(n^2), though less space-efficient.
auto incrementalRandomShuffle(Range, RandomGen)(Range range, ref RandomGen gen)
if (isInputRange!Range && isUniformRNG!RandomGen)
{
	alias E = ElementType!Range;
	static struct IncrementalRandomShuffle
	{
	private:
		E[] arr;
		size_t i;
		RandomGen* gen;

		this(Range range, RandomGen* gen)
		{
			this.arr = range.array;
			this.gen = gen;
			prime();
		}

		void prime()
		{
			import std.algorithm.mutation : swapAt;
			arr.swapAt(i, i + uniform(0, arr.length - i, gen));
		}

	public:
		@property bool empty() const { return i == arr.length; }
		ref E front() { return arr[i]; }
		void popFront()
		{
			i++;
			if (!empty)
				prime();
		}
	}

	return IncrementalRandomShuffle(move(range), &gen);
}

auto incrementalRandomShuffle(Range)(Range range)
if (isInputRange!Range)
{ return incrementalRandomShuffle(range, rndGen); }

unittest
{
	auto shuffled = [1, 2].incrementalRandomShuffle;
	assert(shuffled.equal([1, 2]) || shuffled.equal([2, 1]));
}
