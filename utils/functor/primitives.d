/**
 * Functor primitives.
 *
 * Functors are objects which are callable. Unlike function pointers
 * or delegates, functors may embed state, and don't require a context
 * pointer.
 *
 * Function pointers and delegates are functors; their state contains
 * a pointer to the implementation and context.
 *
 * https://forum.dlang.org/post/qnigarkuxxnqwdernhzv@forum.dlang.org
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

module ae.utils.functor.primitives;

import std.functional : forward;

// Avoid https://issues.dlang.org/show_bug.cgi?id=23901, which for
// some reason manifests only with the `std.algorithm.mutation`
// versions of `move` in recent D versions.
static if (is(typeof({ import core.lifetime : move; })))
	import core.lifetime : move;
else
	import std.algorithm.mutation : move;

/// Constructs a functor with statically-defined behavior (using an
/// alias), with optional state.
template functor(alias fun, State...)
{
	struct Functor
	{
		State state;

		// With https://issues.dlang.org/show_bug.cgi?id=9608, we
		// might be able to introspect `fun` and generate accessors
		// for `state` based on `fun`'s parameter names.

		static if (state.length)
			private this(State state)
			{
				static foreach (i; 0 .. state.length)
					static if (is(typeof(move(state[i]))))
						this.state[i] = move(state[i]);
					else
						this.state[i] = state[i];
			}

		auto opCall(this This, Args...)(auto ref Args args)
		{
			static if (args.length)
				return fun(state, forward!args);
			else
				return fun(state);
		}
	}

	auto functor(State state)
	{
		static if (state.length)
			return Functor(forward!state);
		else
			return Functor.init;
	}
}

///
@nogc unittest
{
	auto getFive = functor!(() => 5)();
	assert(getFive() == 5);

	auto getValue = functor!(n => n)(5);
	assert(getValue() == 5);

	// Functor construction is a bit like currying, though mutation of
	// curried arguments (here, state) is explicitly allowed.

	auto addValue = functor!((n, i) => n + i)(2);
	assert(addValue(5) == 7);

	auto accumulator = functor!((ref n, i) => n += i)(0);
	accumulator(2); accumulator(5);
	assert(accumulator.state[0] == 7);
}

@nogc unittest
{
	struct NC
	{
		@disable this();
		@disable this(this);
		int i;
		this(int i) @nogc { this.i = i; }
	}

	auto f = functor!((ref a, ref b) => a.i + b.i)(NC(2), NC(3));
	assert(f() == 5);
}

@nogc unittest
{
	immutable int i = 2;
	auto f = functor!((a, b) => a + b)(i);
	assert(f(3) == 5);
}

/// Constructs a nullary functor which simply returns a value specified at compile-time.
/// Like `() => value`, but without the indirect call.
auto valueFunctor(alias value)() { return .functor!(() => value)(); }

/// Constructs a nullary functor which simply returns a value specified at run-time.
/// Like `() => value`, but without the closure and indirect call.
auto valueFunctor(Value)(Value value) { return functor!(v => v)(value); }

///
@nogc unittest
{
	assert(valueFunctor(5)() == 5);
	assert(valueFunctor!5()() == 5);
}
