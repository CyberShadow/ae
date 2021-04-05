/**
 * An implementation of promises.
 * Work in progress.
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

	/// Either `(T)` or an empty tuple.
	alias A = typeof(Box.tupleof);

	PromiseState state;
	debug (ae_promise) bool resultUsed;

	union
	{
		Box value;
		E error;
	}

	PromiseHandler[] handlers;

	void doFulfill(A value) nothrow
	{
		this.state = PromiseState.fulfilled;
		this.value.tupleof = value;
		foreach (ref handler; handlers)
			if (handler.onFulfill)
				handler.dg();
		handlers = null;
	}

	void doReject(E e) nothrow
	{
		this.state = PromiseState.rejected;
		this.error = e;
		foreach (ref handler; handlers)
			if (handler.onReject)
				handler.dg();
		handlers = null;
	}

	/// Implements the [[Resolve]](promise, x) resolution procedure.
	void resolve(scope lazy T valueExpr) /* nothrow */
	{
		Box box;
		static if (is(T == void))
			valueExpr;
		else
			box.value = valueExpr;

		fulfill(box.tupleof);
	}

	/// ditto
	void resolve(Promise!(T, E) x) nothrow
	{
		assert(x !is this, "Attempting to resolve a promise with itself");
		assert(this.state == PromiseState.pending);
		this.state = PromiseState.following;
		x.then(&resolveFulfill, &resolveReject);
	}

	void resolveFulfill(A value) nothrow
	{
		assert(this.state == PromiseState.following);
		doFulfill(value);
	}

	void resolveReject(E e) nothrow
	{
		assert(this.state == PromiseState.following);
		doReject(e);
	}

	debug (ae_promise)
	~this() @nogc
	{
		if (state == PromiseState.pending || state == PromiseState.following || resultUsed)
			return;
		static if (is(T == void))
			if (state == PromiseState.fulfilled)
				return;
		// Throwing anything here or doing anything else non-@nogc
		// will just cause an `InvalidMemoryOperationError`, so
		// `printf` is our best compromise.  Even if we could throw,
		// the stack trace would not be useful due to the
		// nondeterministic nature of the GC.
		import core.stdc.stdio : fprintf, stderr;
		fprintf(stderr, "Leaked %s %s\n",
			state == PromiseState.fulfilled ? "fulfilled".ptr : "rejected".ptr,
			typeof(this).stringof.ptr);
	}

public:
	/// Fulfill this promise, with the given value (if applicable).
	void fulfill(A value) nothrow
	{
		assert(this.state == PromiseState.pending,
			"This promise is already fulfilled, rejected, or following another promise.");
		doFulfill(value);
	}

	/// Reject this promise, with the given exception.
	void reject(E e) nothrow
	{
		assert(this.state == PromiseState.pending,
			"This promise is already fulfilled, rejected, or following another promise.");
		doReject(e);
	}

	/// Registers the specified fulfillment and rejection handlers.
	/// If the promise is already resolved, they are called
	/// as soon as possible (but not immediately).
	Promise!(Unpromise!R, F) then(R, F = E)(R delegate(A) onFulfilled, R delegate(E) onRejected = null) nothrow
	{
		static if (!is(T : R))
			assert(onFulfilled, "Cannot implicitly propagate " ~ T.stringof ~ " to " ~ R.stringof ~ " due to null onFulfilled");

		auto next = new typeof(return);

		void fulfillHandler() nothrow
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

		void rejectHandler() nothrow
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

		debug (ae_promise) resultUsed = true;
		return next;
	}

	/// Special overload of `then` with no `onFulfilled` function.
	/// In this scenario, `onRejected` can act as a filter,
	/// converting errors into values for the next promise in the chain.
	Promise!(CommonType!(Unpromise!R, T), F) then(R, F = E)(typeof(null) onFulfilled, R delegate(E) onRejected) nothrow
	{
		// The returned promise will be fulfilled with either
		// `this.value` (if `this` is fulfilled), or the return value
		// of `onRejected` (if `this` is rejected).
		alias C = CommonType!(Unpromise!R, T);

		auto next = new typeof(return);

		void fulfillHandler() nothrow
		{
			assert(this.state == PromiseState.fulfilled);
			static if (is(C == void))
				next.fulfill();
			else
				next.fulfill(this.value.tupleof);
		}

		void rejectHandler() nothrow
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

		debug (ae_promise) resultUsed = true;
		return next;
	}

	/// Registers a rejection handler.
	/// Equivalent to `then(null, onRejected)`.
	/// Similar to the `catch` method in JavaScript promises.
	Promise!(R, F) except(R, F = E)(R delegate(E) onRejected)
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

		void handler() nothrow
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

		debug (ae_promise) resultUsed = true;
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

private struct PromiseHandler
{
	void delegate() nothrow dg;
	bool onFulfill, onReject;
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
unittest
{
	if (false)
	{
		Promise!int test;
		test.then((int i) {});
		test.then((int i) {}, (Exception e) {});
		test.then(null, (Exception e) {});
		test.except((Exception e) {});
		test.finish({});

		Promise!void test2;
		test2.then({});
	}
}
