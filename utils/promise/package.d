/**
 * An implementation of promises.
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

module ae.utils.promise;

import std.functional;
import std.meta : allSatisfy, AliasSeq, staticMap;
import std.traits : CommonType;

import ae.net.asockets : socketManager, onNextTick;

debug (no_ae_promise) {} else debug debug = ae_promise;

/**
   A promise for a value `T` or error `E`.

   Attempts to implement the Promises/A+ spec
   (https://promisesaplus.com/),
   with the following deviations:

   - Sections 2.2.1.1-2, 2.2.7.3-4: Due to D strong typing, the only
     applicable interpretation of "not a function" is `null`.

   - Section 2.2.5: JavaScript-specific, and does not apply to D.

   - Section 2.2.7.2: In D, thrown objects may only be descendants of
     `Throwable`. By default, `Exception` objects are caught, and
     passed to `onRejected` handlers.

   - Section 2.2.7.1/3: In the case when `onFulfilled` is `null` but
     `onRejected` is not, the returned promise may be resolved with
     either the fulfilled value of the current promise or the return
     value of `onRejected`. In this case, the type of the returned
     promise value is the D common type of the two, or `void` if none.

   - Section 2.3.1: Instead of rejecting the promise with a TypeError,
     an assertion failure is thrown.

   - Section 2.3.3: Not implemented. This section facilitates
     interoperability with other implementations of JavaScript
     promises, though it could be implemented in D using DbI to
     support arbitrary then-able objects.

   Additionally, this implementation differs from typical JavaScript
   implementations as follows:

   - `T` may be `void`. In this case, `fulfill`, and the delegate in
     first argument of `then`, take zero arguments instead of one.

   - Instead of the constructor accepting a function which accepts the
     `fulfill` / `reject` functions, these functions are available as
     regular methods.

   - Attempts to fulfill or reject a non-pending promise cause an
     assertion failure instead of being silently ignored.
     (The Promises/A+ standard touches on this in section 2.3.3.3.3.)

   - `catch` is called `except` (because the former is a reserved D
     keyword).

   - `finally` is called `finish` (because the former is a reserved D
     keyword).

   - In debug builds, resolved `Promise` instances check on
     destruction that their value / error was passed on to a handler
     (unless they have been successfully fulfilled to a `void` value).
     Such leaks are reported to the standard error stream.
*/
final class Promise(T, E : Throwable = Exception)
{
private:
	/// Box of `T`, if it's not `void`, otherwise empty `struct`.
	struct Box
	{
		static if (!is(T == void))
			T value;
	}

	alias A = typeof(Box.tupleof);

	PromiseState state;

	union
	{
		Box value;
		E error;
	}

	PromiseHandler[] handlers;

	enum isNoThrow = is(typeof(delegate void(void delegate() fun) nothrow { try fun(); catch (E) {} }));

	private struct PromiseHandler
	{
		static if (isNoThrow)
			void delegate() nothrow dg;
		else
			void delegate() dg;
		bool onFulfill, onReject;
	}

	void doFulfill(A value) /*nothrow*/
	{
		this.state = PromiseState.fulfilled;
		this.value.tupleof = value;
		static if (!is(T == void))
			debug (ae_promise) markAsUnused();
		foreach (ref handler; handlers)
			if (handler.onFulfill)
				handler.dg();
		handlers = null;
	}

	void doReject(E e) /*nothrow*/
	{
		this.state = PromiseState.rejected;
		this.error = e;
		debug (ae_promise) markAsUnused();
		foreach (ref handler; handlers)
			if (handler.onReject)
				handler.dg();
		handlers = null;
	}

	/// Implements the [[Resolve]](promise, x) resolution procedure.
	void resolve(scope lazy T valueExpr) /*nothrow*/
	{
		Box box;
		static if (is(T == void))
			valueExpr;
		else
			box.value = valueExpr;

		fulfill(box.tupleof);
	}

	/// ditto
	void resolve(Promise!(T, E) x) /*nothrow*/
	{
		assert(x !is this, "Attempting to resolve a promise with itself");
		assert(this.state == PromiseState.pending);
		this.state = PromiseState.following;
		x.then(&resolveFulfill, &resolveReject);
	}

	void resolveFulfill(A value) /*nothrow*/
	{
		assert(this.state == PromiseState.following);
		doFulfill(value);
	}

	void resolveReject(E e) /*nothrow*/
	{
		assert(this.state == PromiseState.following);
		doReject(e);
	}

	// This debug machinery tracks leaked promises, i.e. promises
	// which have been fulfilled/rejected, but their result was never
	// used (their .then method was never called).
	debug (ae_promise)
	{
		// Global doubly linked list of promises with unused results
		static typeof(this) unusedHead, unusedTail;
		typeof(this) unusedPrev, unusedNext;
		bool isUnused() { return unusedPrev || (unusedHead is this); }

		LeakedPromiseError leakedPromiseError;
		bool resultUsed;

		void markAsUnused()
		{
			if (resultUsed)
				return; // An earlier `then` call has priority
			assert(!isUnused);
			if (unusedTail)
			{
				unusedPrev = unusedTail;
				unusedTail.unusedNext = this;
			}
			unusedTail = this;
			if (!unusedHead)
				unusedHead = this;
		}

		void markAsUsed()
		{
			if (resultUsed)
				return;
			resultUsed = true;
			if (isUnused)
			{
				if (unusedPrev) unusedPrev.unusedNext = unusedNext; else unusedHead = unusedNext;
				if (unusedNext) unusedNext.unusedPrev = unusedPrev; else unusedTail = unusedPrev;
			}
		}

		static ~this()
		{
			for (auto p = unusedHead; p; p = p.unusedNext)
			{
				// If these asserts fail, there is a bug in our debug machinery
				assert(p.state != PromiseState.pending && p.state != PromiseState.following && !p.resultUsed);
				static if (is(T == void))
					assert(p.state != PromiseState.fulfilled);

				import core.stdc.stdio : fprintf, stderr;
				fprintf(stderr, "Leaked %s %s\n",
					p.state == PromiseState.fulfilled ? "fulfilled".ptr : "rejected".ptr,
					typeof(this).stringof.ptr);
				if (p.state == PromiseState.rejected)
					_d_print_throwable(p.error);
				_d_print_throwable(p.leakedPromiseError);
			}
		}
	}

public:
	debug (ae_promise)
	this() nothrow
	{
		// Record instantiation point
		try
			throw new LeakedPromiseError();
		catch (LeakedPromiseError e)
			leakedPromiseError = e;
		catch (Throwable) {} // allow nothrow
	}

	/// A tuple of this `Promise`'s value.
	/// Either `(T)` or an empty tuple.
	alias ValueTuple = A;

	/// Work-around for DMD bug 21804:
	/// https://issues.dlang.org/show_bug.cgi?id=21804
	/// If your `then` callback argument is a tuple,
	/// insert this call before the `then` call.
	/// (Needs to be done only once per `Promise!T` instance.)
	typeof(this) dmd21804workaround()
	{
		static if (!is(T == void))
			if (false)
				then((A result) {});
		return this;
	}

	/// Ignore this promise leaking in debug builds.
	void ignoreResult()
	{
		debug (ae_promise) markAsUsed();
	}

	/// Fulfill this promise, with the given value (if applicable).
	void fulfill(A value) /*nothrow*/
	{
		assert(this.state == PromiseState.pending,
			"This promise is already fulfilled, rejected, or following another promise.");
		doFulfill(value);
	}

	/// Reject this promise, with the given exception.
	void reject(E e) /*nothrow*/
	{
		assert(this.state == PromiseState.pending,
			"This promise is already fulfilled, rejected, or following another promise.");
		doReject(e);
	}

	/// Registers the specified fulfillment and rejection handlers.
	/// If the promise is already resolved, they are called
	/// as soon as possible (but not immediately).
	Promise!(Unpromise!R, F) then(R, F = E)(R delegate(A) onFulfilled, R delegate(E) onRejected = null) /*nothrow*/
	{
		static if (!is(T : R))
			assert(onFulfilled, "Cannot implicitly propagate " ~ T.stringof ~ " to " ~ R.stringof ~ " due to null onFulfilled");

		auto next = new typeof(return);

		void fulfillHandler() /*nothrow*/
		{
			assert(this.state == PromiseState.fulfilled);
			if (onFulfilled)
			{
				try
					next.resolve(onFulfilled(this.value.tupleof));
				catch (F e)
					next.reject(e);
			}
			else
			{
				static if (is(R == void))
					next.fulfill();
				else
				{
					static if (!is(T : R))
						assert(false); // verified above
					else
						next.fulfill(this.value.tupleof);
				}
			}
		}

		void rejectHandler() /*nothrow*/
		{
			assert(this.state == PromiseState.rejected);
			if (onRejected)
			{
				try
					next.resolve(onRejected(this.error));
				catch (F e)
					next.reject(e);
			}
			else
				next.reject(this.error);
		}

		final switch (this.state)
		{
			case PromiseState.pending:
			case PromiseState.following:
				handlers ~= PromiseHandler({ callSoon(&fulfillHandler); }, true, false);
				handlers ~= PromiseHandler({ callSoon(&rejectHandler); }, false, true);
				break;
			case PromiseState.fulfilled:
				callSoon(&fulfillHandler);
				break;
			case PromiseState.rejected:
				callSoon(&rejectHandler);
				break;
		}

		debug (ae_promise) markAsUsed();
		return next;
	}

	/// Special overload of `then` with no `onFulfilled` function.
	/// In this scenario, `onRejected` can act as a filter,
	/// converting errors into values for the next promise in the chain.
	Promise!(CommonType!(Unpromise!R, T), F) then(R, F = E)(typeof(null) onFulfilled, R delegate(E) onRejected) /*nothrow*/
	{
		// The returned promise will be fulfilled with either
		// `this.value` (if `this` is fulfilled), or the return value
		// of `onRejected` (if `this` is rejected).
		alias C = CommonType!(Unpromise!R, T);

		auto next = new typeof(return);

		void fulfillHandler() /*nothrow*/
		{
			assert(this.state == PromiseState.fulfilled);
			static if (is(C == void))
				next.fulfill();
			else
				next.fulfill(this.value.tupleof);
		}

		void rejectHandler() /*nothrow*/
		{
			assert(this.state == PromiseState.rejected);
			if (onRejected)
			{
				try
					next.resolve(onRejected(this.error));
				catch (F e)
					next.reject(e);
			}
			else
				next.reject(this.error);
		}

		final switch (this.state)
		{
			case PromiseState.pending:
			case PromiseState.following:
				handlers ~= PromiseHandler({ callSoon(&fulfillHandler); }, true, false);
				handlers ~= PromiseHandler({ callSoon(&rejectHandler); }, false, true);
				break;
			case PromiseState.fulfilled:
				callSoon(&fulfillHandler);
				break;
			case PromiseState.rejected:
				callSoon(&rejectHandler);
				break;
		}

		debug (ae_promise) markAsUsed();
		return next;
	}

	/// Registers a rejection handler.
	/// Equivalent to `then(null, onRejected)`.
	/// Similar to the `catch` method in JavaScript promises.
	Promise!(CommonType!(Unpromise!R, T), F) except(R, F = E)(R delegate(E) onRejected)
	{
		return this.then(null, onRejected);
	}

	/// Registers a finalization handler, which is called when the
	/// promise is resolved (either fulfilled or rejected).
	/// Roughly equivalent to `then(value => onResolved(), error => onResolved())`.
	/// Similar to the `finally` method in JavaScript promises.
	Promise!(R, F) finish(R, F = E)(R delegate() onResolved)
	{
		assert(onResolved, "No onResolved delegate specified in .finish");

		auto next = new typeof(return);

		void handler() /*nothrow*/
		{
			assert(this.state == PromiseState.fulfilled || this.state == PromiseState.rejected);
			try
				next.resolve(onResolved());
			catch (F e)
				next.reject(e);
		}

		final switch (this.state)
		{
			case PromiseState.pending:
			case PromiseState.following:
				handlers ~= PromiseHandler({ callSoon(&handler); }, true, true);
				break;
			case PromiseState.fulfilled:
			case PromiseState.rejected:
				callSoon(&handler);
				break;
		}

		debug (ae_promise) markAsUsed();
		return next;
	}
}

// (These declarations are top-level because they don't need to be templated.)

private enum PromiseState
{
	pending,
	following,
	fulfilled,
	rejected,
}

debug (ae_promise)
{
	private final class LeakedPromiseError : Throwable { this() { super("Created here:"); } }
	private extern (C) void _d_print_throwable(Throwable t) @nogc;
}

// The reverse operation is the `.resolve` overload.
private template Unpromise(P)
{
	static if (is(P == Promise!(T, E), T, E))
		alias Unpromise = T;
	else
		alias Unpromise = P;
}

// This is the only non-"pure" part of this implementation.
private void callSoon(void delegate() dg) @safe nothrow { socketManager.onNextTick(dg); }

// This is just a simple instantiation test.
// The full test suite (D translation of the Promises/A+ conformance
// test) is here: https://github.com/CyberShadow/ae-promises-tests
debug(ae_unittest) nothrow unittest
{
	static bool never; if (never)
	{
		Promise!int test;
		test.then((int i) {});
		test.then((int i) {}, (Exception e) {});
		test.then(null, (Exception e) {});
		test.except((Exception e) {});
		test.finish({});
		test.fulfill(1);
		test.reject(Exception.init);

		Promise!void test2;
		test2.then({});
	}
}

// Non-Exception based errors
debug(ae_unittest) unittest
{
	static bool never; if (never)
	{
		static class OtherException : Exception
		{
			this() { super(null); }
		}

		Promise!(int, OtherException) test;
		test.then((int i) {});
		test.then((int i) {}, (OtherException e) {});
		test.then(null, (OtherException e) {});
		test.except((OtherException e) {});
		test.fulfill(1);
		test.reject(OtherException.init);
	}
}

// Test that except() return type matches then(null, onRejected)
// when the handler returns a type with a common type to T.
debug(ae_unittest) unittest
{
	static bool never; if (never)
	{
		// When Promise!long is rejected and handler returns int,
		// the result type should be CommonType!(int, long) = long.
		Promise!long p;
		auto p2 = p.except((Exception e) { return 5; });
		static assert(is(typeof(p2) == Promise!long));

		// Same scenario with then(null, ...) for comparison
		auto p3 = p.then(null, (Exception e) { return 5; });
		static assert(is(typeof(p2) == typeof(p3)));
	}
}

// Following
debug(ae_unittest) unittest
{
    auto p = new Promise!void;
    bool ok;
    p.then({
        return resolve(true);
    }).then((value) {
        ok = value;
    });
    p.fulfill();
    socketManager.loop();
    assert(ok);
}

// ****************************************************************************

/// Returns a new `Promise!void` which is resolved.
Promise!void resolve(E = Exception)() { auto p = new Promise!(void, E)(); p.fulfill(); return p; }

/// Returns a new `Promise` which is resolved with the given value.
Promise!T resolve(T, E = Exception)(T value) { auto p = new Promise!(T, E)(); p.fulfill(value); return p; }

/// Returns a new `Promise` which is rejected with the given reason.
Promise!(T, E) reject(T, E)(E reason) { auto p = new Promise!(T, E)(); p.reject(reason); return p; }

// ****************************************************************************

/// Return `true` if `P` is a `Promise` instantiation.
template isPromise(P)
{
	static if (is(P == Promise!(T, E), T, E))
		enum isPromise = true;
	else
		enum isPromise = false;
}

/// Get the value type of the promise `P`,
/// i.e. its `T` parameter.
template PromiseValue(P)
{
	///
	static if (is(P == Promise!(T, E), T, E))
		alias PromiseValue = T;
	else
		static assert(false);
}

/// Get the error type of the promise `P`,
/// i.e. its `E` parameter.
template PromiseError(P)
{
	///
	static if (is(P == Promise!(T, E), T, E))
		alias PromiseError = E;
	else
		static assert(false);
}

/// Construct a new Promise type based on `P`,
/// if the given transformation was applied on the value type.
/// If `P` is a `void` Promise, then the returned promise
/// will also be `void`.
template PromiseValueTransform(P, alias transform)
if (is(P == Promise!(T, E), T, E))
{
	/// ditto
	static if (is(P == Promise!(T, E), T, E))
	{
		static if (is(T == void))
			private alias T2 = void;
		else
			private alias T2 = typeof({ T* value; return transform(*value); }());
		alias PromiseValueTransform = Promise!(T2, E);
	}
}

// ****************************************************************************

/// Convert any returned value or exception thrown by `task` into
/// the corresponding Promise resolution.
/// Somewhat equivalent to Promise.try in ES2025.
void tryResolve(T, E)(Promise!(T, E) p, scope T delegate() task)
{
	try
		static if (is(T == void))
			task(), p.fulfill();
		else
			p.fulfill(task());
	catch (E e)
		p.reject(e);
}

/// Result of a promise resolution (fulfilled value or rejected error).
struct Result(T, E)
{
	Promise!T.ValueTuple value;
	E error;

	T unwrap()
	{
		if (error)
			throw error;
		else
		{
			static if (!is(T == void))
				return value[0];
		}
	}
}

/// Execute a task and capture the result or thrown exception into a Result.
Result!(T, E) toResult(E = Exception, T)(scope T delegate() task)
{
	Result!(T, E) result;
	try
		static if (is(T == void))
			task();
		else
			result.value[0] = task();
	catch (E e)
		result.error = e;
	return result;
}

/// Capture a promise's resolution (fulfillment or rejection) into a Result.
/// Returns a promise that is fulfilled with the Result when the input promise is resolved.
Promise!(Result!(T, E)) toResult(T, E)(Promise!(T, E) p)
{
	bool isResolved;
	auto resultPromise = new typeof(return);

	p.then((Promise!T.ValueTuple value) {
		assert(!isResolved, "Promise resolved multiple times");
		isResolved = true;
		Result!(T, E) result;
		result.value = value;
		resultPromise.fulfill(result);
	}, (E error) {
		assert(!isResolved, "Promise resolved multiple times");
		isResolved = true;
		Result!(T, E) result;
		result.error = error;
		resultPromise.fulfill(result);
	});

	return resultPromise;
}

/// Deprecated alias for backwards compatibility.
deprecated alias PromiseResult = Result;

/// Deprecated shim for backwards compatibility.
deprecated void capture(T, E)(ref Result!(T, E) result, Promise!(T, E) p, void delegate() onComplete = null)
{
	p.toResult.dmd21804workaround.then((r) { result = r; if (onComplete) onComplete(); });
}

// ****************************************************************************

/// Wait for all promises to be resolved, or for any to be rejected.
PromiseValueTransform!(P, x => [x]) all(P)(P[] promises)
if (is(P == Promise!(T, E), T, E))
{
	alias T = PromiseValue!P;

	auto allPromise = new typeof(return);

	typeof(return).ValueTuple results;
	static if (!is(T == void))
		results[0] = new T[promises.length];

	if (promises.length)
	{
		size_t numResolved;
		foreach (i, p; promises)
			(i, p) {
				p.dmd21804workaround.then((P.ValueTuple result) {
					if (allPromise)
					{
						static if (!is(T == void))
							results[0][i] = result[0];
						if (++numResolved == promises.length)
							allPromise.fulfill(results);
					}
				}, (error) {
					if (allPromise)
					{
						allPromise.reject(error);
						allPromise = null; // ignore successive resolves / rejects
					}
				});
			}(i, p);
	}
	else
		allPromise.fulfill(results);
	return allPromise;
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	int result;
	auto p1 = new Promise!int;
	auto p2 = new Promise!int;
	auto p3 = new Promise!int;
	p2.fulfill(2);
	auto pAll = all([p1, p2, p3]);
	p1.fulfill(1);
	pAll.dmd21804workaround.then((values) { result = values[0] + values[1] + values[2]; });
	p3.fulfill(3);
	socketManager.loop().assertNotThrown;
	assert(result == 6);
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	int called;
	auto p1 = new Promise!void;
	auto p2 = new Promise!void;
	auto p3 = new Promise!void;
	p2.fulfill();
	auto pAll = all([p1, p2, p3]);
	p1.fulfill();
	pAll.then({ called = true; });
	socketManager.loop().assertNotThrown;
	assert(!called);
	p3.fulfill();
	socketManager.loop().assertNotThrown;
	assert(called);
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	Promise!void[] promises;
	auto pAll = all(promises);
	bool called;
	pAll.then({ called = true; });
	socketManager.loop().assertNotThrown;
	assert(called);
}

private template AllResultImpl(size_t promiseIndex, size_t resultIndex, Promises...)
{
	static if (Promises.length == 0)
	{
		alias TupleMembers = AliasSeq!();
		enum size_t[] mapping = [];
	}
	else
	static if (is(PromiseValue!(Promises[0]) == void))
	{
		alias Next = AllResultImpl!(promiseIndex + 1, resultIndex, Promises[1..$]);
		alias TupleMembers = Next.TupleMembers;
		enum size_t[] mapping = [size_t(-1)] ~ Next.mapping;
	}
	else
	{
		alias Next = AllResultImpl!(promiseIndex + 1, resultIndex + 1, Promises[1..$]);
		alias TupleMembers = AliasSeq!(PromiseValue!(Promises[0]), Next.TupleMembers);
		enum size_t[] mapping = [resultIndex] ~ Next.mapping;
	}
}

// Calculates a value type for a Promise suitable to hold the values of the given promises.
// void-valued promises are removed; an empty list is converted to void.
// Also calculates an index map from Promises indices to tuple member indices.
private template AllResult(Promises...)
{
	alias Impl = AllResultImpl!(0, 0, Promises);
	static if (Impl.TupleMembers.length == 0)
		alias ResultType = void;
	else
	{
		import std.typecons : Tuple;
		alias ResultType = Tuple!(Impl.TupleMembers);
	}
}

private alias PromiseBox(P) = P.Box;

/// Heterogeneous variant, which resolves to a tuple.
/// void promises' values are omitted from the result tuple.
/// If all promises are void, then so is the result.
Promise!(AllResult!Promises.ResultType) all(Promises...)(Promises promises)
if (allSatisfy!(isPromise, Promises))
{
	AllResult!Promises.Impl.TupleMembers results;

	auto allPromise = new typeof(return);

	static if (promises.length)
	{
		size_t numResolved;
		foreach (i, p; promises)
		{
			alias P = typeof(p);
			alias T = PromiseValue!P;
			p.dmd21804workaround.then((P.ValueTuple result) {
				if (allPromise)
				{
					static if (!is(T == void))
						results[AllResult!Promises.Impl.mapping[i]] = result[0];
					if (++numResolved == promises.length)
					{
						static if (AllResult!Promises.Impl.TupleMembers.length)
						{
							import std.typecons : tuple;
							allPromise.fulfill(tuple(results));
						}
						else
							allPromise.fulfill();
					}
				}
			}, (error) {
				if (allPromise)
				{
					allPromise.reject(error);
					allPromise = null; // ignore successive resolves / rejects
				}
			});
		}
	}
	else
		allPromise.fulfill();
	return allPromise;
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	import ae.utils.meta : I;

	int result;
	auto p1 = new Promise!byte;
	auto p2 = new Promise!void;
	auto p3 = new Promise!int;
	p2.fulfill();
	auto pAll = all(p1, p2, p3);
	p1.fulfill(1);
	pAll.dmd21804workaround
		.then(values => values.expand.I!((v1, v3) {
			result = v1 + v3;
	}));
	p3.fulfill(3);
	socketManager.loop().assertNotThrown;
	assert(result == 4);
}

debug(ae_unittest) nothrow unittest
{
	bool ok;
	import std.exception : assertNotThrown;
	auto p1 = new Promise!void;
	auto p2 = new Promise!void;
	auto p3 = new Promise!void;
	p2.fulfill();
	auto pAll = all(p1, p2, p3);
	p1.fulfill();
	pAll.then({ ok = true; });
	socketManager.loop().assertNotThrown;
	assert(!ok);
	p3.fulfill();
	socketManager.loop().assertNotThrown;
	assert(ok);
}

// ****************************************************************************

/// Returns a promise that resolves or rejects as soon as any of the input
/// promises resolves or rejects, with the value or error of that promise.
P race(P)(P[] promises)
if (is(P == Promise!(T, E), T, E))
{
	auto racePromise = new P;

	foreach (p; promises)
		p.then((P.ValueTuple result) {
			if (racePromise)
			{
				racePromise.fulfill(result);
				racePromise = null; // ignore successive resolves / rejects
			}
		}, (error) {
			if (racePromise)
			{
				racePromise.reject(error);
				racePromise = null; // ignore successive resolves / rejects
			}
		});

	return racePromise;
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	int result;
	auto p1 = new Promise!int;
	auto p2 = new Promise!int;
	auto p3 = new Promise!int;
	auto pRace = race([p1, p2, p3]);
	p2.fulfill(2);
	pRace.dmd21804workaround.then((value) { result = value; });
	p1.fulfill(1);
	p3.fulfill(3);
	socketManager.loop().assertNotThrown;
	assert(result == 2);
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	int result;
	auto p1 = new Promise!int;
	auto p2 = new Promise!int;
	auto pRace = race([p1, p2]);
	p1.reject(new Exception("error"));
	pRace.then((value) { result = 1; }, (e) { result = 2; });
	socketManager.loop().assertNotThrown;
	assert(result == 2);
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	bool called;
	auto p1 = new Promise!void;
	auto p2 = new Promise!void;
	auto pRace = race([p1, p2]);
	p2.fulfill();
	pRace.then({ called = true; });
	socketManager.loop().assertNotThrown;
	assert(called);
}

// ****************************************************************************

/// Returns a promise that is fulfilled with an array of Results when all
/// input promises have settled (either fulfilled or rejected).
/// Unlike `all`, this never rejects - it collects all outcomes.
Promise!(Result!(PromiseValue!P, PromiseError!P)[]) allSettled(P)(P[] promises)
if (isPromise!P)
{
	alias T = PromiseValue!P;
	alias E = PromiseError!P;

	auto allPromise = new typeof(return);
	auto results = new Result!(T, E)[promises.length];

	if (promises.length)
	{
		size_t numSettled;
		foreach (i, p; promises)
			(i, p) {
				p.toResult.dmd21804workaround.then((result) {
					results[i] = result;
					if (++numSettled == promises.length)
						allPromise.fulfill(results);
				});
			}(i, p);
	}
	else
		allPromise.fulfill(results);

	return allPromise;
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	auto p1 = new Promise!int;
	auto p2 = new Promise!int;
	auto p3 = new Promise!int;
	p2.fulfill(2);
	auto pAll = allSettled([p1, p2, p3]);
	p1.reject(new Exception("error"));
	Result!(int, Exception)[] results;
	pAll.dmd21804workaround.then((r) { results = r; });
	p3.fulfill(3);
	socketManager.loop().assertNotThrown;
	assert(results.length == 3);
	assert(results[0].error !is null);
	assert(results[1].value[0] == 2);
	assert(results[2].value[0] == 3);
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	auto p1 = new Promise!void;
	auto p2 = new Promise!void;
	p1.fulfill();
	p2.reject(new Exception("error"));
	auto pAll = allSettled([p1, p2]);
	Result!(void, Exception)[] results;
	pAll.dmd21804workaround.then((r) { results = r; });
	socketManager.loop().assertNotThrown;
	assert(results.length == 2);
	assert(results[0].error is null);
	assert(results[1].error !is null);
}

debug(ae_unittest) nothrow unittest
{
	import std.exception : assertNotThrown;
	Promise!int[] promises;
	auto pAll = allSettled(promises);
	Result!(int, Exception)[] results;
	pAll.dmd21804workaround.then((r) { results = r; });
	socketManager.loop().assertNotThrown;
	assert(results.length == 0);
}

// ****************************************************************************

Promise!(T, E) require(T, E)(ref Promise!(T, E) p, lazy Promise!(T, E) lp)
{
    if (!p)
        p = lp;
    return p;
}

debug(ae_unittest) unittest
{
    Promise!int p;
    int work;
    Promise!int getPromise()
    {
        return p.require({
            work++;
            return resolve(1);
        }());
    }
    int done;
    getPromise().then((n) { done += 1; });
    getPromise().then((n) { done += 1; });
	socketManager.loop();
    assert(work == 1 && done == 2);
}

/// Ordered promise queue, supporting asynchronous enqueuing / fulfillment.
struct PromiseQueue(T, E = Exception)
{
	private alias P = Promise!(T, E);

	private P[] fulfilled, waiting;

	import ae.utils.array : queuePush, queuePop;

	/// Retrieve the next fulfilled promise, or enqueue a waiting one.
	P waitOne()
	{
		if (fulfilled.length)
			return fulfilled.queuePop();

		auto p = new P;
		waiting.queuePush(p);
		return p;
	}

	/// Fulfill one waiting promise, or enqueue a fulfilled one.
	P fulfillOne(typeof(P.Box.tupleof) value)
	{
		if (waiting.length)
		{
			waiting.queuePop.fulfill(value);
			return null;
		}

		auto p = new P;
		p.fulfill(value);
		fulfilled.queuePush(p);
		return p;
	}
}

debug(ae_unittest) unittest
{
	PromiseQueue!int q;
	q.fulfillOne(1);
	q.fulfillOne(2);
	int[] result;
	q.waitOne().then((i) { result ~= i; });
	q.waitOne().then((i) { result ~= i; });
	socketManager.loop();
	assert(result == [1, 2]);
}

debug(ae_unittest) unittest
{
	PromiseQueue!int q;
	int[] result;
	q.waitOne().then((i) { result ~= i; });
	q.waitOne().then((i) { result ~= i; });
	q.fulfillOne(1);
	q.fulfillOne(2);
	socketManager.loop();
	assert(result == [1, 2]);
}
