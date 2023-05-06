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

module ae.utils.functor.composition;

import ae.utils.functor.primitives;

import core.lifetime;

import std.meta : allSatisfy;
import std.traits : isCallable;

/// Check if `f` is a functor, and can participate in functor composition.
// Work around https://issues.dlang.org/show_bug.cgi?id=20246
// (We assume opCall is always a function or function template.)
enum isFunctor(f...) = f.length == 1 && (
	isCallable!f || __traits(hasMember, f, "opCall")
);

unittest
{
	static assert(isFunctor!(typeof(() => 5)));
	int i;
	static assert(isFunctor!(typeof(() => i)));
	auto getFive = functor!(() => 5)();
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
	return functor!fun(cond, t, f);
}

auto select(T, F)(bool cond, T t, F f) @nogc
if (isFunctor!T && isFunctor!F)
{ return select(cond.valueFunctor, t, f); } /// ditto

///
unittest
{
	assert(select(true , 5.valueFunctor, 7.valueFunctor)() == 5);
	assert(select(false, 5.valueFunctor, 7.valueFunctor)() == 7);
}

/// The chain operation using functors.
/// Calls all functors in sequence, returns `void`.
/// (Not to be confused with function composition.)
auto seq(Functors...)(Functors functors) @nogc
if (allSatisfy!(isFunctor, Functors))
{
	static void fun(Args...)(ref Functors functors, auto ref Args args)
	{
		/*static*/ foreach (ref functor; functors)
			functor(args);
	}
	return functor!fun(functors);
}

///
unittest
{
	auto addFive = functor!(p => *p += 5)();
	auto addThree = functor!(p => *p += 3)();
	auto addEight = seq(addFive, addThree);
	int i;
	addEight(&i);
	assert(i == 8);
}
