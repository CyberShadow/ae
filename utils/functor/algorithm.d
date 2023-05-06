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
@nogc unittest
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
	auto front() { return pred(r.front); }
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
