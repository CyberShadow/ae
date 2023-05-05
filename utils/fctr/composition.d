/**
 * Functor composition.
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

module ae.utils.fctr.composition;

import ae.utils.fctr.primitives;

import core.lifetime;

import std.meta : allSatisfy;
import std.traits : isCallable;

/// Check if `f` is a functor, and can participate in functor composition.
// Work around https://issues.dlang.org/show_bug.cgi?id=20246
// (We assume opCall is always a function or function template.)
enum isFunctor(alias f) = isCallable!f || __traits(hasMember, f, "opCall");

unittest
{
	static assert(isFunctor!(typeof(() => 5)));
	int i;
	static assert(isFunctor!(typeof(() => i)));
	auto getFive = fctr!(() => 5)();
	static assert(isFunctor!getFive);
}

/// The ternary operation using functors.
auto select(Cond, T, F)(Cond cond, T t, F f) @nogc
if (isFunctor!Cond && isFunctor!T && isFunctor!F)
{
	static auto fun(Args...)(Cond cond, T t, F f, auto ref Args args)
	{
		return cond()
			? t(forward!args)
			: f(forward!args);
	}
	return fctr!fun(cond, t, f);
}

auto select(T, F)(bool cond, T t, F f) @nogc
if (isFunctor!T && isFunctor!F)
{ return select(cond.valFctr, t, f); } /// ditto

///
unittest
{
	assert(select(true , 5.valFctr, 7.valFctr)() == 5);
	assert(select(false, 5.valFctr, 7.valFctr)() == 7);
}

/// The chain operation using functors.
/// Calls all functors in sequence, returns `void`.
/// (Not to be confused with function composition.)
auto seq(Fctrs...)(Fctrs fctrs) @nogc
if (allSatisfy!(isFunctor, Fctrs))
{
	static void fun(Args...)(ref Fctrs fctrs, auto ref Args args)
	{
		/*static*/ foreach (ref fctr; fctrs)
			fctr(args);
	}
	return fctr!fun(fctrs);
}

///
unittest
{
	auto addFive = fctr!(p => *p += 5)();
	auto addThree = fctr!(p => *p += 3)();
	auto addEight = seq(addFive, addThree);
	int i;
	addEight(&i);
	assert(i == 8);
}
