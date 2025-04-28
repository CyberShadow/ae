/**
 * std.algorithm-like functions which accept functors as predicates.
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

module ae.utils.functor.algorithm;

import std.range.primitives : isInputRange;
import std.traits : Unqual;

import std.range; // array range primitives

import ae.utils.functor.primitives;

/// `std.algorithm.map` variant which accepts a functor predicate.
auto map(Range, P)(Range r, P pred)
if (isInputRange!(Unqual!Range))
{
	return PMapResult!(Range, P)(r, pred);
}

private struct PMapResult(R, P)
{
	bool empty() { return r.empty; }
	auto front() { return pred(r.front); }
	static if (__traits(hasMember, R, "back"))
		auto back() { return pred(r.back); }
	void popFront() { r.popFront; }

private:
	R r;
	P pred;
}

///
debug(ae_unittest) @nogc unittest
{
	import std.algorithm.comparison : equal;
	import std.range : iota, only;
	import std.typecons : tuple;

	// Simple map. Delegates are functors too!
	assert(5.iota.map((int n) => n + 1).equal(only(1, 2, 3, 4, 5)));

	// Now with an explicit functor object (no indirect call):
	assert(5.iota.map(functor!((int n) => n + 1)).equal(only(1, 2, 3, 4, 5)));

	// With state (in @nogc !!!)
	int addend = 1;
	assert(5.iota.map(functor!((addend, n) => n + addend)(addend)).equal(only(1, 2, 3, 4, 5)));

	// Aggregate state with tuples:
	auto p = functor!((state, n) => (n + state.addend) * state.factor)(
		tuple!("addend", "factor")(1, 2)
	);
	assert(5.iota.map(p).equal(only(2, 4, 6, 8, 10)));

	// ... or just pass multiple parameters:
	auto q = functor!((addend, factor, n) => (n + addend) * factor)(1, 2);
	assert(5.iota.map(q).equal(only(2, 4, 6, 8, 10)));
}

/// `std.algorithm.filter` variant which accepts a functor predicate.
auto filter(Range, P)(Range r, P pred)
if (isInputRange!(Unqual!Range))
{
	return PFilterResult!(Range, P)(r, pred);
}

private struct PFilterResult(R, P)
{
	bool empty() { return r.empty; }
	auto front() { return r.front; }
	void popFront() { r.popFront(); advance(); }

	this(R r, P pred)
	{
		this.r = r;
		this.pred = pred;
		advance();
	}

private:
	R r;
	P pred;

	void advance()
	{
		while (!r.empty && !pred(r.front))
			r.popFront();
	}
}

///
debug(ae_unittest) @nogc unittest
{
	import std.algorithm.comparison : equal;
	import std.range : iota, only;

	assert(5.iota.filter((int n) => n % 2 == 0).equal(only(0, 2, 4)));
}

/// `std.algorithm.iteration.fold` variant which accepts a functor predicate.
auto fold(Range, P, S)(Range r, scope P functorOp, S seed)
	// if (isInputRange!(Unqual!Range) &&
	// 	is(typeof(functorOp(S.init, ElementType!Range.init)) : S))
{
	auto acc = seed;
	while (!r.empty)
	{
		acc = functorOp(acc, r.front);
		r.popFront();
	}
	return acc;
}

/// ditto
auto fold(Range, P)(Range r, scope P functorOp)
	// if (isInputRange!(Unqual!Range) &&
	// 	is(typeof(functorOp(ElementType!Range.init, ElementType!Range.init)) : ElementType!Range))
{
	import std.exception : enforce;

	enforce(!r.empty, "Cannot fold an empty range without a seed");

	ElementType!Range acc = r.front;
	r.popFront();

	while (!r.empty)
	{
		acc = functorOp(acc, r.front);
		r.popFront();
	}
	return acc;
}

///
debug(ae_unittest) @nogc unittest
{
	import std.conv : to;
	import std.range : iota, only;
	import std.typecons : tuple;

	// Fold with seed (sum)
	assert(5.iota.fold((int acc, int n) => acc + n, 0) == 10); // 0+0+1+2+3+4
	assert(5.iota.fold(functor!((int acc, int n) => acc + n), 100) == 110);

	// Fold with state
	int threshold = 2;
	auto counter = functor!((state, acc, n) => acc + (n > state.threshold ? 1 : 0))(
		tuple!"threshold"(threshold)
	);
	assert(5.iota.fold(counter, 0) == 2); // Count elements > 2 in [0, 1, 2, 3, 4] -> (3, 4)

	// Another stateful example: product with multiplier from state
	int multiplier = 2;
	auto productFunctor = functor!((state, acc, n) => acc * (n + state.multiplier))(
		tuple!"multiplier"(multiplier)
	);
	// Range [1, 2, 3] -> (1+2)=3, (2+2)=4, (3+2)=5
	// Seed = 1: 1 * 3 * 4 * 5 = 60
	assert(iota(1, 4).fold(productFunctor, 1) == 60);

	// Edge case: empty range with seed
	int[] emptyInts;
	assert(emptyInts.fold((int acc, int n) => acc + n, 42) == 42);
	assert(emptyInts.fold(functor!((int acc, int n) => acc + n), 42) == 42);

	// Edge case: single element range with seed
	assert(only(5).fold((int acc, int n) => acc + n, 10) == 15);
	assert(only(5).fold(functor!((int acc, int n) => acc + n), 10) == 15);

	// Test with tuple state (alternative syntax)
	auto productFunctor2 = functor!((multiplier, acc, n) => acc * (n + multiplier))(2);
	assert(iota(1, 4).fold(productFunctor2, 1) == 60);
}

///
debug(ae_unittest) unittest
{
	import std.conv : to; // For string test
	import std.exception : assertThrown;
	import std.range : iota, only;
	import std.typecons : tuple;

	// Fold without seed (sum)
	assert(iota(1, 5).fold((int acc, int n) => acc + n) == 10); // 1+2+3+4
	assert(iota(1, 5).fold(functor!((int acc, int n) => acc + n)) == 10);

	// Fold with different types (string concatenation)
	string[] words = ["hello", " ", "world", "!"];
	assert(words.fold((string acc, string s) => acc ~ s, "") == "hello world!");
	assert(words.fold(functor!((string acc, string s) => acc ~ s), "") == "hello world!");

	// Fold without seed (string concatenation)
	string[] words2 = ["hello", " ", "world", "!"]; // Need separate array as fold consumes
	assert(words2.fold((string acc, string s) => acc ~ s) == "hello world!");

	int[] emptyInts;
	assertThrown(emptyInts.fold((int acc, int n) => acc + n));

	// Edge case: single element range without seed
	assert(only(5).fold((int acc, int n) => acc + n) == 5);
	assert(only(5).fold(functor!((int acc, int n) => acc + n)) == 5);
}
