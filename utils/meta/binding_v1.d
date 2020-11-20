/**
 * Method binding - before alias inference
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

module ae.utils.meta.binding_v1;

import std.traits;

import ae.utils.meta.caps;
import ae.utils.meta.proxy;
import ae.utils.meta.reference;

/// Disconnect function (or function template) f from its "this" pointer,
/// creating a template that can be passed as an alias parameter
/// to a template which already has a context (such as a non-static
/// templated method).
/// To connect the alias back to a "this" pointer, use .connect(p).
/// Use .call(args) on the result to call the resulting function.
/// Requires __traits(child) support.
template disconnect(alias f)
{
	static assert(haveChildTrait, "Your compiler doesn't support __traits(child)");

	alias P = thisOf!f;
	alias R = RefType!P;

	struct disconnect
	{
		R p;

		@disable this();
		private this(R p) { this.p = p; }

		static typeof(this) connect(R p) { return typeof(this)(p); }

		auto call(T...)(auto ref T args)
		{
			return __traits(child, p, f)(args);
		}
	}
}

// (illustration for why disconnect is needed)
version(none)
{
	struct X
	{
		int i;

		void funB(/* ??? */)(/* ??? */)
		{
			c(i);
		}
	}

	struct Y
	{
		X* x;

		void funA()
		{
			// Problem: pass funC to x.funB so that funB can call it.
			// funC is a templated method, and Y doesn't know
			// how X will instantiate it beforehand.

			x.funB!funC(); // Doesn't work - X doesn't have an Y* and it
			               // is not transmitted via the alias parameter

			x.funB(&funC); // Doesn't work - can't take the address of a
			               // template declaration

			/* ??? */
		}

		void funC(T)(T v)
		{
			// ...
		}
	}
}

static if (haveChildTrait && haveFieldAliasBinding)
unittest
{
	static struct A()
	{
		static template Impl(alias v)
		{
			void call(T)(T target)
			{
				target.callee!(disconnect!call2)();
			}

			void call2(T)(T target)
			{
				target.setter();
			}
		}
	}

	static struct B(alias a)
	{
		static template Impl(alias v)
		{
			void doCall()
			{
				alias RefType!(typeof(this)) Parent;
				static struct Target
				{
					int i;
					Parent parent;

					void callee(alias setter)()
					{
						setter.connect(parent).call(&this);
					}

					void setter()
					{
						i = 42;
					}
				}

				Target target;
				target.parent = this.reference;
				a.call(&target);
				v = target.i;
			}
		}
	}

	static struct S
	{
		int v;
		alias a = A!( ).Impl!v;
		alias b = B!(a).Impl!v;
	}

	S s;
	s.b.doCall();
	assert(s.v == 42);
}

// ***************************************************************************

/// This function group manufactures delegate-like objects which selectively
/// contain a context or function pointer. This allows avoiding the overhead
/// of an indirect call (which prevents inlining), or passing around a context
/// when that context is already available on the caller's side, all while
/// having the same syntax for invocation. The invocation syntax is as follows:
/// If fun is the return value of these functions, and Fun is its type,
/// Fun.call(fun, args...) will invoke the respective function.
/// Unbound variants provide a callWith method, which additionally take a
/// context to rebind with.

/// Unbound delegate alias.
/// Return value contains nothing (empty struct).
/// Example construction: $(D unboundDgAlias!method)
@property auto unboundDgAlias(alias fun)()
{
	return UnboundDgAlias!fun();
}
struct UnboundDgAlias(alias fun)
{
	alias C = RefType!(thisOf!fun);

	static template Caller(alias fun)
	{
		auto Caller(Args...)(UnboundDgAlias self, auto ref Args args)
		{
			return fun(args);
		}
	}

	/// Call the delegate using the context from the caller's context.
	alias call = Caller!fun;

	/// Call the delegate using the given context.
	static auto callWith(Args...)(UnboundDgAlias self, C context, auto ref Args args)
	{
		return __traits(child, context, fun)(args);
	}
}

/// Bound delegate alias.
/// Return value contains context.
/// Example construction: $(D boundDgAlias!method(context))
template boundDgAlias(alias fun)
{
	static auto boundDgAlias(RefType!(thisOf!fun) context)
	{
		return BoundDgAlias!fun(context);
	}
}
struct BoundDgAlias(alias fun)
{
	alias C = RefType!(thisOf!fun);
	C context;

	/// Call the delegate using the stored context.
	static auto call(Args...)(BoundDgAlias self, auto ref Args args)
	{
		auto c = self.context;
		return __traits(child, c, fun)(args);
	}

	// HACK, TODO
	static auto callWith(C, Args...)(BoundDgAlias self, C context, auto ref Args args)
	{
		auto c = self.context;
		return __traits(child, c, fun)(args);
	}
}

/// Unbound delegate pointer.
/// Return value contains function pointer without context.
/// Example construction: $(D unboundDgPointer!method(&method))
/// Currently only implements callWith.
template unboundDgPointer(alias fun)
{
	static auto unboundDgPointer(Dg)(Dg dg)
	{
		return UnboundDgPointer!(RefType!(thisOf!fun), Dg)(dg);
	}
}
struct UnboundDgPointer(C, Dg)
{
	typeof(Dg.init.funcptr) func;

	this(Dg dg)
	{
		func = dg.funcptr;
	}

	static auto callWith(Args...)(UnboundDgPointer self, C context, auto ref Args args)
	{
		Dg dg;
		dg.ptr = context;
		dg.funcptr = self.func;
		return dg(args);
	}
}

/// Bound delegate pointer.
/// Just a regular D delegate, basically.
/// Return value contains a D delegate.
/// Example construction: $(D boundDgPointer(&method))
auto boundDgPointer(Dg)(Dg dg)
{
	return BoundDgPointer!Dg(dg);
}
struct BoundDgPointer(Dg)
{
	Dg dg;

	static auto call(Args...)(BoundDgPointer self, auto ref Args args)
	{
		return self.dg(args);
	}
}

static if (haveMethodAliasBinding)
unittest
{
	static struct A
	{
		static template Impl(alias anchor)
		{
			void caller(Fun)(Fun fun)
			{
			//	pragma(msg, Fun.sizeof);
				Fun.call(fun);
			}

			void callerIndirect(Fun, C)(Fun fun, C c)
			{
				Fun.callWith(fun, c);
			}
		}
	}

	static struct B(alias a)
	{
		static template Impl(alias anchor)
		{
			void test()
			{
				a.caller(unboundDgAlias!calleeB);
				a.callerIndirect(unboundDgAlias!calleeB, this.reference);

				C c;
				a.caller(boundDgAlias!(C.calleeC)(c.reference));

				a.callerIndirect(unboundDgPointer!(c.calleeC)(&c.calleeC), c.reference);

				a.caller(boundDgPointer(&c.calleeC));
			}

			void calleeB()
			{
				anchor = 42;
			}

			struct C
			{
				int value;

				void calleeC()
				{
					value = 42;
				}
			}
		}
	}

	static struct Test
	{
		int anchor;
		alias A.Impl!anchor a;
		alias B!a.Impl!anchor b;
	}

	Test test;
	test.b.test();
}

// ***************************************************************************

/// Equilavents to the above functions, but for entire objects.
/// Caller syntax:
/// Obj.method(obj, args...)

/// Create an unbound "object" which forwards calls to the given alias.
/// Context is inferred from caller site.
/// Example construction: unboundObj!aggregate
@property auto unboundObj(alias target)()
{
	return UnboundObj!target();
}
struct UnboundObj(alias target)
{
	template opDispatch(string name)
	{
		static template funTpl(alias fun)
		{
			auto funTpl(Args...)(UnboundObj!target self, auto ref Args args)
			{
				return fun(args);
			}
		}

		mixin(`alias opDispatch = funTpl!(target.`~name~`);`);
	}
}

/// Create a bound "object" with the given context.
/// Example construction: boundObj(context)
auto boundObj(S)(S s)
{
	return DispatchToFirstArg!S(s);
}

/// Create a bound "object" with the given sub-aggregate and context.
/// Example construction: boundObjScope!aggregate(context)
auto boundObjScope(alias obj, S)(S s)
{
	alias BoundProxy = ScopeProxy!obj;
	return DispatchToFirstArg!BoundProxy(BoundProxy(s));
}

struct DispatchToFirstArg(T)
{
	T next;

	template opDispatch(string name)
	{
		static auto opDispatch(Args...)(DispatchToFirstArg self, auto ref Args args)
		{
			return mixin("self.next." ~ name ~ "(args)");
		}
	}
}

static if (haveMethodAliasBinding)
unittest
{
	static struct Consumer
	{
		static template Impl(alias anchor)
		{
			void caller(Obj)(Obj obj)
			{
				Obj.callee(obj);
			}
		}
	}

	static struct AliasTarget(alias consumer)
	{
		static template Impl(alias anchor)
		{
			void test()
			{
				consumer.caller(unboundObj!(Impl!anchor));
				consumer.caller(boundObjScope!(Impl!anchor)(this.reference));

				static struct Test
				{
					void callee() {}
				}
				Test test;
				consumer.caller(boundObj(&test));
			}

			void callee() {}
		}
	}

	static struct Test
	{
		int anchor;
		alias Consumer.Impl!anchor c;
		alias AliasTarget!c.Impl!anchor t;

		void test()
		{
			t.test();
		}
	}

	Test test;
	test.test();
}
