/**
 * Metaprogramming
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

public import ae.utils.meta.reference;
public import ae.utils.meta.x;
public import ae.utils.meta.proxy;
public import ae.utils.meta.binding_v1;
public import ae.utils.meta.binding;

// ************************************************************************

import std.algorithm;
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

/// Return true if all of T's fields are the same type.
@property bool isHomogenous(T)()
{
	foreach (i, f; T.init.tupleof)
		if (!is(typeof(T.init.tupleof[i]) == typeof(T.init.tupleof[0])))
			return false;
	return true;
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

/// One past the biggest element of the enum T.
/// Example: string[enumLength!E] arr;
template enumLength(T)
	if (is(T==enum))
{
	enum enumLength = cast(T)(cast(size_t)T.max + 1);
}

deprecated alias EnumLength = enumLength;

// ************************************************************************

// http://d.puremagic.com/issues/show_bug.cgi?id=7805
static template stringofArray(Args...)
{
	static string[] stringofArray()
	{
		string[] args;
		foreach (i, _ ; typeof(Args))
			args ~= Args[i].stringof;
		return args;
	}
}

/// Returns the index of fun's parameter with the name
/// matching "names", or asserts if the parameter is not found.
/// "names" can contain multiple names separated by slashes.
static size_t findParameter(alias fun, string names)()
{
	foreach (name; names.split("/"))
		foreach (i, param; ParameterIdentifierTuple!fun)
			if (param == name)
				return i;
	assert(false, "Function " ~ __traits(identifier, fun) ~ " doesn't have a parameter called " ~ name);
}

/// ditto
// Workaround for no "static alias" template parameters
static size_t findParameter()(string[] searchedNames, string soughtNames, string funName)
{
	foreach (soughtName; soughtNames.split("/"))
	{
		auto targetIndex = searchedNames.countUntil(soughtName);
		if (targetIndex >= 0)
			return targetIndex;
	}
	assert(false, "No argument %s in %s's parameters (%s)".format(soughtNames, funName, searchedNames).idup);
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

/// Generate a @property function which creates/returns
/// a thread-local singleton of a class with the given arguments.

@property T singleton(T, args...)()
	if (is(typeof(new T(args))))
{
	static T instance;
	if (!instance)
		instance = new T(args);
	return instance;
}

unittest
{
	static class C
	{
		static int n = 0;

		this()      { n++; }
		this(int x) { n += x; }

		void fun() {}
	}

	alias singleton!C c0;
	c0.fun();
	c0.fun();
	assert(C.n == 1);

	alias singleton!(C, 5) c1;
	c1.fun();
	c1.fun();
	assert(C.n == 6);
}

// ************************************************************************

/// Were we built with -debug?
debug
	enum isDebug = true;
else
	enum isDebug = false;

deprecated alias IsDebug = isDebug;

// ************************************************************************

/// Shorter synonym for std.traits.Identity.
/// Can be used to UFCS-chain static methods and nested functions.
alias I(alias A) = A;

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

// ************************************************************************

/// Unsigned integer type big enough to fit N bits of precision.
template UnsignedBitsType(uint bits)
{
	static if (bits <= 8)
		alias ubyte UnsignedBitsType;
	else
	static if (bits <= 16)
		alias ushort UnsignedBitsType;
	else
	static if (bits <= 32)
		alias uint UnsignedBitsType;
	else
	static if (bits <= 64)
		alias ulong UnsignedBitsType;
	else
		static assert(0, "No integer type big enough to fit " ~ bits.stringof ~ " bits");
}

template SignedBitsType(uint bits)
{
	alias Signed!(UnsignedBitsType!bits) SignedBitsType;
}

/// Evaluates to array of strings with name for each field.
@property string[] structFields(T)()
	if (is(T == struct) || is(T == class))
{
	import std.string : split;

	string[] fields;
	foreach (i, f; T.init.tupleof)
	{
		string field = T.tupleof[i].stringof;
		field = field.split(".")[$-1];
		fields ~= field;
	}
	return fields;
}
