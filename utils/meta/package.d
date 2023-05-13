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
 *   Vladimir Panteleev <ae@cy.md>
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
import std.typecons : tuple;

/**
 * Same as TypeTuple, but meant to be used with values.
 *
 * Example:
 *   foreach (char channel; valueTuple!('r', 'g', 'b'))
 *   {
 *     // the loop is unrolled at compile-time
 *     // "channel" is a compile-time value, and can be used in string mixins
 *   }
 */
template valueTuple(T...)
{
	alias T valueTuple;
}
deprecated alias ValueTuple = valueTuple;

template _rangeTupleImpl(size_t N, R...)
{
	static if (N==R.length)
		alias R _rangeTupleImpl;
	else
		alias _rangeTupleImpl!(N, valueTuple!(R, R.length)) _rangeTupleImpl;
}

/// Generate a tuple containing integers from 0 to N-1.
/// Useful for static loop unrolling. (staticIota)
template rangeTuple(size_t N)
{
	alias _rangeTupleImpl!(N, valueTuple!()) rangeTuple;
}
deprecated alias RangeTuple = rangeTuple;

/// Expand an array to a tuple.
/// The array value must be known during compilation.
template arrayToTuple(alias arr, Elements...)
{
	///
	static if (arr.length)
		alias arrayToTuple = arrayToTuple!(arr[1..$], valueTuple!(Elements, arr[0]));
	else
		alias arrayToTuple = Elements;
}
deprecated alias ArrayToTuple = arrayToTuple;

unittest
{
	alias X = arrayToTuple!"abc";
	static assert(X[0] == 'a' && X[2] == 'c');
	static assert([X] == "abc");
}

/// Expand a static array to a tuple.
/// Unlike `arrayToTuple`, the array may be a runtime variable.
template expand(alias arr, size_t offset = 0)
	if (isStaticArray!(typeof(arr)))
{
	import std.typetuple : AliasSeq;

	///
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

/// Maps values with a predicate, returning a `std.typecons` tuple.
auto tupleMap(alias pred, Values...)(auto ref Values values)
{
	static if (values.length == 0)
		return tuple();
	else
		return tuple(pred(values[0]), tupleMap!pred(values[1 .. $]).expand);
}

unittest
{
	assert(tuple(2, 3.0).expand.tupleMap!(n => n + 1) == tuple(3, 4.0));
}

/// Return something to foreach over optimally.
/// If A is known at compile-time, return a tuple,
/// so the foreach is unrolled at compile-time.
/// Otherwise, return A for a regular runtime foreach.
template CTIterate(alias A)
{
	///
	static if (is(typeof(arrayToTuple!A)))
		enum CTIterate = arrayToTuple!A;
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
	mixin(_GenFieldList!(void, Fields));
}

template _GenFieldList(T, Fields...)
{
	///
	static if (Fields.length == 0)
		enum _GenFieldList = "";
	else
	{
		static if (is(typeof(Fields[0]) == string))
			enum _GenFieldList = T.stringof ~ " " ~ Fields[0] ~ ";\n" ~ _GenFieldList!(T, Fields[1..$]);
		else
			enum _GenFieldList = _GenFieldList!(Fields[0], Fields[1..$]);
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
@property bool isHomogeneous(T)()
{
	foreach (i, f; T.init.tupleof)
		if (!is(typeof(T.init.tupleof[i]) == typeof(T.init.tupleof[0])))
			return false;
	return true;
}
deprecated alias isHomogenous = isHomogeneous;

/// Resolves to `true` if tuple `T` contains a value whose type is `X`.
template isValueOfTypeInTuple(X, T...)
{
	///
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
	static assert( isValueOfTypeInTuple!(int, valueTuple!("a", 42)));
	static assert(!isValueOfTypeInTuple!(int, valueTuple!("a", 42.42)));
	static assert(!isValueOfTypeInTuple!(int, valueTuple!()));

	static assert(!isValueOfTypeInTuple!(int, "a", int, Object));
	static assert( isValueOfTypeInTuple!(int, "a", int, Object, 42));
}

/// Returns the first value in `T` of type `X`.
template findValueOfTypeInTuple(X, T...)
{
	///
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
	static assert(findValueOfTypeInTuple!(int, valueTuple!("a", 42))==42);
	static assert(findValueOfTypeInTuple!(int, "a", int, Object, 42)==42);
}

/// Combines the getMember and allMembers traits, to return the
/// parameter's members as aliases.
template AllMembers(X...)
if (X.length == 1)
{
	alias GetMember(string name) = I!(__traits(getMember, X, name));
	alias AllMembers = staticMap!(GetMember, __traits(allMembers, X));
}

unittest
{
	import std.typetuple : AliasSeq;

	struct A { struct B {} struct C {} }
	static assert(is(AllMembers!A == AliasSeq!(A.B, A.C)));
}

// ************************************************************************

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

struct Has(E, bool byRef)
{
private:
	static if (byRef)
	{
		E* p;
		@property ref e() { return *p; }
	}
	else
		E e;

public:
	@property bool opDispatch(string name)()
	if (__traits(hasMember, E, name))
	{
		static foreach (i, member; EnumMembers!E)
			static if (__traits(identifier, EnumMembers!E[i]) == name)
				return (e & member) == member;
	}

	@property bool opDispatch(string name)(bool value)
	if (byRef && __traits(hasMember, E, name))
	{
		static foreach (i, member; EnumMembers!E)
			static if (__traits(identifier, EnumMembers!E[i]) == name)
			{
				if (value)
					e |= member;
				else
					e &= ~member;
				return value;
			}
	}
}

/// Convenience facility for manipulating bitfield enums.
auto has(E)(ref E e) if (is(E == enum)) { return Has!(E, true)(&e); }
auto has(E)(    E e) if (is(E == enum)) { return Has!(E, false)(e); } /// ditto

///
unittest
{
	enum E
	{
		init = 0,
		foo = 1 << 0,
		bar = 1 << 1,
	}
	assert(E.foo.has.foo);
	E e;
	assert(!e.has.foo);
	e.has.foo = true;
	assert(e.has.foo);
}

// ************************************************************************

// Use strong typing to provably disambiguate BoxedVoid from any other type.
private struct BoxedVoidElement {}

/// What to use instead of void for boxVoid/unboxVoid.
/// Use a zero-length array instead of an empty struct as this one has a .sizeof
/// of 0, unlike the struct.
alias BoxedVoid = BoxedVoidElement[0];

static assert(BoxedVoid.sizeof == 0);

/// Resolves to `BoxedVoid` if `T` is `void`, or to `T` otherwise.
template BoxVoid(T)
{
	///
	static if (is(T == void))
		alias BoxVoid = BoxedVoid;
	else
		alias BoxVoid = T;
}

/// D does not allow void variables or parameters.
/// As such, there is no "common type" for functions that return void
/// and non-void.
/// To allow generic metaprogramming in such cases, this function will
/// "box" a void expression to a different type.
BoxVoid!T boxVoid(T)(lazy T expr)
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

/// As boxVoid/unboxVoid, but returns a struct with zero or one members.
/// .tupleof can then be used to paste the tuple in e.g. an argument list.
auto voidStruct(T)(T value)
if (!is(T == void))
{
	static struct Result
	{
		static if (!is(T == BoxedVoid))
			T value;
	}

	static if (is(T == BoxedVoid))
		return Result();
	else
		return Result(value);
}

/// ditto
auto voidStruct(T)(lazy T value)
if (is(T == void))
{
	value; // evaluate

	static struct Result {}
	return Result();
}

unittest
{
	import std.typetuple : AliasSeq;

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

	gun(gun().boxVoid.voidStruct.tupleof);
	gun(gun().voidStruct.tupleof);
	static assert(is(typeof(fun().boxVoid.voidStruct.tupleof) == AliasSeq!S));
	static assert(is(typeof(fun().voidStruct.tupleof) == AliasSeq!S));
}

// ************************************************************************

/// `std.traits.ParameterIdentifierTuple` patched to support anonymous functions.
// https://issues.dlang.org/show_bug.cgi?id=13780
// https://github.com/dlang/phobos/pull/3620
template ParameterNames(func...)
    if (func.length == 1 && isCallable!func)
{
    static if (is(FunctionTypeOf!func PT == __parameters))
    {
        template Get(size_t i)
        {
            // Unnamed parameters yield CT error.
            static if (is(typeof(__traits(identifier, PT[i..i+1]))x))
            {
                enum Get = __traits(identifier, PT[i..i+1]);
            }
            else
            {
                enum Get = "";
            }
        }
    }
    else
    {
        static assert(0, func[0].stringof ~ "is not a function");

        // Define dummy entities to avoid pointless errors
        template Get(size_t i) { enum Get = ""; }
        alias PT = AliasSeq!();
    }

	import std.typetuple : AliasSeq;

    template Impl(size_t i = 0)
    {
        static if (i == PT.length)
            alias Impl = AliasSeq!();
        else
            alias Impl = AliasSeq!(Get!i, Impl!(i+1));
    }

    alias ParameterNames = Impl!();
}

/// Apply `.stringof` over `Args` and
/// return the result as a `string[]`.
static // https://issues.dlang.org/show_bug.cgi?id=7805
template stringofArray(Args...)
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
		foreach (i, param; ParameterNames!fun)
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
	mixin((){
		import std.algorithm.iteration : map;
		import std.array : join;
		import std.format : format;
		import std.meta : staticMap;
		import std.range : iota;

		enum identifierAt(int n) = __traits(identifier, S.tupleof[n]);
		enum names = [staticMap!(identifierAt, rangeTuple!(S.tupleof.length))];

		return
			"S structFun(\n" ~
			S.tupleof.length.iota.map!(n =>
			"	typeof(S.init.tupleof[%d]) %s = S.init.tupleof[%d],\n".format(n, names[n], n)
			).join() ~
			`) { return S(` ~ names.join(", ") ~ "); }";
	}());
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
struct StructFromParams(args...)
if (args.length == 1 || args.length == 2)
{
	mixin((){
		alias fun = args[0];
		static if (args.length == 1)
			enum bool voidInitializeRequired = false;
		else
			enum bool voidInitializeRequired = args[1];
		import ae.utils.text.ascii : toDec;

		string code;
		foreach (i; rangeTuple!(ParameterTypeTuple!fun.length))
		{
			enum n = toDec(i);

			code ~= `ParameterTypeTuple!(args[0])[` ~ n ~ `] `;

			static if (ParameterNames!fun[i].length)
				code ~= ParameterNames!fun[i];
			else
				code ~= "_param_" ~ toDec(i);

			static if (is(ParameterDefaultValueTuple!fun[i] == void))
				static if (voidInitializeRequired)
					code ~= ` = void;`;
				else
					code ~= `;`;
			else
				code ~= ` = ParameterDefaultValueTuple!(args[0])[` ~ n ~ `];`;
		}
		return code;
	}());
}

unittest
{
	static void fun(string a, int b = 42) {}
	alias S = StructFromParams!fun;
	static assert(is(typeof(S.a) == string));
	static assert(S.init.b == 42);
}

unittest
{
	static void fun(string, int = 42) {}
	alias Fun = typeof(&fun);
	alias S = StructFromParams!Fun;
	static assert(is(typeof(S.tupleof[0]) == string));
}

// ************************************************************************

// By Paul Backus: https://forum.dlang.org/post/mkiyylyjznwgkzpnbryk@forum.dlang.org
/// Pass struct / tuple members as arguments to a function.
alias tupleAs(alias fun) = args => fun(args.tupleof);

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
	foreach (n; rangeTuple!(Args[1..$].length))
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
	foreach (n; rangeTuple!(Args.length-1))
		cast(void)args[1+n];
	return result;
}

unittest
{
	int a = 10, b = 20, c = 30;
	int d = prog1(a++, b++, c++);
	assert(a==11 && b==21 && c == 31 && d == 10);
}

/// Resolves to `true` if there exists a non-`void`
/// common type for all elements of `T`.
enum bool haveCommonType(T...) = is(CommonType!T) && !is(CommonType!T == void);

/// Lazily evaluate and return first true-ish result; otherwise return last result.
CommonType!Args or(Args...)(lazy Args args)
if (haveCommonType!Args)
{
	foreach (n; rangeTuple!(Args.length-1))
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
	foreach (n; rangeTuple!(Args.length-1))
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
deprecated alias HAVE_UDA = haveUDA;

static if (haveUDA)
{
	/*
	template hasAttribute(T, alias D)
	{
		enum bool hasAttribute = isValueOfTypeInTuple!(T, __traits(getAttributes, D));
	}
	*/

	/// Detects types and values of the given type.
	template hasAttribute(Args...)
		if (Args.length == 2)
	{
	//	alias attribute = Args[0];
	//	alias symbol = Args[1];

		import std.typetuple : staticIndexOf;
		import std.traits : staticMap;

		///
		static if (is(Args[0]))
		{
			template _isTypeOrValueInTuple(T, Args...)
			{
				static if (!Args.length)
					enum _isTypeOrValueInTuple = false;
				else
				static if (is(Args[0] == T))
					enum _isTypeOrValueInTuple = true;
				else
				static if (is(typeof(Args[0]) == T))
					enum _isTypeOrValueInTuple = true;
				else
					enum _isTypeOrValueInTuple = _isTypeOrValueInTuple!(T, Args[1..$]);
			}

			enum bool hasAttribute = _isTypeOrValueInTuple!(Args[0], __traits(getAttributes, Args[1]));
		}
		else
			enum bool hasAttribute = staticIndexOf!(Args[0], __traits(getAttributes, Args[1])) != -1;
	}

	/// Retrieves the attribute (type or value of the given type).
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
	/// Stub (unsupported)>
	template hasAttribute(T, alias D)
	{
		enum bool hasAttribute = false;
	}

	/// ditto
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
	alias _p = I!(__traits(parent, f));
	///
	static if (is(_p == class) || is(_p == struct) || is(_p == union))
		alias thisOf = _p;
	else
		alias thisOf = thisOf!_p;
}

// ************************************************************************

/// Return the number of bits used to store the value part, i.e.
/// T.sizeof*8 for integer parts and the mantissa size for
/// floating-point types.
template valueBits(T)
{
	///
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
	///
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
	///
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

/// Integer type big enough to fit N bits of precision.
template UnsignedBitsType(uint bits)
{
	///
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

/// ditto
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
deprecated("Use ae.utils.functor")
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
