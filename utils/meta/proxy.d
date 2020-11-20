/**
 * Proxy objects
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

module ae.utils.meta.proxy;

import std.traits;

import ae.utils.meta : I;
import ae.utils.meta.caps;
import ae.utils.meta.reference;

/// Mixes in an opDispatch that forwards to the specified target prefix.
mixin template StringMixinProxy(string targetPrefix)
{
	// from std.typecons.Proxy
	template opDispatch(string name)
	{
		static if (is(typeof(mixin(targetPrefix~name)) == function))
		{
			// non template function
			auto ref opDispatch(this X, Args...)(auto ref Args args) { return mixin(targetPrefix~name~q{(args)}); }
		}
		else static if (is(typeof({ enum x = mixin(targetPrefix~name); })))
		{
			// built-in type field, manifest constant, and static non-mutable field
			enum opDispatch = mixin(targetPrefix~name);
		}
		else static if (is(typeof(mixin(targetPrefix~name)))
		  || (is(typeof(__traits(getOverloads, __traits(parent, mixin(targetPrefix~name)), name)))
		             && __traits(getOverloads, __traits(parent, mixin(targetPrefix~name)), name).length != 0
		     )
		)
		{
			// field or property function
			@property auto ref opDispatch(this X)()                { return mixin(targetPrefix~name        ); }
			@property auto ref opDispatch(this X, V)(auto ref V v) { return mixin(targetPrefix~name~q{ = v}); }
		}
		else
		{
			// member template
			template opDispatch(T...)
			{
				enum targs = T.length ? "!T" : "";
				auto ref opDispatch(this X, Args...)(auto ref Args args){ return mixin(targetPrefix~name~targs~q{(args)}); }
			}
		}
	}
}

/// Instantiates to a type that points to a named
/// sub-aggregate of a struct or class.
template SubProxy(alias S, string exp)
{
	alias RefType!S R;

	struct SubProxy
	{
		R _subProxy;

		this(R s) { _subProxy = s; }

		mixin StringMixinProxy!(q{_subProxy.} ~ exp);
	}
}

alias parentOf(alias a) = I!(__traits(parent, a));

/// Returns a type that points to a sub-aggregate
/// (mixin or template alias) of a struct or class.
/// Requires __traits(child) support.
template scopeProxy(alias a)
{
	@property auto scopeProxy()
	{
		return ScopeProxy!a(this.reference);
	}

	static @property auto scopeProxy(R)(R r)
	{
		return ScopeProxy!a(r);
	}
}

template ScopeProxy(alias a)
{
	static assert(haveChildTrait, "Your compiler doesn't support __traits(child)");

	alias parentOf!a S;
	alias RefType!S R;

	struct ScopeProxy
	{
		R _scopeProxy;

		this(R s) { _scopeProxy = s; }

		mixin StringMixinProxy!q{__traits(child, _scopeProxy, a).};
	}
}

static if (haveChildTrait && haveFieldAliasBinding)
unittest
{
	// Can't declare template at statement level
	static struct Dummy
	{
		static template T(alias a)
		{
			void set(int n)
			{
				a = n;
			}
		}
	}

	static struct S
	{
		int i;
		alias t = Dummy.T!i;

		auto getProxy() { return scopeProxy!t; }
	}

	{
		S s;
		auto w = ScopeProxy!(S.t)(&s);
		w.set(42);
		assert(s.i == 42);
	}

	{
		S s;
		auto w = scopeProxy!(S.t)(&s);
		w.set(42);
		assert(s.i == 42);
	}

	{
		S s;
		auto w = s.getProxy();
		w.set(42);
		assert(s.i == 42);
	}

	{
		S s;
		auto w = SubProxy!(S, "t.")(&s);
		w.set(42);
		assert(s.i == 42);
	}
}
