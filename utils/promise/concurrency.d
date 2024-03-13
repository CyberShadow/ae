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
if (!is(T == return))
{
	return threadAsync({ return value; });
}

/// ditto
Promise!(T, E) threadAsync(T, E = Exception)(T delegate() value)
if (!is(T == return))
{
	auto p = new Promise!T;
	auto mainThread = new ThreadAnchor(No.daemon);
	Thread t;
	t = new Thread({
		try
		{
			auto result = value().voidStruct;
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

/// ditto
Promise!(T, E) threadAsync(T, E = Exception)(T function() value)
if (!is(T == return))
{
	import std.functional : toDelegate;
	return threadAsync(value.toDelegate);
}

version(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	int ok;

	Thread.sleep(1.msecs).threadAsync.then(() { ok++; });
	"foo".threadAsync.dmd21804workaround.then((s) { ok += s == "foo"; });
	(){throw new Exception("yolo");}().threadAsync.then((){}, (e) { ok += e.msg == "yolo"; });

	socketManager.loop();
	assert(ok == 3, [cast(char)('0'+ok)]);
}

// ****************************************************************************

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

version(ae_unittest) unittest
{
	Promise!void funImpl() { return resolve(); }
	alias fun = globallyMemoized!funImpl;
}

// ****************************************************************************

/// Runs tasks asynchronously in an ordered manner.
/// For each `put` call, return a `Promise` which
/// resolves to the given delegate's return value.
/// The `taskFun` is evaluated in a separate thread.
/// Unlike `threadAsync`, at most one task will execute
/// at any given time (per `AsyncQueue` instance),
/// they will be executed in the order of the `put` calls,
/// and the promises will be resolved in the main thread
/// in the same order.
final class AsyncQueue(T, E = Exception)
{
	this()
	{
		// Note: std.concurrency can't support daemon tasks
		anchor = new ThreadAnchor(No.daemon);
		tid = spawn(&threadFunc, thisTid);
	} ///

	Promise!(T, E) put(T delegate() taskFun)
	{
		auto promise = new Promise!(T, E);
		tid.send(cast(immutable)Task(taskFun, promise, anchor));
		return promise;
	} ///

	/// Close the queue. Must be called to free up resources
	/// (thread and message queue).
	void close()
	{
		tid.send(cast(immutable)EOF(anchor));
		anchor = null;
	}

private:
	import std.concurrency : spawn, send, receive, Tid, thisTid;

	ThreadAnchor anchor;
	Tid tid;

	struct Task
	{
		T delegate() fun;
		Promise!(T, E) promise;
		ThreadAnchor anchor;
	}
	struct EOF
	{
		ThreadAnchor anchor;
	}

	static void threadFunc(Tid _)
	{
		bool done;
		while (!done)
		{
			receive(
				(immutable Task immutableTask)
				{
					auto task = cast()immutableTask;
					try
					{
						auto result = task.fun().voidStruct;
						task.anchor.runAsync({
							task.promise.fulfill(result.tupleof);
						});
					}
					catch (E e)
						task.anchor.runAsync({
							task.promise.reject(e);
						});
				},
				(immutable EOF immutableEOF)
				{
					auto eof = cast()immutableEOF;
					eof.anchor.close();
					done = true;
				},
			);
		}
	}
}

version(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	int[] result;
	{
		auto queue = new AsyncQueue!void;
		scope(exit) queue.close();
		auto taskFun(int n) { return () { Thread.sleep(n.msecs); result ~= n; }; }
		queue.put(taskFun(200));
		queue.put(taskFun(100));
	}
	socketManager.loop();
	assert(result == [200, 100]);
}
