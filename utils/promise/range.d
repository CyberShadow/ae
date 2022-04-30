/**
 * Promise range tools.
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

module ae.utils.promise.range;

import std.range.primitives;

import ae.net.asockets : socketManager;
import ae.utils.promise;

/// Given a range of promises, resolve them one after another,
/// and return a promise which is fulfilled when all promises in `range` are fulfilled.
/// `range` may be a lazy range (e.g. a `map` which produces promises from other input),
/// which will cause the work to be started only when the previous promise completes.
PromiseValueTransform!(ElementType!R, x => [x]) allSerial(R)(R range)
if (isInputRange!R)
{
	auto p = new typeof(return);

	alias P = ElementType!R;
	alias T = PromiseValue!P;
	alias E = PromiseError!P;

	typeof(p).ValueTuple results;
	static if (!is(T == void))
	{
		static if (hasLength!R)
			results[0].reserve(range.length);
	}

	void next()
	{
		if (range.empty)
			p.fulfill(results);
		else
		{
			range.front.then((P.ValueTuple value) {
				static if (!is(T == void))
					results[0] ~= value[0];
				next();
			}, (E error) {
				p.reject(error);
			});
			range.popFront();
		}
	}

	next();

	return p;
}

unittest
{
	import std.algorithm.iteration : map;
	import ae.sys.timing : setTimeout;
	import core.time : seconds;

	size_t sum;
	[1, 2, 3]
		.map!((n) {
			auto nextSum = sum + n;
			auto p = new Promise!void();
			setTimeout({ sum = nextSum; p.fulfill(); }, 0.seconds);
			return p;
		})
		.allSerial;
	socketManager.loop();
	assert(sum == 6);
}
