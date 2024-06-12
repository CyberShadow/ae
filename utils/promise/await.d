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

enum defaultFiberSize = 64 * 1024;

/// Evaluates `task` in a new fiber, and returns a promise which is
/// fulfilled when `task` exits.  `task` may use `await` to block on
/// other promises.
// TODO: is using lazy OK for this? https://issues.dlang.org/show_bug.cgi?id=23923
Promise!(T, E) async(T, E = Exception)(lazy T task, size_t size = defaultFiberSize)
if (!is(T == return))
{
	return async({ return task; }, size);
}

/// ditto
Promise!(T, E) async(T, E = Exception)(T delegate() task, size_t size = defaultFiberSize)
if (!is(T == return))
{
	auto p = new Promise!T;
	auto f = new Fiber({
		try
			static if (is(T == void))
				task(), p.fulfill();
			else
				p.fulfill(task());
		catch (E e)
			p.reject(e);
	}, size);
	f.call();
	return p;
}

/// ditto
Promise!(T, E) async(T, E = Exception)(T function() task)
if (!is(T == return))
{
	import std.functional : toDelegate;
	return async(task.toDelegate);
}

/// Synchronously waits until the promise `p` is fulfilled.
/// Can only be called in a fiber.
T await(T, E)(Promise!(T, E) p)
{
	Promise!T.ValueTuple fiberValue;
	E fiberError;

	auto f = Fiber.getThis();
	assert(f, "await called while not in a fiber");
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
debug(ae_unittest) unittest
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

debug(ae_unittest) unittest
{
	if (false)
	{
		async({}).await();
		async({}()).await();
	}
}
