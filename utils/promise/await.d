/**
 * async/await-like API for asynchronous tasks combining promises and
 * fibers.
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

module ae.utils.promise.await;

import core.thread : Fiber;

import ae.utils.promise;

/// Evaluates `task` in a new fiber, and returns a promise which is
/// fulfilled when `task` exits.  `task` may use `await` to block on
/// other promises.
Promise!(T, E) async(T, E = Exception)(lazy T task)
{
	auto p = new Promise!T;
	auto f = new Fiber({
		try
			static if (is(T == void))
				task, p.fulfill();
			else
				p.fulfill(task);
		catch (E e)
			p.reject(e);
	});
	f.call();
	return p;
}

/// Synchronously waits until the promise `p` is fulfilled.
/// Can only be called in a fiber.
T await(T, E)(Promise!(T, E) p)
{
	Promise!T.ValueTuple fiberValue;
	E fiberError;

	auto f = Fiber.getThis();
	p.then((Promise!T.ValueTuple value) {
		fiberValue = value;
		f.call();
	}, (E error) {
		fiberError = error;
		f.call();
	});
	Fiber.yield();
	if (fiberError)
		throw fiberError;
	else
	{
		static if (!is(T == void))
			return fiberValue[0];
	}
}

///
unittest
{
	import ae.net.asockets : socketManager;

	auto one = resolve(1);
	auto two = resolve(2);

	int sum;
	async(one.await + two.await).then((value) {
		sum = value;
	});
	socketManager.loop();
	assert(sum == 3);
}

unittest
{
	if (false)
	{
		async({}()).await();
	}
}
