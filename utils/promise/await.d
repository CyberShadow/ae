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

import ae.net.asockets : socketManager;
import ae.utils.promise;

enum defaultFiberSize = 64 * 1024;

/// UDA marking functions that must be called from within a fiber context (created via `async()`).
/// This is a documentation convention; the requirement is enforced at runtime by `await()`.
typeof(assert(false)) async()() { static assert(false, "This should be used only as an UDA (@async)"); }

/// Evaluates `task` in a new fiber, and returns a promise which is
/// fulfilled when `task` exits.  `task` may use `await` to block on
/// other promises.
// TODO: is using lazy OK for this? https://issues.dlang.org/show_bug.cgi?id=23923
Promise!(T, E) async(T, E = Exception)(@async lazy T task, size_t size = defaultFiberSize)
if (!is(T == return))
{
	return async({ return task; }, size);
}

/// ditto
Promise!(T, E) async(T, E = Exception)(@async T delegate() task, size_t size = defaultFiberSize)
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
Promise!(T, E) async(T, E = Exception)(@async T function() task)
if (!is(T == return))
{
	import std.functional : toDelegate;
	return async(task.toDelegate);
}

/// Synchronously waits until the promise `p` is fulfilled.
/// Can only be called in a fiber.
T await(T, E)(Promise!(T, E) p) @async
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

/// Synchronously starts and event loop and waits for it to exit.
/// Assumes that the promise `p` is resolved during the event loop;
/// Propagates any return value or exception to the caller.
T awaitSync(T, E)(Promise!(T, E) p)
{
	bool completed;
	Promise!T.ValueTuple taskValue;
	E taskError;

	p.then((Promise!T.ValueTuple value) {
		completed = true;
		taskValue = value;
	}, (E error) {
		completed = true;
		taskError = error;
	});

	socketManager.loop();

	assert(completed, "Event loop exited but the promise remained unresolved");
	if (taskError)
		throw taskError;
	else
	{
		static if (!is(T == void))
			return taskValue[0];
	}
}

debug(ae_unittest) unittest
{
	if (false)
	{
		async({}).awaitSync();
		async({}()).awaitSync();
	}
}
