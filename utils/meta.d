/**
 * Metaprogramming stuff
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

module ae.utils.meta;

import std.traits;

/**
 * Same as TypeTuple, but meant to be used with values.
 *
 * Example:
 *   foreach (char channel; ValueTuple!('r', 'g', 'b'))
 *   {
 *     // the loop is unrolled at compile-time
 *     // "channel" is a compile-time value, and can be used in string mixins
 *   }
 */
template ValueTuple(T...)
{
	alias T ValueTuple;
}

template RangeTupleImpl(size_t N, R...)
{
	static if (N==R.length)
		alias R RangeTupleImpl;
	else
		alias RangeTupleImpl!(N, ValueTuple!(R, R.length)) RangeTupleImpl;
}

/// Generate a tuple containing integers from 0 to N-1.
/// Useful for static loop unrolling. (staticIota)
template RangeTuple(size_t N)
{
	alias RangeTupleImpl!(N, ValueTuple!()) RangeTuple;
}

template ArrayToTuple(alias arr, Elements...)
{
	static if (arr.length)
		alias ArrayToTuple = ArrayToTuple!(arr[1..$], ValueTuple!(Elements, arr[0]));
	else
		alias ArrayToTuple = Elements;
}

unittest
{
	alias X = ArrayToTuple!"abc";
	static assert(X[0] == 'a' && X[2] == 'c');
	static assert([X] == "abc");
}

/// Return something to foreach over optimally.
/// If A is known at compile-time, return a tuple,
/// so the foreach is unrolled at compile-time.
/// Otherwise, return A for a regular runtime foreach.
template CTIterate(alias A)
{
	static if (is(typeof(ArrayToTuple!A)))
		enum CTIterate = ArrayToTuple!A;
	else
		alias CTIterate = A;
}

unittest
{
	foreach (c; CTIterate!"abc") {}
	string s;
	foreach (c; CTIterate!s) {}
}

/// Like std.typecons.Tuple, but a template mixin.
/// Unlike std.typecons.Tuple, names may not be omitted - but repeating types may be.
/// Example: FieldList!(ubyte, "r", "g", "b", ushort, "a");
mixin template FieldList(Fields...)
{
	mixin(GenFieldList!(void, Fields));
}

template GenFieldList(T, Fields...)
{
	static if (Fields.length == 0)
		enum GenFieldList = "";
	else
	{
		static if (is(typeof(Fields[0]) == string))
			enum GenFieldList = T.stringof ~ " " ~ Fields[0] ~ ";\n" ~ GenFieldList!(T, Fields[1..$]);
		else
			enum GenFieldList = GenFieldList!(Fields[0], Fields[1..$]);
	}
}

unittest
{
	struct S
	{
		mixin FieldList!(ubyte, "r", "g", "b", ushort, "a");
	}
	S s;
	static assert(is(typeof(s.r) == ubyte));
	static assert(is(typeof(s.g) == ubyte));
	static assert(is(typeof(s.b) == ubyte));
	static assert(is(typeof(s.a) == ushort));
}

template isValueOfTypeInTuple(X, T...)
{
	static if (T.length==0)
		enum bool isValueOfTypeInTuple = false;
	else
	static if (T.length==1)
		enum bool isValueOfTypeInTuple = is(typeof(T[0]) : X);
	else
		enum bool isValueOfTypeInTuple = isValueOfTypeInTuple!(X, T[0..$/2]) || isValueOfTypeInTuple!(X, T[$/2..$]);
}

unittest
{
	static assert( isValueOfTypeInTuple!(int, ValueTuple!("a", 42)));
	static assert(!isValueOfTypeInTuple!(int, ValueTuple!("a", 42.42)));
	static assert(!isValueOfTypeInTuple!(int, ValueTuple!()));

	static assert(!isValueOfTypeInTuple!(int, "a", int, Object));
	static assert( isValueOfTypeInTuple!(int, "a", int, Object, 42));
}

template findValueOfTypeInTuple(X, T...)
{
	static if (T.length==0)
		static assert(false, "Can't find value of type " ~ X.stringof ~ " in specified tuple");
	else
	static if (is(typeof(T[0]) : X))
		enum findValueOfTypeInTuple = T[0];
	else
		enum findValueOfTypeInTuple = findValueOfTypeInTuple!(X, T[1..$]);
}

unittest
{
	static assert(findValueOfTypeInTuple!(int, ValueTuple!("a", 42))==42);
	static assert(findValueOfTypeInTuple!(int, "a", int, Object, 42)==42);
}

public import ae.utils.meta_x;

// ************************************************************************

static // http://d.puremagic.com/issues/show_bug.cgi?id=7805
string[] toArray(Args...)()
{
	string[] args;
	foreach (i, _ ; typeof(Args))
		args ~= Args[i].stringof;
	return args;
}

/// Returns the index of fun's parameter called "name",
/// or asserts if the parameter is not found.
size_t findParameter(alias fun, string name)()
{
	foreach (i, param; ParameterIdentifierTuple!fun)
		if (param == name)
			return i;
	assert(false, "Function " ~ __traits(identifier, fun) ~ " doesn't have a parameter called " ~ name);
}

// ************************************************************************

// Using a compiler with UDA support?
enum HAVE_UDA = __traits(compiles, __traits(getAttributes, Object));

static if (HAVE_UDA)
{
	template hasAttribute(T, alias D)
	{
		enum bool hasAttribute = isValueOfTypeInTuple!(T, __traits(getAttributes, D));
	}

	template getAttribute(T, alias D)
	{
		enum T getAttribute = findValueOfTypeInTuple!(T, __traits(getAttributes, D));
	}
}
else
{
	template hasAttribute(T, alias D)
	{
		enum bool hasAttribute = false;
	}

	template getAttribute(T, alias D)
	{
		static assert(false, "This D compiler has no UDA support.");
	}
}

// ************************************************************************

import std.conv;
import std.string;

string mixGenerateContructorProxies(T)()
{
	string s;
	static if (__traits(hasMember, T, "__ctor"))
		foreach (ctor; __traits(getOverloads, T, "__ctor"))
		{
			string[] declarationList, usageList;
			foreach (i, param; ParameterTypeTuple!(typeof(&ctor)))
			{
				auto varName = "v" ~ text(i);
				declarationList ~= param.stringof ~ " " ~ varName;
				usageList ~= varName;
			}
			s ~= "this(" ~ declarationList.join(", ") ~ ") { super(" ~ usageList.join(", ") ~ "); }\n";
		}
	return s;
}

/// Generate constructors that simply call the parent class constructors.
/// Based on http://forum.dlang.org/post/i3hpj0$2vc6$1@digitalmars.com
mixin template GenerateContructorProxies()
{
	mixin(mixGenerateContructorProxies!(typeof(super))());
}

unittest
{
	class A
	{
		int i, j;
		this() { }
		this(int i) { this.i = i; }
		this(int i, int j ) { this.i = i; this.j = j; }
	}

	class B : A
	{
		mixin GenerateContructorProxies;
	}

	A a;

	a = new B();
	assert(a.i == 0);
	a = new B(17);
	assert(a.i == 17);
	a = new B(17, 42);
	assert(a.j == 42);
}

// ************************************************************************

/// Were we built with -debug?
debug
	enum IsDebug = true;
else
	enum IsDebug = false;

// ************************************************************************

/// typeof(new T) - what we use to refer to an allocated instance
template RefType(T)
{
	static if (is(T == class))
		alias T RefType;
	else
		alias T* RefType;
}

/// Reverse of RefType
template FromRefType(R)
{
	static if (is(T == class))
		alias T FromRefType;
	else
	{
		static assert(is(typeof(*(R.init))), R.stringof ~ " is not dereferenceable");
		alias typeof(*(R.init)) FromRefType;
	}
}

/// A type that can be used to store instances of T.
/// A struct with T's instance size if T is a class, T itself otherwise.
template StorageType(T)
{
	static if (is(T == class))
	{
		//alias void*[(__traits(classInstanceSize, T) + size_t.sizeof-1) / size_t.sizeof] StorageType;
		//static assert(__traits(classInstanceSize, T) % size_t.sizeof == 0, "TODO"); // union with a pointer

		// Use a struct to allow new-ing the type (you can't new a static array directly)
		struct StorageType
		{
			void*[(__traits(classInstanceSize, T) + size_t.sizeof-1) / size_t.sizeof] data;
		}
	}
	else
		alias T StorageType;
}

// ************************************************************************

/// Is T a reference type (a pointer or a class)?
template isReference(T)
{
	enum isReference = isPointer!T || is(T==class);
}

/// Allow passing a constructed (non-null class, or non-class)
/// object by reference, without redundant indirection.
T* reference(T)(ref T v)
	if (!isReference!T)
{
	return &v;
}

/// ditto
T reference(T)(T v)
	if (isReference!T)
{
	return v;
}

/// Reverse of "reference".
ref typeof(*T.init) dereference(T)(T v)
	if (!isReference!T)
{
	return *v;
}

/// ditto
T dereference(T)(T v)
	if (isReference!T)
{
	return v;
}

unittest
{
	Object o = new Object;
	assert(o.reference is o);
	assert(o.dereference is o);

	static struct S {}
	S s;
	auto p = s.reference;
	assert(p is &s);
	assert(p.reference is p);
}

// ************************************************************************

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

alias parentOf(alias a) = Identity!(__traits(parent, a));

/// Does this compiler support __traits(child) ?
/// https://github.com/D-Programming-Language/dmd/pull/3329
enum haveChildTrait = is(typeof({ struct S { int i; } S s; __traits(child, s, S.i) = 0; }));

/// Instantiates to a type that points to a sub-aggregate
/// (mixin or template alias) of a struct or class.
/// Requires __traits(child) support.
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

static if (haveChildTrait)
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
	}

	{
		S s;
		auto w = ScopeProxy!(S.t)(&s);
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

// ************************************************************************

/// Get f's ancestor which represents its "this" pointer.
/// Skips template and mixin ancestors until it finds a struct or class.
template thisOf(alias f)
{
	alias p = Identity!(__traits(parent, f));
	static if (is(p == class) || is(p == struct) || is(p == union))
		alias thisOf = p;
	else
		alias thisOf = thisOf!p;
}

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

static if (haveChildTrait)
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
