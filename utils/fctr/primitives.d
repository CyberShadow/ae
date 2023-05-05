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

/// Constructs a functor with statically-defined behavior (using the a
/// static lambda), with optional state.
auto fctr(alias fun, State...)(State state)
{
	struct Pred
	{
		State state;

		private this(State state) { this.state = state; }

		auto opCall(this This, Args...)(auto ref Args args)
		{
			return fun(state, args);
		}
	}

	return Pred(state);
}

///
@nogc unittest
{
	// auto getFive = fctr!(() => 5)();
	// assert(getFive() == 5);

	auto getValue = fctr!(n => n)(5);
	assert(getValue() == 5);

	auto addValue = fctr!((n, i) => n + i)(2);
	assert(addValue(5) == 7);
}
