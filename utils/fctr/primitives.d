/**
 * Functor primitives.
 *
 * Functors are objects which are callable. Unlike function pointers
 * or delegates, functors may embed state, and don't need a context
 * pointer.
 *
 * Function pointers and delegates are functors.
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

module ae.utils.fctr.primitives;

import core.lifetime;

/// Constructs a functor with statically-defined behavior (using the a
/// static lambda), with optional state.
auto fctr(alias fun, State...)(State state)
{
	struct Pred
	{
		State state;

		static if (state.length)
			private this(State state)
			{
				static foreach (i; 0 .. state.length)
					moveEmplace(state[i], this.state[i]);
			}

		auto opCall(this This, Args...)(auto ref Args args)
		{
			return fun(state, args);
		}
	}

	static if (state.length)
		return Pred(forward!state);
	else
		return Pred.init;
}

///
@nogc unittest
{
	auto getFive = fctr!(() => 5)();
	assert(getFive() == 5);

	auto getValue = fctr!(n => n)(5);
	assert(getValue() == 5);

	auto addValue = fctr!((n, i) => n + i)(2);
	assert(addValue(5) == 7);
}

unittest
{
	struct NC
	{
		@disable this();
		@disable this(this);
		int i;
		this(int i) { this.i = i; }
	}

	auto f = fctr!((ref a, ref b) => a.i + b.i)(NC(2), NC(3));
	assert(f() == 5);
}