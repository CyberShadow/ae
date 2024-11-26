/**
 * ae.utils.parallelism
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

module ae.utils.parallelism;

import ae.utils.array : amap;

import std.algorithm.comparison : min;
import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.parallelism;
import std.range : chunks, iota;
import std.range.primitives;

// https://gist.github.com/63e139a16b9b278fb5d449ace611e7b8

/// Sort `r` using all CPU cores.
auto parallelSort(alias less = "a < b", R)(R r)
{
	auto impl(size_t depth = 0)(R order)
	{
		static if (depth < 8)
			if ((1L << depth) < totalCPUs)
				foreach (chunk; order.chunks(order.length / 2 + 1).parallel(1))
					impl!(depth + 1)(chunk);

		return order.sort!(less, SwapStrategy.stable, R);
	}
	return impl(r);
}

debug(ae_unittest) unittest
{
	assert([3, 1, 2].parallelSort.release == [1, 2, 3]);
}


/// Parallel map.  Like TaskPool.amap, but uses functors for
/// predicates instead of alias arguments, and as such does not have
/// the multiple-context problem.
/// https://forum.dlang.org/post/qnigarkuxxnqwdernhzv@forum.dlang.org
auto parallelEagerMap(R, Pred)(R input, Pred pred, size_t workUnitSize = 0)
{
	if (workUnitSize == 0)
		workUnitSize = taskPool.defaultWorkUnitSize(input.length);
	alias RT = typeof(pred(input[0]));
	auto result = new RT[input.length];
	foreach (i; input.length.iota.parallel(workUnitSize))
		result[i] = pred(input[i]);
	return result;
}

debug(ae_unittest) unittest
{
	assert([1, 2, 3].parallelEagerMap((int n) => n + 1) == [2, 3, 4]);
}


/// Compare two arrays for equality, in parallel.
bool parallelEqual(T)(T[] a, T[] b)
{
	if (a.length != b.length)
		return false;

	static bool[] chunkEqualBuf;
	if (!chunkEqualBuf)
		chunkEqualBuf = new bool[totalCPUs];
	auto chunkEqual = chunkEqualBuf;
	foreach (threadIndex; totalCPUs.iota.parallel(1))
	{
		auto start = a.length * (threadIndex    ) / totalCPUs;
		auto end   = a.length * (threadIndex + 1) / totalCPUs;
		chunkEqual[threadIndex] = a[start .. end] == b[start .. end];
	}
	return chunkEqual.all!(a => a)();
}

debug(ae_unittest) unittest
{
	import std.array : array;
	auto a = 1024.iota.array;
	auto b = a.dup;
	assert(parallelEqual(a, b));
	b[500] = 0;
	assert(!parallelEqual(a, b));
}

// ************************************************************************

private auto parallelChunkOffsets(size_t length)
{
	size_t numChunks = min(length, totalCPUs);
	return (numChunks + 1).iota.map!(chunkIndex => chunkIndex * length / numChunks);
}

/// Split a range into chunks, processing each chunk in parallel.
/// Returns a dynamic array containing the result of calling `fun` on each chunk.
/// `fun` is called at most once per CPU core.
T[] parallelChunks(R, T)(R range, scope T delegate(R) fun)
if (isRandomAccessRange!R)
{
	auto offsets = parallelChunkOffsets(range.length);
	size_t numChunks = offsets.length - 1;
	auto result = new T[numChunks];
	foreach (chunkIndex; numChunks.iota.parallel(1))
		result[chunkIndex] = fun(range[offsets[chunkIndex] .. offsets[chunkIndex + 1]]);
	return result;
}

/// ditto
T[] parallelChunks(N, T)(N total, scope T delegate(N start, N end) fun)
if (is(N : ulong))
{
	auto offsets = parallelChunkOffsets(total);
	size_t numChunks = offsets.length - 1;
	auto result = new T[numChunks];
	foreach (chunkIndex; numChunks.iota.parallel(1))
		result[chunkIndex] = fun(cast(N)offsets[chunkIndex], cast(N)offsets[chunkIndex + 1]);
	return result;
}

/// ditto
auto parallelChunks(alias fun, R)(R range)
if (isRandomAccessRange!R)
{
	alias T = typeof(fun(range[0..0]));
	auto offsets = parallelChunkOffsets(range.length);
	size_t numChunks = offsets.length - 1;
	auto result = new T[numChunks];
	foreach (chunkIndex; numChunks.iota.parallel(1))
		result[chunkIndex] = fun(range[offsets[chunkIndex] .. offsets[chunkIndex + 1]]);
	return result;
}

/// ditto
auto parallelChunks(alias fun, N)(N total)
if (is(N : ulong))
{
	alias T = typeof(fun(N.init, N.init));
	auto offsets = parallelChunkOffsets(total);
	size_t numChunks = offsets.length - 1;
	auto result = new T[numChunks];
	foreach (chunkIndex; numChunks.iota.parallel(1))
		result[chunkIndex] = fun(cast(N)offsets[chunkIndex], cast(N)offsets[chunkIndex + 1]);
	return result;
}

debug(ae_unittest) unittest
{
	import std.algorithm.iteration : sum;
	assert([1, 2, 3].parallelChunks((int[] arr) => arr.sum).sum == 6);
	assert(4.parallelChunks((int low, int high) => iota(low, high).sum).sum == 6);
	assert([1, 2, 3].parallelChunks!(arr => arr.sum).sum == 6);
	assert(4.parallelChunks!((low, high) => iota(low, high).sum).sum == 6);
}

// ************************************************************************

/// Filters `input` in parallel.
/// This version calls `fun` only once per `input` element
/// (at the expense of additional used memory).
auto parallelCachedFilter(alias fun, R)(R input)
if (isInputRange!R && is(typeof(fun(input.front))))
{
	import ae.utils.functor.primitives : functor;

	auto inputOffsets = parallelChunkOffsets(input.length);

	bool[][] wantedChunks = input.parallelChunks!(chunk => chunk.map!fun.array);
	auto numChunks = wantedChunks.length;
	auto outputCounts = wantedChunks.parallelEagerMap(functor!((bool[] chunk) => chunk.reduce!((a, b) => size_t(a) + size_t(b))));
	auto outputOffsets = 0 ~ outputCounts.cumulativeFold!((a, b) => a + b).array;
	auto outputTotal = outputOffsets[$-1];
	auto output = new typeof(input.front)[outputTotal];
	foreach (chunkIndex; numChunks.iota.parallel)
	{
		auto chunkOutputIndex = outputOffsets[chunkIndex];
		auto chunkInputOffset = inputOffsets[chunkIndex];
		foreach (chunkInputIndex, wanted; wantedChunks[chunkIndex])
			if (wanted)
				output[chunkOutputIndex++] = input[chunkInputOffset + chunkInputIndex];
	}
	return output;
}

debug(ae_unittest) unittest
{
	assert([1, 2, 3].parallelCachedFilter!(x => x % 2 == 0) == [2]);
}

// ************************************************************************

template parallelReduce(alias fun)
{
	auto parallelReduce(R)(R range)
	{
		import std.algorithm.iteration : reduce;
		return range.parallelChunks!(chunk => chunk.reduce!fun).reduce!fun;
	}
}

// alias parallelSum = parallelReduce!((a, b) => a + b);

debug(ae_unittest) unittest
{
	import std.algorithm.iteration : sum;
	assert([1, 2, 3].parallelReduce!((a, b) => a + b) == 6);
}

auto parallelSum(R)(R range)
{
	import std.algorithm.iteration : sum;
	return range.parallelChunks!sum.sum;
}

debug(ae_unittest) unittest
{
	import std.algorithm.iteration : sum;
	assert([1, 2, 3].parallelSum == 6);
}
