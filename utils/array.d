/**
 * Array utility functions
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

module ae.utils.array;

import std.algorithm.iteration;
import std.algorithm.mutation;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.exception;
import std.format;
import std.functional;
import std.range.primitives;
import std.traits;

import ae.utils.meta;

public import ae.utils.aa;
public import ae.utils.appender;

/// Slice a variable.
@property T[] asSlice(T)(ref T v)
{
	return (&v)[0..1];
}

// deprecated alias toArray = asSlice;
// https://issues.dlang.org/show_bug.cgi?id=23968
deprecated T[] toArray(T)(ref T v) { return v.asSlice; }

/// Wrap `v` into a static array of length 1.
@property T[1] asUnitStaticArray(T)(T v)
{
	return (&v)[0..1];
}

/// ditto
@property ref T[1] asUnitStaticArray(T)(ref T v)
{
	return (&v)[0..1];
}

debug(ae_unittest) unittest
{
	int[1] arr = 1.asUnitStaticArray;
	int i;
	assert(i.asUnitStaticArray.ptr == &i);
}

/// std.array.staticArray polyfill
static if (__traits(hasMember, std.array, "staticArray"))
	public import std.array : staticArray;
else
	pragma(inline, true) T[n] staticArray(T, size_t n)(auto ref T[n] a) { return a; }

/// Convert a dynamic array to a static array
template toStaticArray(size_t n)
{
	ref T[n] toStaticArray(T)(return T[] a)
	{
		assert(a.length == n, "Size mismatch");
		return a[0 .. n];
	}
}

debug(ae_unittest) unittest
{
	auto a = [1, 2, 3];
	assert(a.toStaticArray!3 == [1, 2, 3]);

	import std.range : chunks;
	auto b = [1, 2, 3, 4];
	assert(b.chunks(2).map!(toStaticArray!2).array == [[1, 2], [3, 4]]);
}

/// Return the value represented as an array of bytes.
@property inout(ubyte)[] asBytes(T)(ref inout(T) value)
	if (!hasIndirections!T)
{
	return value.asSlice.asBytes;
}

/// ditto
@property inout(ubyte)[] asBytes(T)(inout(T) value)
	if (is(T U : U[]) && !hasIndirections!U)
{
	return cast(inout(ubyte)[])value;
}

// deprecated alias bytes = asBytes;
// https://issues.dlang.org/show_bug.cgi?id=23968
deprecated @property inout(ubyte)[] bytes(T)(ref inout(T) value) if (!hasIndirections!T) { return value.asBytes; }
deprecated @property inout(ubyte)[] bytes(T)(inout(T) value) if (is(T U : U[]) && !hasIndirections!U) { return value.asBytes; }

debug(ae_unittest) unittest
{
	ubyte b = 5;
	assert(b.asBytes == [5]);

	struct S { ubyte b = 5; }
	S s;
	assert(s.asBytes == [5]);

	ubyte[1] sa = [5];
	assert(sa.asBytes == [5]);

	void[] va = sa[];
	assert(va.asBytes == [5]);
}

/// Reverse of .asBytes
ref inout(T) as(T)(inout(ubyte)[] bytes)
	if (!hasIndirections!T)
{
	assert(bytes.length == T.sizeof, "Data length mismatch for %s".format(T.stringof));
	return *cast(inout(T)*)bytes.ptr;
}

/// ditto
inout(T) as(T)(inout(ubyte)[] bytes)
	if (is(T U == U[]) && !hasIndirections!U)
{
	return cast(inout(T))bytes;
}

// deprecated alias fromBytes = as;
// https://issues.dlang.org/show_bug.cgi?id=23968
deprecated ref inout(T) fromBytes(T)(inout(ubyte)[] bytes) if (!hasIndirections!T) { return bytes.as!T; }
deprecated inout(T) fromBytes(T)(inout(ubyte)[] bytes) if (is(T U == U[]) && !hasIndirections!U) { return bytes.as!T; }

debug(ae_unittest) unittest
{
	{       ubyte b = 5; assert(b.asBytes.as!ubyte == 5); }
	{ const ubyte b = 5; assert(b.asBytes.as!ubyte == 5); }
	struct S { ubyte b; }
	{       ubyte b = 5; assert(b.asBytes.as!S == S(5)); }
}

debug(ae_unittest) unittest
{
	struct S { ubyte a, b; }
	ubyte[] arr = [1, 2];
	assert(arr.as!S == S(1, 2));
	assert(arr.as!(S[]) == [S(1, 2)]);
	assert(arr.as!(S[1]) == [S(1, 2)]);
}

/// Return the value represented as a static array of bytes.
@property ref inout(ubyte)[T.sizeof] asStaticBytes(T)(ref inout(T) value)
	if (!hasIndirections!T)
{
	return *cast(inout(ubyte)[T.sizeof]*)&value;
}

/// ditto
@property inout(ubyte)[T.sizeof] asStaticBytes(T)(inout(T) value)
	if (!hasIndirections!T)
{
	return *cast(inout(ubyte)[T.sizeof]*)&value;
}

debug(ae_unittest) unittest
{
	ubyte[4] arr = 1.asStaticBytes;

	int i;
	void* a = i.asStaticBytes.ptr;
	void* b = &i;
	assert(a is b);
}

/// Returns an empty, but non-null slice of T.
auto emptySlice(T)() pure @trusted
{
	static if (false)  // https://github.com/ldc-developers/ldc/issues/831
	{
		T[0] arr;
		auto p = arr.ptr;
	}
	else
		auto p = cast(T*)1;
	return p[0..0];
}

debug(ae_unittest) unittest
{
	int[] arr = emptySlice!int;
	assert(arr.ptr);
	immutable int[] iarr = emptySlice!int;
	assert(iarr.ptr);
}

// ************************************************************************

/// A more generic alternative to the "is" operator,
/// which doesn't have corner cases with static arrays / floats.
bool isIdentical(T)(auto ref T a, auto ref T b)
{
	static if (hasIndirections!T)
		return a is b;
	else
		return a.asStaticBytes == b.asStaticBytes;
}

debug(ae_unittest) unittest
{
	float nan;
	assert(isIdentical(nan, nan));
	float[4] nans;
	assert(isIdentical(nans, nans));
}

/// C `memcmp` wrapper.
int memcmp(in ubyte[] a, in ubyte[] b)
{
	assert(a.length == b.length);
	import core.stdc.string : memcmp;
	return memcmp(a.ptr, b.ptr, a.length);
}

/// Like std.algorithm.copy, but without the auto-decode bullshit.
/// https://issues.dlang.org/show_bug.cgi?id=13650
void memmove(T)(T[] dst, in T[] src)
{
	assert(src.length == dst.length);
	import core.stdc.string : memmove;
	memmove(dst.ptr, src.ptr, dst.length * T.sizeof);
}

/// Performs binary operation `op` on every element of `a` and `b`.
T[] vector(string op, T)(T[] a, T[] b)
{
	assert(a.length == b.length);
	T[] result = new T[a.length];
	foreach (i, ref r; result)
		r = mixin("a[i]" ~ op ~ "b[i]");
	return result;
}

/// Performs in-place binary operation `op` on every element of `a` and `b`.
T[] vectorAssign(string op, T)(T[] a, T[] b)
{
	assert(a.length == b.length);
	foreach (i, ref r; a)
		mixin("r " ~ op ~ "= b[i];");
	return a;
}

/// Return `s` expanded to at least `l` elements, filling them with `c`.
T[] padRight(T)(T[] s, size_t l, T c)
{
	auto ol = s.length;
	if (ol < l)
	{
		s.length = l;
		s[ol..$] = c;
	}
	return s;
}

/// Return a new `T[]` of length `l`, filled with `c`.
T[] repeatOne(T)(T c, size_t l)
{
	T[] result = new T[l];
	result[] = c;
	return result;
}

static import std.string;
/// Pull in overload set
private alias indexOf = std.string.indexOf;
private alias lastIndexOf = std.string.lastIndexOf;

/// Complement to std.string.indexOf which works with arrays
/// of non-character types.
/// Unlike std.algorithm.countUntil, it does not auto-decode,
/// and returns an index usable for array indexing/slicing.
ptrdiff_t indexOf(T, D)(in T[] arr, in D val)
//	if (!isSomeChar!T)
	if (!isSomeChar!T && is(typeof(arr.countUntil(val))) && is(typeof(arr[0]==val)))
{
	//assert(arr[0]==val);
	return arr.countUntil(val);
}

ptrdiff_t indexOf(T)(in T[] arr, in T[] val) /// ditto
	if (!isSomeChar!T && is(typeof(arr.countUntil(val))))
{
	return arr.countUntil(val);
} /// ditto

debug(ae_unittest) unittest
{
	assert("abc".indexOf('b') == 1);
	assert("abc".indexOf("b") == 1);
	assert([1, 2, 3].indexOf( 2 ) == 1);
	assert([1, 2, 3].indexOf([2]) == 1);
}

/// Same for `lastIndexOf`.
ptrdiff_t lastIndexOf(T, D)(in T[] arr, in D val)
	// if (!isSomeChar!T)
	if (!isSomeChar!T && is(typeof(arr[0]==val)))
{
	foreach_reverse (i, ref v; arr)
		if (v == val)
			return i;
	return -1;
}

ptrdiff_t lastIndexOf(T)(in T[] arr, in T[] val) /// ditto
	if (!isSomeChar!T && is(typeof(arr[0..1]==val[0..1])))
{
	if (val.length > arr.length)
		return -1;
	foreach_reverse (i; 0 .. arr.length - val.length + 1)
		if (arr[i .. i + val.length] == val)
			return i;
	return -1;
} /// ditto

debug(ae_unittest) unittest
{
	assert("abc".lastIndexOf('b') == 1);
	assert("abc".lastIndexOf("b") == 1);
	assert([1, 2, 3].lastIndexOf( 2 ) == 1);
	assert([1, 2, 3].lastIndexOf([2]) == 1);

	assert([1, 2, 3, 2, 4].lastIndexOf( 2 ) == 3);
	assert([1, 2, 3, 2, 4].lastIndexOf([2]) == 3);
	assert([1, 2, 3, 2, 4].lastIndexOf([2, 3]) == 1);
	assert([1, 2, 3, 2, 4].lastIndexOf([2, 5]) == -1);
	assert([].lastIndexOf([2, 5]) == -1);
}

deprecated("Use `indexOf`")
ptrdiff_t indexOfElement(T, D)(in T[] arr, auto ref const D val)
	if (is(typeof(arr[0]==val)))
{
	foreach (i, ref v; arr)
		if (v == val)
			return i;
	return -1;
}

/// Whether array contains value, no BS.
bool contains(T, V)(in T[] arr, auto ref const V val)
	if (is(typeof(arr[0]==val)))
{
	return arr.indexOf(val) >= 0;
}

/// Ditto, for substrings
bool contains(T, U)(T[] str, U[] what)
if (is(Unqual!T == Unqual!U))
{
	return str._indexOf(what) >= 0;
}

debug(ae_unittest) unittest
{
	assert( "abc".contains('b'));
	assert(!"abc".contains('x'));
	assert( "abc".contains("b"));
	assert(!"abc".contains("x"));
}

/// Like startsWith, but with an offset.
bool containsAt(T)(in T[] haystack, in T[] needle, size_t offset)
{
	return haystack.length >= offset + needle.length
		&& haystack[offset..offset+needle.length] == needle;
}

debug(ae_unittest) unittest
{
	assert( "abracadabra".containsAt("ada", 5));
	assert(!"abracadabra".containsAt("ada", 6));
	assert(!"abracadabra".containsAt("ada", 99));
}

/// Returns `true` if one of the elements of `arr` contains `val`.
bool isIn(T)(T val, in T[] arr)
{
	return arr.contains(val);
}

/// Returns `true` if one of the elements of `arr` contains `val`.
bool isOneOf(T)(T val, T[] arr...)
{
	return arr.contains(val);
}

/// Like AA.get - soft indexing, throws an
/// Exception (not an Error) on out-of-bounds,
/// even in release builds.
ref T get(T)(T[] arr, size_t index)
{
	enforce(index < arr.length, "Out-of-bounds array access");
	return arr[index];
}

/// Like AA.get - soft indexing, returns
/// default value on out-of-bounds.
auto get(T)(T[] arr, size_t index, auto ref T defaultValue)
{
	if (index >= arr.length)
		return defaultValue;
	return arr[index];
}

/// Expand the array if index is out-of-bounds.
ref T getExpand(T)(ref T[] arr, size_t index)
{
	if (index >= arr.length)
		arr.length = index + 1;
	return arr[index];
}

/// ditto
ref T putExpand(T)(ref T[] arr, size_t index, auto ref T value)
{
	if (index >= arr.length)
		arr.length = index + 1;
	return arr[index] = value;
}

/// Slices an array. Throws an Exception (not an Error)
/// on out-of-bounds, even in release builds.
T[] slice(T)(T[] arr, size_t p0, size_t p1)
{
	enforce(p0 < p1 && p1 < arr.length, "Out-of-bounds array slice");
	return arr[p0..p1];
}

/// Given an array and a reference to an element,
/// return whether the array slices over the element reference.
bool slicesOver(T)(const(T)[] arr, ref const T element)
{
	auto start = arr.ptr;
	auto end = start + arr.length;
	auto p = &element;
	return start <= p && p < end;
}

/// Given an array and a reference to an element inside it, returns its index.
/// The reverse operation of indexing an array.
size_t elementIndex(T)(const(T)[] arr, ref const T element) @trusted
{
	auto start = arr.ptr;
	auto end = start + arr.length;
	auto p = &element;
	assert(start <= p && p < end, "Element is not in array");
	return p - start;
}

debug(ae_unittest) @safe unittest
{
	auto arr = [1, 2, 3];
	assert(arr.elementIndex(arr[1]) == 1);
}

/// Given an array and its slice, returns the
/// start index of the slice inside the array.
/// The reverse operation of slicing an array.
size_t sliceIndex(T)(in T[] arr, in T[] slice) @trusted
{
	auto a = arr.ptr;
	auto b = a + arr.length;
	auto p = slice.ptr;
	assert(a <= p && p <= b, "Out-of-bounds array slice");
	return p - a;
}

/// Like std.array.split, but returns null if val was empty.
auto splitEmpty(T, S)(T value, S separator)
{
	return value.length ? split(value, separator) : null;
}

/// Like std.array.split, but always returns a non-empty array.
auto split1(T, S)(T value, S separator)
{
	auto result = split(value, separator);
	return result.length ? result : [value];
}

/// Include delimiter in result chunks as suffix
H[] splitWithSuffix(H, S)(H haystack, S separator)
{
	H[] result;
	while (haystack.length)
	{
		auto pos = haystack._indexOf(separator);
		if (pos < 0)
			pos = haystack.length;
		else
		{
			static if (is(typeof(haystack[0] == separator)))
				pos += 1;
			else
			static if (is(typeof(haystack[0..1] == separator)))
				pos += separator.length;
			else
				static assert(false, "Don't know how to split " ~ H.stringof ~ " by " ~ S.stringof);
		}
		result ~= haystack[0..pos];
		haystack = haystack[pos..$];
	}
	return result;
}

debug(ae_unittest) unittest
{
	assert("a\nb".splitWithSuffix('\n') == ["a\n", "b"]);
	assert([1, 0, 2].splitWithSuffix(0) == [[1, 0], [2]]);

	assert("a\r\nb".splitWithSuffix("\r\n") == ["a\r\n", "b"]);
	assert([1, 0, 0, 2].splitWithSuffix([0, 0]) == [[1, 0, 0], [2]]);
}

/// Include delimiter in result chunks as prefix
H[] splitWithPrefix(H, S)(H haystack, S separator)
{
	H[] result;
	while (haystack.length)
	{
		auto pos = haystack[1..$]._indexOf(separator);
		if (pos < 0)
			pos = haystack.length;
		else
			pos++;
		result ~= haystack[0..pos];
		haystack = haystack[pos..$];
	}
	return result;
}

debug(ae_unittest) unittest
{
	assert("a\nb".splitWithPrefix('\n') == ["a", "\nb"]);
	assert([1, 0, 2].splitWithPrefix(0) == [[1], [0, 2]]);

	assert("a\r\nb".splitWithPrefix("\r\n") == ["a", "\r\nb"]);
	assert([1, 0, 0, 2].splitWithPrefix([0, 0]) == [[1], [0, 0, 2]]);
}

/// Include delimiters in result chunks as prefix/suffix
S[] splitWithPrefixAndSuffix(S)(S haystack, S prefix, S suffix)
{
	S[] result;
	auto separator = suffix ~ prefix;
	while (haystack.length)
	{
		auto pos = haystack._indexOf(separator);
		if (pos < 0)
			pos = haystack.length;
		else
			pos += suffix.length;
		result ~= haystack[0..pos];
		haystack = haystack[pos..$];
	}
	return result;
}

///
debug(ae_unittest) unittest
{
	auto s = q"EOF
Section 1:
10
11
12
Section 2:
21
22
23
Section 3:
31
32
33
EOF";
	auto parts = s.splitWithPrefixAndSuffix("Section ", "\n");
	assert(parts.length == 3 && parts.join == s);
	foreach (part; parts)
		assert(part.startsWith("Section ") && part.endsWith("\n"));
}

/// Ensure that arr is non-null if empty.
T[] nonNull(T)(T[] arr)
{
	if (arr !is null)
		return arr;
	return emptySlice!(typeof(arr[0]));
}

/// If arr is null, return null. Otherwise, return a non-null
/// transformation dg over arr.
template mapNull(alias dg)
{
	auto mapNull(T)(T arr)
	{
		if (arr is null)
			return null;
		return dg(arr).nonNull;
	}
}

debug(ae_unittest) unittest
{
	assert(string.init.mapNull!(s => s          )  is null);
	assert(string.init.mapNull!(s => ""         )  is null);
	assert(""         .mapNull!(s => s          ) !is null);
	assert(""         .mapNull!(s => string.init) !is null);
}

/// Select and return a random element from the array.
auto ref sample(T)(T[] arr)
{
	import std.random;
	return arr[uniform(0, $)];
}

debug(ae_unittest) unittest
{
	assert([7, 7, 7].sample == 7);
	auto s = ["foo", "bar"].sample(); // Issue 13807
	const(int)[] a2 = [5]; sample(a2);
}

/// Select and return a random element from the array,
/// and remove it from the array.
T pluck(T)(ref T[] arr)
{
	import std.random;
	auto pos = uniform(0, arr.length);
	auto result = arr[pos];
	arr = arr.remove(pos);
	return result;
}

debug(ae_unittest) unittest
{
	auto arr = [1, 2, 3];
	auto res = [arr.pluck, arr.pluck, arr.pluck];
	res.sort();
	assert(res == [1, 2, 3]);
}

import std.functional;

/// Remove first matching element in an array, mutating the array.
/// Returns true if the array has been modified.
/// Cf. `K[V].remove(K)`
bool removeFirst(T, alias eq = binaryFun!"a == b", SwapStrategy swapStrategy = SwapStrategy.stable)(ref T[] arr, T elem)
{
	foreach (i, ref e; arr)
		if (eq(e, elem))
		{
			arr = arr.remove!swapStrategy(i);
			return true;
		}
	return false;
}

debug(ae_unittest) unittest
{
	int[] arr = [1, 2, 3, 2];
	arr.removeFirst(2);
	assert(arr == [1, 3, 2]);
}

/// Remove all matching elements in an array, mutating the array.
/// Returns the number of removed elements.
size_t removeAll(T, alias eq = binaryFun!"a == b", SwapStrategy swapStrategy = SwapStrategy.stable)(ref T[] arr, T elem)
{
	auto oldLength = arr.length;
	arr = arr.remove!((ref e) => eq(e, elem));
	return oldLength - arr.length;
}

debug(ae_unittest) unittest
{
	int[] arr = [1, 2, 3, 2];
	arr.removeAll(2);
	assert(arr == [1, 3]);
}

/// Sorts `arr` in-place using counting sort.
/// The difference between the lowest and highest
/// return value of `orderPred(arr[i])` shouldn't be too big.
void countSort(alias orderPred = "a", T)(T[] arr, ref T[] valuesBuf, ref size_t[] countsBuf)
{
	alias getIndex = unaryFun!orderPred;
	alias Index = typeof(getIndex(arr[0]));
	if (arr.length == 0)
		return;
	Index min = getIndex(arr[0]);
	Index max = min;
	foreach (ref el; arr[1..$])
	{
		Index i = getIndex(el);
		if (min > i)
			min = i;
		if (max < i)
			max = i;
	}

	auto n = max - min + 1;
	if (valuesBuf.length < n)
		valuesBuf.length = n;
	auto values = valuesBuf[0 .. n];
	if (countsBuf.length < n)
		countsBuf.length = n;
	auto counts = countsBuf[0 .. n];

	foreach (el; arr)
	{
		auto i = getIndex(el) - min;
		values[i] = el;
		counts[i]++;
	}

	size_t p = 0;
	foreach (i; 0 .. n)
	{
		auto count = counts[i];
		arr[p .. p + count] = values[i];
		p += count;
	}
	assert(p == arr.length);
}

void countSort(alias orderPred = "a", T)(T[] arr)
{
	static size_t[] countsBuf;
	static T[] valuesBuf;
	countSort!orderPred(arr, valuesBuf, countsBuf);
} /// ditto

debug(ae_unittest) unittest
{
	auto arr = [3, 2, 5, 2, 1];
	arr.countSort();
	assert(arr == [1, 2, 2, 3, 5]);
}

// ***************************************************************************

/// Push `val` into `arr`, treating it like a stack.
void stackPush(T)(ref T[] arr, auto ref T val)
{
	arr ~= val;
}

/// Push `val` into `arr`, treating it like a queue.
alias stackPush queuePush;

/// Peek at the front of `arr`, treating it like a stack.
ref T stackPeek(T)(T[] arr) { return arr[$-1]; }

/// Pop a value off the front of `arr`, treating it like a stack.
ref T stackPop(T)(ref T[] arr)
{
	auto ret = &arr[$-1];
	arr = arr[0..$-1];
	return *ret;
}

/// Peek at the front of `arr`, treating it like a queue.
ref T queuePeek(T)(T[] arr) { return arr[0]; }

/// Peek at the back of `arr`, treating it like a queue.
ref T queuePeekLast(T)(T[] arr) { return arr[$-1]; }

/// Pop a value off the front of `arr`, treating it like a queue.
ref T queuePop(T)(ref T[] arr)
{
	auto ret = &arr[0];
	arr = arr[1..$];
	if (!arr.length) arr = null;
	return *ret;
}

/// Remove the first element of `arr` and return it.
ref T shift(T)(ref T[] arr) { auto oldArr = arr; arr = arr[1..$]; return oldArr[0]; }

/// Remove the `n` first elements of `arr` and return them.
T[] shift(T)(ref T[] arr, size_t n) { T[] result = arr[0..n]; arr = arr[n..$]; return result; }
T[N] shift(size_t N, T)(ref T[] arr) { T[N] result = cast(T[N])(arr[0..N]); arr = arr[N..$]; return result; } /// ditto

/// Insert elements in the front of `arr`.
void unshift(T)(ref T[] arr, T value) { arr.insertInPlace(0, value); }
void unshift(T)(ref T[] arr, T[] value) { arr.insertInPlace(0, value); } /// ditto

debug(ae_unittest) unittest
{
	int[] arr = [1, 2, 3];
	assert(arr.shift == 1);
	assert(arr == [2, 3]);
	assert(arr.shift(2) == [2, 3]);
	assert(arr == []);

	arr = [3];
	arr.unshift([1, 2]);
	assert(arr == [1, 2, 3]);
	arr.unshift(0);
	assert(arr == [0, 1, 2, 3]);

	assert(arr.shift!2 == [0, 1]);
	assert(arr == [2, 3]);
}

/// If arr starts with prefix, slice it off and return true.
/// Otherwise leave arr unchaned and return false.
deprecated("Use std.algorithm.skipOver instead")
bool eat(T)(ref T[] arr, T[] prefix)
{
	if (arr.startsWith(prefix))
	{
		arr = arr[prefix.length..$];
		return true;
	}
	return false;
}

// Overload disambiguator
private sizediff_t _indexOf(H, N)(H haystack, N needle)
{
	static import std.string;

	static if (is(typeof(ae.utils.array.indexOf(haystack, needle))))
		alias indexOf = ae.utils.array.indexOf;
	else
	static if (is(typeof(std.string.indexOf(haystack, needle))))
		alias indexOf = std.string.indexOf;
	else
		static assert(false, "No suitable indexOf overload found");
	return indexOf(haystack, needle);
}

/// Returns the slice of source up to the first occurrence of delim,
/// and fast-forwards source to the point after delim.
/// If delim is not found, the behavior depends on orUntilEnd:
/// - If orUntilEnd is false (default), it returns null
///   and leaves source unchanged.
/// - If orUntilEnd is true, it returns source,
///   and then sets source to null.
T[] skipUntil(T, D)(ref T[] source, D delim, bool orUntilEnd = false)
{
	enum bool isSlice = is(typeof(source[0..1]==delim));
	enum bool isElem  = is(typeof(source[0]   ==delim));
	static assert(isSlice || isElem, "Can't skip " ~ T.stringof ~ " until " ~ D.stringof);
	static assert(isSlice != isElem, "Ambiguous types for skipUntil: " ~ T.stringof ~ " and " ~ D.stringof);
	static if (isSlice)
		auto delimLength = delim.length;
	else
		enum delimLength = 1;

	auto i = _indexOf(source, delim);
	if (i < 0)
	{
		if (orUntilEnd)
		{
			auto result = source;
			source = null;
			return result;
		}
		else
			return null;
	}
	auto result = source[0..i];
	source = source[i+delimLength..$];
	return result;
}

/// Like `std.algorithm.skipOver`, but stops when
/// `pred(suffix)` or `pred(suffix[0])` returns false.
template skipWhile(alias pred)
{
	T[] skipWhile(T)(ref T[] source, bool orUntilEnd = false)
	{
		enum bool isSlice = is(typeof(pred(source[0..1])));
		enum bool isElem  = is(typeof(pred(source[0]   )));
		static assert(isSlice || isElem, "Can't skip " ~ T.stringof ~ " until " ~ pred.stringof);
		static assert(isSlice != isElem, "Ambiguous types for skipWhile: " ~ T.stringof ~ " and " ~ pred.stringof);

		foreach (i; 0 .. source.length)
		{
			bool match;
			static if (isSlice)
				match = pred(source[i .. $]);
			else
				match = pred(source[i]);
			if (!match)
			{
				auto result = source[0..i];
				source = source[i .. $];
				return result;
			}
		}

		if (orUntilEnd)
		{
			auto result = source;
			source = null;
			return result;
		}
		else
			return null;
	}
}

debug(ae_unittest) unittest
{
	import std.ascii : isDigit;

	string s = "01234abcde";
	auto p = s.skipWhile!isDigit;
	assert(p == "01234" && s == "abcde", p ~ "|" ~ s);
}

deprecated("Use skipUntil instead")
enum OnEof { returnNull, returnRemainder, throwException }

deprecated("Use skipUntil instead")
template eatUntil(OnEof onEof = OnEof.throwException)
{
	T[] eatUntil(T, D)(ref T[] source, D delim)
	{
		static if (onEof == OnEof.returnNull)
			return skipUntil(source, delim, false);
		else
		static if (onEof == OnEof.returnRemainder)
			return skipUntil(source, delim, true);
		else
			return skipUntil(source, delim, false).enforce("Delimiter not found in source");
	}
}

debug(ae_unittest) deprecated unittest
{
	string s;

	s = "Mary had a little lamb";
	assert(s.eatUntil(" ") == "Mary");
	assert(s.eatUntil(" ") == "had");
	assert(s.eatUntil(' ') == "a");

	assertThrown!Exception(s.eatUntil("#"));
	assert(s.eatUntil!(OnEof.returnNull)("#") is null);
	assert(s.eatUntil!(OnEof.returnRemainder)("#") == "little lamb");

	ubyte[] bytes = [1, 2, 0, 3, 4, 0, 0];
	assert(bytes.eatUntil(0) == [1, 2]);
	assert(bytes.eatUntil([ubyte(0), ubyte(0)]) == [3, 4]);
}

// ***************************************************************************

/// Equivalents of `array(xxx(...))`.
template amap(alias pred)
{
	auto amap(R)(R range)
	if (isInputRange!R && hasLength!R)
	{
		import core.memory : GC;
		import core.lifetime : emplace;
		alias T = typeof(unaryFun!pred(range.front));
		auto result = (() @trusted => uninitializedArray!(Unqual!T[])(range.length))();
		foreach (i; 0 .. range.length)
		{
			auto value = cast()unaryFun!pred(range.front);
			(() @trusted { moveEmplace(value, result[i]); })();
			range.popFront();
		}
		assert(range.empty);
		return (() @trusted => cast(T[])result)();
	}

	/// Like `amap` but with a static array.
	auto amap(T, size_t n)(T[n] arr)
	{
		alias R = typeof(unaryFun!pred(arr[0]));
		R[n] result;
		foreach (i, ref r; result)
			r = unaryFun!pred(arr[i]);
		return result;
	}
}
template afilter(alias pred) { auto afilter(T)(T[] arr) { return array(filter!pred(arr)); } } /// ditto
auto auniq(T)(T[] arr) { return array(uniq(arr)); } /// ditto
auto asort(alias pred, T)(T[] arr) { sort!pred(arr); return arr; } /// ditto

debug(ae_unittest) @safe unittest
{
	assert([1, 2, 3].amap!`a*2`() == [2, 4, 6]);
	assert([1, 2, 3].amap!(n => n*n)() == [1, 4, 9]);
	assert([1, 2, 3].staticArray.amap!(n => n*n)() == [1, 4, 9].staticArray);
}

debug(ae_unittest) @safe unittest
{
	struct NC
	{
		int i;
		@disable this();
		this(int i) { this.i = i; }
		@disable this(this);
	}

	import std.range : iota;
	assert(3.iota.amap!(i => NC(i))[1].i == 1);
}

debug(ae_unittest) @safe unittest
{
	import std.range : iota;
	immutable(int)[] arr;
	arr = 3.iota.amap!(i => cast(immutable)i);
	assert(arr[1] == 1);
}

// ***************************************************************************

/// Array with normalized comparison and hashing.
/// Params:
///   T = array element type to wrap.
///   normalize = function which should return a range of normalized elements.
struct NormalizedArray(T, alias normalize)
{
	T[] arr; /// Underlying array.

	this(T[] arr) { this.arr = arr; } ///

	int opCmp    (in T[]                 other) const { return std.algorithm.cmp(normalize(arr), normalize(other    ))   ; } ///
	int opCmp    (    const typeof(this) other) const { return std.algorithm.cmp(normalize(arr), normalize(other.arr))   ; } ///
	int opCmp    (ref const typeof(this) other) const { return std.algorithm.cmp(normalize(arr), normalize(other.arr))   ; } ///
	bool opEquals(in T[]                 other) const { return std.algorithm.cmp(normalize(arr), normalize(other    ))==0; } ///
	bool opEquals(    const typeof(this) other) const { return std.algorithm.cmp(normalize(arr), normalize(other.arr))==0; } ///
	bool opEquals(ref const typeof(this) other) const { return std.algorithm.cmp(normalize(arr), normalize(other.arr))==0; } ///

	private hash_t toHashReal() const
	{
		import std.digest.crc;
		CRC32 crc;
		foreach (c; normalize(arr))
			crc.put(cast(ubyte[])((&c)[0..1]));
		static union Result { ubyte[4] crcResult; hash_t hash; }
		return Result(crc.finish()).hash;
	}

	hash_t toHash() const nothrow @trusted
	{
		return (cast(hash_t delegate() nothrow @safe)&toHashReal)();
	} ///
}

// ***************************************************************************

/// Equivalent of PHP's `list` language construct:
/// http://php.net/manual/en/function.list.php
/// Works with arrays and tuples.
/// Specify `null` as an argument to ignore that index
/// (equivalent of `list(x, , y)` in PHP).
auto list(Args...)(auto ref Args args)
{
	struct List
	{
		auto dummy() { return args[0]; } // https://issues.dlang.org/show_bug.cgi?id=11886
		void opAssign(T)(auto ref T t)
		{
			assert(t.length == args.length,
				"Assigning %d elements to list with %d elements"
				.format(t.length, args.length));
			foreach (i; rangeTuple!(Args.length))
				static if (!is(Args[i] == typeof(null)))
					args[i] = t[i];
		}
	}
	return List();
}

///
debug(ae_unittest) unittest
{
	string name, value;
	list(name, null, value) = "NAME=VALUE".findSplit("=");
	assert(name == "NAME" && value == "VALUE");
}

version(LittleEndian)
debug(ae_unittest) unittest
{
	uint onlyValue;
	ubyte[] data = [ubyte(42), 0, 0, 0];
	list(onlyValue) = cast(uint[])data;
	assert(onlyValue == 42);
}
