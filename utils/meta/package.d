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

import ae.utils.meta.caps;

// ************************************************************************

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

/// Expand an array to a tuple.
/// The array value must be known during compilation.
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

/// Expand a static array to a tuple.
/// Unlike ArrayToTuple, the array may be a runtime variable.
template expand(alias arr, size_t offset = 0)
	if (isStaticArray!(typeof(arr)))
{
	import std.typetuple : AliasSeq;

	static if (arr.length == offset)
		alias expand = AliasSeq!();
	else
	{
		@property ref getValue() { return arr[offset]; }
		alias expand = AliasSeq!(getValue, expand!(arr, offset+1));
	}
}

unittest
{
	int[3] arr = [1, 2, 3];
	void test(int a, int b, int c) {}
	test(expand!arr);
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

/// A range that iterates over all members of an enum.
@property auto enumIota(T)()
{
	import std.range : iota;
	return iota(T.init, enumLength!T);
}

unittest
{
	import std.algorithm.comparison : equal;
	enum E { a, b, c }
	static assert(equal(enumIota!E, [E.a, E.b, E.c]));
}

// ************************************************************************

/// What to use instead of void for boxVoid/unboxVoid.
/// Use void[0] instead of an empty struct as this one has a .sizeof
/// of 0, unlike the struct.
alias BoxedVoid = void[0];

/// D does not allow void variables or parameters.
/// As such, there is no "common type" for functions that return void
/// and non-void.
/// To allow generic metaprogramming in such cases, this function will
/// "box" a void expression to a different type.
auto boxVoid(T)(lazy T expr)
{
	static if (is(T == void))
	{
		expr;
		return BoxedVoid.init;
	}
	else
		return expr;
}

/// Inverse of boxVoid.
/// Can be used in a return statement, i.e.:
/// return unboxVoid(someBoxedVoid);
auto unboxVoid(T)(T value)
{
	static if (is(T == BoxedVoid))
		return;
	else
		return value;
}

unittest
{
	struct S { void* p; }

	auto process(T)(T delegate() dg)
	{
		auto result = dg().boxVoid;
		return result.unboxVoid;
	}

	S fun() { return S(); }
	assert(process(&fun) == S.init);

	void gun() { }
	static assert(is(typeof(process(&gun)) == void));
}

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
	import std.array : split;

	foreach (name; names.split("/"))
		foreach (i, param; ParameterIdentifierTuple!fun)
			if (param == name)
				return i;
	assert(false, "Function " ~ __traits(identifier, fun) ~ " doesn't have a parameter called " ~ names);
}

/// ditto
// Workaround for no "static alias" template parameters
static size_t findParameter()(string[] searchedNames, string soughtNames, string funName)
{
	import std.array : split;

	foreach (soughtName; soughtNames.split("/"))
	{
		import std.algorithm.searching : countUntil;

		auto targetIndex = searchedNames.countUntil(soughtName);
		if (targetIndex >= 0)
			return targetIndex;
	}

	{
		import std.format : format;

		assert(false, "No argument %s in %s's parameters (%s)"
			.format(soughtNames, funName, searchedNames).idup);
	}
}

unittest
{
	static void fun(int a, int b, int c) {}

	static assert(findParameter!(fun, "x/c") == 2);
	assert(findParameter(["a", "b", "c"], "x/c", "fun") == 2);
}

// ************************************************************************

/// Generates a function which passes its arguments to a struct, which is
/// returned. Preserves field names (as parameter names) and default values.
template structFun(S)
{
	string gen()
	{
		import std.algorithm.iteration : map;
		import std.array : join;
		import std.format : format;
		import std.meta : staticMap;
		import std.range : iota;

		enum identifierAt(int n) = __traits(identifier, S.tupleof[n]);
		enum names = [staticMap!(identifierAt, RangeTuple!(S.tupleof.length))];

		return
			"S structFun(\n" ~
			S.tupleof.length.iota.map!(n =>
			"	typeof(S.init.tupleof[%d]) %s = S.init.tupleof[%d],\n".format(n, names[n], n)
			).join() ~
			`) { return S(` ~ names.join(", ") ~ "); }";
	}

	mixin(gen());
}

unittest
{
	static struct Test
	{
		string a;
		int b = 42;
	}

	Test test = structFun!Test("banana");
	assert(test.a is "banana");
	assert(test.b == 42);
}

/// Generates a struct containing fields with names, types, and default values
/// corresponding to a function's parameter list.
static if (haveStaticForeach)
{
	mixin(q{
		struct StructFromParams(alias fun, bool voidInitializeRequired = false)
		{
			static foreach (i, T; ParameterTypeTuple!fun)
				static if (is(ParameterDefaultValueTuple!fun[i] == void))
					static if (voidInitializeRequired)
						mixin(`T ` ~ ParameterIdentifierTuple!fun[i] ~ ` = void;`);
					else
						mixin(`T ` ~ ParameterIdentifierTuple!fun[i] ~ `;`);
				else
					mixin(`T ` ~ ParameterIdentifierTuple!fun[i] ~ ` = ParameterDefaultValueTuple!fun[i];`);
		}
	});

	unittest
	{
		static void fun(string a, int b = 42) {}
		alias S = StructFromParams!fun;
		static assert(is(typeof(S.a) == string));
		static assert(S.init.b == 42);
	}
}

// ************************************************************************

/// Call a predicate with the given value. Return the value.
/// Intended to be used in UFCS chains using functions which mutate their argument,
/// such as skipOver and each.
template apply(alias dg)
{
	auto ref T apply(T)(auto ref T v)
	{
		dg(v);
		return v;
	}
}

///
unittest
{
	int i = 7;
	int j = i.apply!((ref v) => v++);
	assert(j == 8);
}

/// Evaluate all arguments and return the last argument.
/// Can be used instead of the comma operator.
/// Inspired by http://clhs.lisp.se/Body/s_progn.htm
Args[$-1] progn(Args...)(lazy Args args)
{
	foreach (n; RangeTuple!(Args[1..$].length))
		cast(void)args[n];
	return args[$-1];
}

unittest
{
	// Test that expressions are correctly evaluated exactly once.
	int a, b, c, d;
	d = progn(a++, b++, c++);
	assert(a==1 && b==1 && c == 1 && d == 0);
	d = progn(a++, b++, ++c);
	assert(a==2 && b==2 && c == 2 && d == 2);
}

unittest
{
	// Test void expressions.
	int a, b;
	void incA() { a++; }
	void incB() { b++; }
	progn(incA(), incB());
	assert(a == 1 && b == 1);
}

/// Like progn, but return the first argument instead.
Args[0] prog1(Args...)(lazy Args args)
{
	auto result = args[0];
	foreach (n; RangeTuple!(Args.length-1))
		cast(void)args[1+n];
	return result;
}

unittest
{
	int a = 10, b = 20, c = 30;
	int d = prog1(a++, b++, c++);
	assert(a==11 && b==21 && c == 31 && d == 10);
}

enum bool haveCommonType(T...) = is(CommonType!T) && !is(CommonType!T == void);

/// Lazily evaluate and return first true-ish result; otherwise return last result.
CommonType!Args or(Args...)(lazy Args args)
if (haveCommonType!Args)
{
	foreach (n; RangeTuple!(Args.length-1))
	{
		auto r = args[n];
		if (r)
			return r;
	}
	return args[$-1];
}

unittest
{
	assert(or(0, 7, 5) == 7);
	assert(or(0, 0, 0) == 0);
	int fun() { assert(false); }
	assert(or(0, 7, fun) == 7);
}

/// Lazily evaluate and return first false-ish result; otherwise return last result.
CommonType!Args and(Args...)(lazy Args args)
if (haveCommonType!Args)
{
	foreach (n; RangeTuple!(Args.length-1))
	{
		auto r = args[n];
		if (!r)
			return r;
	}
	return args[$-1];
}

unittest
{
	assert(and(7, 5, 0) == 0);
	assert(and(7, 5, 3) == 3);
	int fun() { assert(false); }
	assert(and(7, 0, fun) == 0);
}

// ************************************************************************

// Using a compiler with UDA support?
enum HAVE_UDA = __traits(compiles, __traits(getAttributes, Object));

static if (HAVE_UDA)
{
	/*
	template hasAttribute(T, alias D)
	{
		enum bool hasAttribute = isValueOfTypeInTuple!(T, __traits(getAttributes, D));
	}
	*/

	/// Detects types and values of the given type
	template hasAttribute(Args...)
		if (Args.length == 2)
	{
	//	alias attribute = Args[0];
	//	alias symbol = Args[1];

		import std.typetuple : staticIndexOf;
		import std.traits : staticMap;

		static if (is(Args[0]))
		{
			template isTypeOrValueInTuple(T, Args...)
			{
				static if (!Args.length)
					enum isTypeOrValueInTuple = false;
				else
				static if (is(Args[0] == T))
					enum isTypeOrValueInTuple = true;
				else
				static if (is(typeof(Args[0]) == T))
					enum isTypeOrValueInTuple = true;
				else
					enum isTypeOrValueInTuple = isTypeOrValueInTuple!(T, Args[1..$]);
			}

			enum bool hasAttribute = isTypeOrValueInTuple!(Args[0], __traits(getAttributes, Args[1]));
		}
		else
			enum bool hasAttribute = staticIndexOf!(Args[0], __traits(getAttributes, Args[1])) != -1;
	}

	template getAttribute(T, alias D)
	{
		enum T getAttribute = findValueOfTypeInTuple!(T, __traits(getAttributes, D));
	}

	unittest
	{
		struct Attr { int i; }

		struct S
		{
			@Attr int a;
			@Attr(5) int b;
			@("test") int c;
		}

		static assert(hasAttribute!(Attr, S.a));
		static assert(hasAttribute!(Attr, S.b));
		static assert(hasAttribute!(string, S.c));
		static assert(hasAttribute!("test", S.c));
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

/// Generate constructors that simply call the parent class constructors.
/// Based on http://forum.dlang.org/post/i3hpj0$2vc6$1@digitalmars.com
mixin template GenerateConstructorProxies()
{
	mixin(() {
		import std.conv : text;
		import std.string : join;
		import std.traits : ParameterTypeTuple, fullyQualifiedName;

		alias T = typeof(super);

		string s;
		static if (__traits(hasMember, T, "__ctor"))
			foreach (ctor; __traits(getOverloads, T, "__ctor"))
			{
				string[] declarationList, usageList;
				foreach (i, param; ParameterTypeTuple!(typeof(&ctor)))
				{
					auto varName = "v" ~ text(i);
					declarationList ~= fullyQualifiedName!param ~ " " ~ varName;
					usageList ~= varName;
				}
				s ~= "this(" ~ declarationList.join(", ") ~ ") { super(" ~ usageList.join(", ") ~ "); }\n";
			}
		return s;
	} ());
}

deprecated alias GenerateContructorProxies = GenerateConstructorProxies;

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
		mixin GenerateConstructorProxies;
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

/// As above, but using arbitrary types and a factory function.
@property singleton(alias fun, args...)()
	if (is(typeof(fun(args))))
{
	alias T = typeof(fun(args));
	static T instance;
	static bool initialized;
	if (!initialized)
	{
		instance = fun(args);
		initialized = true;
	}
	return instance;
}

unittest
{
	int n;
	int gen(int _ = 0)
	{
		return ++n;
	}

	alias singleton!gen c0;
	assert(c0 == 1);
	assert(c0 == 1);

	alias singleton!(gen, 1) c1;
	assert(c1 == 2);
	assert(c1 == 2);
}

// ************************************************************************

/// Were we built with -debug?
debug
	enum isDebug = true;
else
	enum isDebug = false;

deprecated alias IsDebug = isDebug;

/// Is a specific version on?
template isVersion(string versionName)
{
	mixin(`version (` ~ versionName ~ `) enum isVersion = true; else enum isVersion = false;`);
}

// ************************************************************************

/// Identity function.
auto ref T identity(T)(auto ref T value) { return value; }

/// Shorter synonym for std.traits.Identity.
/// Can be used to UFCS-chain static methods and nested functions.
alias I(alias A) = A;

// ************************************************************************

/// Get f's ancestor which represents its "this" pointer.
/// Skips template and mixin ancestors until it finds a struct or class.
template thisOf(alias f)
{
	alias p = I!(__traits(parent, f));
	static if (is(p == class) || is(p == struct) || is(p == union))
		alias thisOf = p;
	else
		alias thisOf = thisOf!p;
}

// ************************************************************************

/// Return the number of bits used to store the value part, i.e.
/// T.sizeof*8 for integer parts and the mantissa size for
/// floating-point types.
template valueBits(T)
{
	static if (is(T : ulong))
		enum valueBits = T.sizeof * 8;
	else
	static if (is(T : real))
		enum valueBits = T.mant_dig;
	else
		static assert(false, "Don't know how many value bits there are in " ~ T.stringof);
}

static assert(valueBits!uint == 32);
static assert(valueBits!double == 53);

/// Expand to a built-in numeric type of the same kind
/// (signed integer / unsigned integer / floating-point)
/// with at least the indicated number of bits of precision.
template ResizeNumericType(T, uint bits)
{
	static if (is(T : ulong))
		static if (isSigned!T)
			alias ResizeNumericType = SignedBitsType!bits;
		else
			alias ResizeNumericType = UnsignedBitsType!bits;
	else
	static if (is(T : real))
	{
		static if (bits <= float.mant_dig)
			alias ResizeNumericType = float;
		else
		static if (bits <= double.mant_dig)
			alias ResizeNumericType = double;
		else
		static if (bits <= real.mant_dig)
			alias ResizeNumericType = real;
		else
			static assert(0, "No floating-point type big enough to fit " ~ bits.stringof ~ " bits");
	}
	else
		static assert(false, "Don't know how to resize type: " ~ T.stringof);
}

static assert(is(ResizeNumericType!(float, double.mant_dig) == double));

/// Expand to a built-in numeric type of the same kind
/// (signed integer / unsigned integer / floating-point)
/// with at least additionalBits more bits of precision.
alias ExpandNumericType(T, uint additionalBits) =
	ResizeNumericType!(T, valueBits!T + additionalBits);

/// Like ExpandNumericType, but do not error if the resulting type is
/// too large to fit any native D type - just expand to the largest
/// type of the same kind instead.
template TryExpandNumericType(T, uint additionalBits)
{
	static if (is(typeof(ExpandNumericType!(T, additionalBits))))
		alias TryExpandNumericType = ExpandNumericType!(T, additionalBits);
	else
		static if (is(T : ulong))
			static if (isSigned!T)
				alias TryExpandNumericType = long;
			else
				alias TryExpandNumericType = ulong;
		else
		static if (is(T : real))
			alias TryExpandNumericType = real;
		else
			static assert(false, "Don't know how to expand type: " ~ T.stringof);
}

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

/// Returns the class's initializer instance.
/// Returns null if all class fields are zero.
/// Can be used to get the value of class fields' initial values.
immutable(T) classInit(T)()
if (is(T == class))
{
	return cast(immutable(T))typeid(T).initializer.ptr;
}

///
unittest
{
	class C { int n = 42; }
	assert(classInit!C.n == 42);
}

/// Create a functor value type (bound struct) from an alias.
template functor(alias fun)
{
	struct Functor
	{
		//alias opCall = fun;
		auto opCall(T...)(auto ref T args) { return fun(args); }
	}

	Functor functor()
	{
		Functor f;
		return f;
	}
}

static if (haveAliasStructBinding)
unittest
{
	static void caller(F)(F fun)
	{
		fun(42);
	}

	int result;
	caller(functor!((int i) => result = i));
	assert(result == 42);
}
