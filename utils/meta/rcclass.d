/**
 * Basic reference-counting for classes.
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

module ae.utils.meta.rcclass;

import core.memory;

import std.conv : emplace;

private struct RCClassStore(C)
{
	size_t refCount = void;
	void[__traits(classInstanceSize, C)] data = void;
}

/// Wraps class type `C` into a reference-counting value type.
struct RCClass(C)
if (is(C == class))
{
	// storage

	private RCClassStore!C* _rcClassStore;

	@property C _rcClassGet()
	{
		return cast(C)_rcClassStore.data.ptr;
	}

	alias _rcClassGet this;

	// construction

	this(T)(T value)
	if (is(T == RCClass!U, U) && is(typeof({U u; C c = u;})))
	{
		_rcClassStore = cast(RCClassStore!C*)value._rcClassStore;
		if (_rcClassStore)
			_rcClassStore.refCount++;
	}

	// operations

	ref typeof(this) opAssign(T)(T value)
	if (is(T == typeof(null)))
	{
		_rcClassDestroy();
		_rcClassStore = null;
		return this;
	} ///

	ref typeof(this) opAssign(T)(auto ref T value)
	if (is(T == RCClass!U, U) && is(typeof({U u; C c = u;})))
	{
		_rcClassDestroy();
		_rcClassStore = cast(RCClassStore!C*)value._rcClassStore;
		if (_rcClassStore)
			_rcClassStore.refCount++;
		return this;
	} ///

	T opCast(T)()
	if (is(T == RCClass!U, U) && is(typeof({C c; U u = c;})))
	{
		T result;
		result._rcClassStore = cast(typeof(result._rcClassStore))_rcClassStore;
		if (_rcClassStore)
			_rcClassStore.refCount++;
		return result;
	} ///

	bool opCast(T)()
	if (is(T == bool))
	{
		return !!_rcClassStore;
	} ///

	auto opCall(Args...)(auto ref Args args)
	if (is(typeof(_rcClassGet.opCall(args))))
	{
		return _rcClassGet.opCall(args);
	} ///

	// lifetime

	void _rcClassDestroy()
	{
		if (_rcClassStore && --_rcClassStore.refCount == 0)
		{
			static if (__traits(hasMember, C, "__xdtor"))
				_rcClassGet.__xdtor();
			GC.free(_rcClassStore);
		}
	}

	this(this)
	{
		if (_rcClassStore)
			_rcClassStore.refCount++;
	}

	~this()
	{
		_rcClassDestroy();
	}
}

/// Constructs a new reference-counted instance of `C`.
/// (An external factory function is used instead of `static opCall`
/// to avoid conflicting with the class's non-static `opCall`.)
template rcClass(C)
if (is(C == class))
{
	RCClass!C rcClass(Args...)(auto ref Args args)
	if (is(C == class) && is(typeof(emplace!C(null, args))))
	{
		RCClass!C c;
		c._rcClassStore = new RCClassStore!C;
		c._rcClassStore.refCount = 1;
		emplace!C(c._rcClassStore.data[], args);
		return c;
	}
}

/// Constructors
unittest
{
	void ctorTest(bool haveArglessCtor, bool haveArgCtor)()
	{
		static class C
		{
			int n = -1;

			static if (haveArglessCtor)
				this() { n = 1; }

			static if (haveArgCtor)
				this(int val) { n = val; }

			~this() { n = -2; }
		}

		RCClass!C rc;
		assert(!rc);

		static if (haveArglessCtor || !haveArgCtor)
		{
			rc = rcClass!C();
			assert(rc);
			static if (haveArglessCtor)
				assert(rc.n == 1);
			else
				assert(rc.n == -1); // default value
		}
		else
			static assert(!is(typeof(rcClass!C())));

		static if (haveArgCtor)
		{
			rc = rcClass!C(42);
			assert(rc);
			assert(rc.n == 42);
		}
		else
			static assert(!is(typeof(rcClass!C(1))));

		rc = null;
		assert(!rc);
	}

	import std.meta : AliasSeq;
	foreach (haveArglessCtor; AliasSeq!(false, true))
		foreach (haveArgCtor; AliasSeq!(false, true))
			ctorTest!(haveArglessCtor, haveArgCtor);
}

/// Lifetime
unittest
{
	static class C
	{
		static int counter;

		this() { counter++; }
		~this() { counter--; }
	}

	{
		auto a = rcClass!C();
		assert(C.counter == 1);
		auto b = a;
		assert(C.counter == 1);
	}
	assert(C.counter == 0);
}

/// Inheritance
unittest
{
	static class Base
	{
		int foo() { return 1; }
	}

	static class Derived : Base
	{
		override int foo() { return 2; }
	}

	auto derived = rcClass!Derived();
	RCClass!Base base = derived; // initialization
	base = derived;              // assignment
	static assert(!is(typeof(derived = base)));
	auto base2 = cast(RCClass!Base)derived;
}

/// Non-static opCall
unittest
{
	static class C
	{
		int calls;
		void opCall() { calls++; }
	}

	auto c = rcClass!C();
	assert(c.calls == 0);
	c();
	assert(c.calls == 1);
}
