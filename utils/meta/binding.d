/**
 * Method binding - using alias inference patch
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

module ae.utils.meta.binding;

import ae.utils.meta : thisOf;
import ae.utils.meta.caps;
import ae.utils.meta.reference;

/// Create unbound functor of a method
template unboundFunctorOf(alias f)
{
	static @property auto unboundFunctorOf()
	{
		UnboundFunctorOf!f r;
		return r;
	}
}
struct UnboundFunctorOf(alias f)
{
	alias opCall = f;

	alias R = RefType!(thisOf!f);
	auto bind(R r) { return boundFunctorOf!f(r); }
}

/// Create bound functor of a method
template boundFunctorOf(alias f)
{
	static @property auto boundFunctorOf(T)(T context)
	{
		BoundFunctorOf!(T, f) r;
		r.context = context;
		return r;
	}
}

/// ditto
@property auto boundFunctorOf(alias f)()
if (is(typeof(this))) // haveMethodAliasBinding
{
	BoundFunctorOf!(RefType!(typeof(this)), f) r;
	r.context = this.reference;
	return r;
}

struct BoundFunctorOf(R, alias f)
{
	R context;
	template opCall(Args...)
	{
		alias Ret = typeof(__traits(child, context, f)(Args.init));
		Ret opCall(auto ref Args args)
		{
			return __traits(child, context, f)(args);
		}
	}

	/// Ignore - BoundFunctors are already bound
	auto bind(R)(R r) { return this; }
}

static if (haveChildTrait)
unittest
{
	static struct Test
	{
		void caller(Func)(Func func)
		{
			func();
		}

		int i = 0;

		void callee()
		{
			i++;
		}

		void test()
		{
			caller(unboundFunctorOf!callee.bind(&this));
			assert(i == 1);

			static if (haveMethodAliasBinding) // or is it haveAliasCtxInference ?
			{
				caller(unboundFunctorOf!callee);
				caller(  boundFunctorOf!callee);

				assert(i == 3);
			}

			static struct S
			{
				int i = 0;

				void callee()
				{
					i++;
				}
			}
			S s;
			caller(boundFunctorOf!(S.callee)(&s));

			assert(s.i == 1);
		}
	}

	Test test;
	test.test();
}
