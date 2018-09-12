/**
 * Compiler capability detection
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.meta.caps;

/// Does this compiler support __traits(child) ?
/// https://github.com/D-Programming-Language/dmd/pull/3329
enum haveChildTrait = is(typeof({ struct S { int i; } S s; __traits(child, s, S.i) = 0; }));

// ************************************************************************

struct TestFieldAliasBinding
{
	static template T(alias a)
	{
		void foo()() { a = 0; }
	}

	struct S(alias T)
	{
		int f;
		alias t = T!f;
	}

	static void test()()
	{
		S!T s;
		s.t.foo();
	}
}

/// Does this compiler support binding field context via alias parameters?
/// https://github.com/D-Programming-Language/dmd/pull/2794
/// Added   in 2.065.0: https://github.com/D-Programming-Language/dmd/pull/2794
/// Removed in 2.066.1: https://github.com/D-Programming-Language/dmd/pull/3884
enum haveFieldAliasBinding = __traits(compiles, TestFieldAliasBinding.test());

// ************************************************************************

struct TestMethodAliasBinding
{
	static template T(alias a)
	{
		void foo()() { a(); }
	}

	struct S(alias T)
	{
		void m() { }
		alias t = T!m;
	}

	static void test()()
	{
		S!T s;
		s.t.foo();
	}
}

/// Does this compiler support binding method context via alias parameters?
/// https://github.com/D-Programming-Language/dmd/pull/3345
enum haveMethodAliasBinding = __traits(compiles, TestMethodAliasBinding.test());

// ************************************************************************

struct TestAliasCtxInference
{
	struct A
	{
		void fun() {}

		void caller(T)(T t)
		{
			t.callee();
		}
	}

	struct B
	{
		alias callee = A.fun;
	}

	static void test()()
	{
		A a;
		B b;
		a.caller(b);
	}
}

/// Does this compiler support inferring "this" of an aliased
/// method call from the current context?
/// https://github.com/D-Programming-Language/dmd/pull/3361
enum haveAliasCtxInference = __traits(compiles, TestAliasCtxInference.test());

// ************************************************************************

struct TestAliasStructBinding
{
	struct S(alias fun)
	{
		void call(T)(T t)
		{
			fun(t);
		}
	}

	static void test()()
	{
		int n;

		// Hmm, why doesn't this work?
		//void fun(T)(T x) { n += x; }
		//S!fun s;

		S!(x => n+=x) s;
		s.call(42);
	}
}

/// Does this compiler support binding lambdas via struct template alias parameters?
/// https://github.com/dlang/dmd/pull/5518
enum haveAliasStructBinding = __traits(compiles, TestAliasStructBinding.test());
