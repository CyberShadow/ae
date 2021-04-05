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

import ae.net.asockets;

private enum PromiseState
{
	pending,
	fulfilled,
	rejected,
}

private struct PromiseHandler
{
	void delegate() dg;
	bool onFulfill, onReject;
}

/**
   A promise for a value `T` or error `E`.

   Attempts to implement the Promises/A+ spec
   (https://promisesaplus.com/),
   with the following deviations:

   - Sections 2.2.1.1-2, 2.2.7.3-4: Due to D strong typing, the only
     applicable interpretation of "not a function" is `null`.

   - Section 2.3.3.3.3: Attempts to fulfill or reject a non-pending
     promise cause an assertion failure instead of being silently
     ignored.

   - Section 2.2.5: JavaScript-specific, and does not apply to D.
*/
final class Promise(T, E = Exception)
{
private:
	/// Box of `T`, if it's not `void`, otherwise empty `struct`.
	struct B
	{
		static if (!is(T == void))
			T value;
	}

	/// Either `(T)` or an empty tuple.
	alias A = typeof(B.tupleof);

	/// Box a `T` rvalue. Expand to `A` with `.tupleof`.
	B box(scope lazy T expr)
	{
		static if (is(T == void))
		{
			expr;
			return B.init;
		}
		else
			return B(expr);
	}

	PromiseState state;

	union
	{
		B value;
		E error;
	}

	PromiseHandler[] handlers;

	static void substituteNullHandler(R, Args...)(ref R delegate(Args) dg)
	{
		if (dg)
			return;
		static if (is(R == void))
			dg = toDelegate((Args args) {});
		else
			assert(false, "Non-void handlers may not be null");
	}

public:
	void fulfill(A value)
	{
		assert(this.state == PromiseState.pending,
			"This promise has already been fulfilled or rejected.");
		this.state = PromiseState.fulfilled;
		this.value.tupleof = value;
		foreach (ref handler; handlers)
			if (handler.onFulfill)
				handler.dg();
	}

	void reject(E e)
	{
		assert(this.state == PromiseState.pending,
			"This promise has already been fulfilled or rejected.");
		this.state = PromiseState.rejected;
		this.error = e;
		foreach (ref handler; handlers)
			if (handler.onReject)
				handler.dg();
	}

	Promise!R then(R)(R delegate(A) onFulfilled)
	{
		substituteNullHandler(onFulfilled);

		auto next = new Promise!R;

		void handler()
		{
			assert(this.state == PromiseState.fulfilled);
			next.fulfill(next.box(onFulfilled(this.value.tupleof)).tupleof);
		}

		final switch (this.state)
		{
			case PromiseState.pending:
				handlers ~= PromiseHandler(&handler, true, false);
				break;
			case PromiseState.fulfilled:
				callSoon(&handler);
				break;
			case PromiseState.rejected:
				next.reject(this.error);
				break;
		}
		return next;
	}

	Promise!R then(R)(R delegate(A) onFulfilled, R delegate(E) onRejected)
	{
		substituteNullHandler(onFulfilled);
		substituteNullHandler(onRejected);

		auto next = new Promise!R;

		void handler()
		{
			final switch (this.state)
			{
				case PromiseState.pending:
					assert(false);
				case PromiseState.fulfilled:
				{
					auto b = next.box(onFulfilled(this.value.tupleof));
					return next.fulfill(b.tupleof);
				}
				case PromiseState.rejected:
				{
					auto b = next.box(onRejected(this.error));
					return next.fulfill(b.tupleof);
				}
			}
		}

		final switch (this.state)
		{
			case PromiseState.pending:
				handlers ~= PromiseHandler(&handler, true, true);
				break;
			case PromiseState.fulfilled:
			case PromiseState.rejected:
				callSoon(&handler);
				break;
		}
		return next;
	}

	Promise!R except(R)(R delegate(E) onRejected)
	{
		substituteNullHandler(onRejected);

		auto next = new Promise!R;

		void handler()
		{
			assert(this.state == PromiseState.rejected);
			next.fulfill(next.box(onRejected(this.error)).tupleof);
		}

		final switch (this.state)
		{
			case PromiseState.pending:
				handlers ~= PromiseHandler(&handler, false, true);
				break;
			case PromiseState.fulfilled:
				callSoon(&handler);
				break;
			case PromiseState.rejected:
				next.reject(this.error);
				break;
		}

		return next;
	}
}

private void callSoon(void delegate() dg) { socketManager.onNextTick(dg); }

unittest
{
	if (false)
	{
		Promise!int test;
		test.then((int i) {});
		test.then((int i) {}, (Exception e) {});

		Promise!void test2;
		test2.then({});
	}
}
