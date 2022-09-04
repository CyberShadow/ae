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

import std.algorithm.mutation;
import std.algorithm.sorting;
import std.parallelism;
import std.range : chunks, iota;

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

unittest
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

unittest
{
	assert([1, 2, 3].parallelEagerMap((int n) => n + 1) == [2, 3, 4]);
}
