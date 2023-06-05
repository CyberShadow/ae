/**
 * Promise concurrency tools.
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

module ae.utils.promise.concurrency;

import core.thread;

import std.traits;
import std.typecons : No;

import ae.net.sync;
import ae.utils.aa : updateVoid;
import ae.utils.meta;
import ae.utils.promise;

/// Evaluate `value` in a new thread.
/// The promise is resolved in the current (calling) thread.
// TODO: is using lazy OK for this? https://issues.dlang.org/show_bug.cgi?id=23923
Promise!(T, E) threadAsync(T, E = Exception)(lazy T value)
{
	auto p = new Promise!T;
	auto mainThread = new ThreadAnchor(No.daemon);
	Thread t;
	t = new Thread({
		try
		{
			auto result = value.voidStruct;
			mainThread.runAsync({
				t.join();
				p.fulfill(result.tupleof);
			});
		}
		catch (Exception e)
			mainThread.runAsync({
				t.join();
				p.reject(e);
			});
		mainThread.close();
	});
	t.start();
	return p;
}

unittest
{
	import ae.net.asockets : socketManager;

	int ok;

	Thread.sleep(1.msecs).threadAsync.then(() { ok++; });
	"foo".threadAsync.dmd21804workaround.then((s) { ok += s == "foo"; });
	(){throw new Exception("yolo");}().threadAsync.then((){}, (e) { ok += e.msg == "yolo"; });

	socketManager.loop();
	assert(ok == 3, [cast(char)('0'+ok)]);
}

/// Given a function `fun` which returns a promise,
/// globally memoize it (across all threads),
/// so that at most one invocation of `fun` with the given parameters
/// is invoked during the program's lifetime.
/// If a `fun` promise is in progress (incl. if started
/// by another thread), wait for it to finish first.
template globallyMemoized(alias fun)
if (is(ReturnType!fun == Promise!(T, E), T, E))
{
	alias P = ReturnType!fun;
	static if (is(FunctionTypeOf!fun PT == __parameters))
	{
		P globallyMemoized(PT args)
		{
			// At any point in time (excluding times when it is
			// being updated, i.e. when the mutex lock is held),
			// a cache entry can be in one of three states:
			// - nonexistent (no one tried to calculate this result yet)
			// - in progress (someone started work on this)
			// - resolved (the work has finished)
			static struct Key
			{
				Parameters!fun args;
			}
			static struct Entry
			{
				ThreadAnchor ownerThread;
				P realPromise; // only safe to access in ownerThread
				bool resolved; // avoid thread roundtrip, as an optimization
			}
			__gshared Entry*[Key] cache;

			auto key = Key(args);

			P localPromise;
			synchronized cache.updateVoid(key,
				{
					localPromise = fun(args);
					return new Entry(thisThread, localPromise);
				},
				(ref Entry* entry)
				{
					if (entry.resolved)
					{
						// If we know that the promise is settled,
						// then it is effectively immutable,
						// and it is safe to return it as is.
						localPromise = entry.realPromise;
					}
					else
					{
						auto localThread = thisThread;
						if (entry.ownerThread is localThread)
						{
							// We are in the thread that owns this promise.
							// Just return it.
							localPromise = entry.realPromise;
						}
						else
						{
							// Go to the thread that created the promise,
							// and append a continuation which goes back to our thread
							// and resolves the returned promise.
							localPromise = new P;
							entry.ownerThread.runAsync({
								entry.realPromise.then((P.ValueTuple value) {
									entry.resolved = true;
									localThread.runAsync({
										localPromise.fulfill(value);
									});
								}, (error) {
									entry.resolved = true;
									localThread.runAsync({
										localPromise.reject(error);
									});
								});
							});
						}
					}
				});
			return localPromise;
		}
	}
	else
		static assert(false, "Not a function: " ~ __traits(identifier, fun));
}

unittest
{
	Promise!void funImpl() { return resolve(); }
	alias fun = globallyMemoized!funImpl;
}
