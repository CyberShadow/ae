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
	assert(reference(o) is o);
	assert(dereference(o) is o);

	static struct S {}
	S s;
	auto p = reference(s);
	assert(p is &s);
	assert(reference(p) is p);
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
		else static if (is(typeof(mixin(targetPrefix~name))) || __traits(getOverloads, __traits(parent, mixin(targetPrefix~name)), name).length != 0)
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
				auto ref opDispatch(this X, Args...)(auto ref Args args){ return mixin(targetPrefix~name~q{!T(args)}); }
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

alias Identity(alias a) = a;

alias parentOf(alias a) = Identity!(__traits(parent, a));

/// Instantiates to a type that points to a sub-aggregate
/// (mixin or template alias) of a struct or class.
/// Requires __traits(child) support:
/// https://github.com/D-Programming-Language/dmd/pull/3329
template ScopeProxy(alias a)
{
	alias parentOf!a S;
	alias RefType!S R;

	struct ScopeProxy
	{
		R _scopeProxy;

		this(R s) { _scopeProxy = s; }

		mixin StringMixinProxy!q{__traits(child, _scopeProxy, a).};
	}
}

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
