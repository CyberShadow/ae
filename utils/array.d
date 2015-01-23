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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.array;

import std.exception;
import std.traits;

public import ae.utils.aa;
public import ae.utils.appender;

/// Slice a variable.
T[] toArray(T)(ref T v)
{
	return (&v)[0..1];
}

/// Return the value represented as an array of bytes.
@property inout(ubyte)[] bytes(T)(ref inout(T) value)
	if (!(is(T == class) || isDynamicArray!T))
{
	return value.toArray().bytes;
}

/// ditto
@property inout(ubyte)[] bytes(T)(inout(T) value)
	if ( (is(T == class) || isDynamicArray!T))
{
	static if (is(T U : U[]))
		return cast(inout(ubyte)[])value;
	else
		return (cast(inout(ubyte)*)value)[0..__traits(classInstanceSize, T)];
}

unittest
{
	ubyte b = 5;
	assert(b.bytes == [5]);

	struct S { ubyte b = 5; }
	S s;
	assert(s.bytes == [5]);

	ubyte[1] sa = [5];
	assert(sa.bytes == [5]);
}

int memcmp(in ubyte[] a, in ubyte[] b)
{
	import core.stdc.string;
	assert(a.length == b.length);
	return memcmp(a.ptr, b.ptr, a.length);
}

/// Like std.algorithm.copy, but without the auto-decode bullshit.
/// https://issues.dlang.org/show_bug.cgi?id=13650
void memmove(T)(T[] dst, in T[] src)
{
	import core.stdc.string;
	assert(src.length == dst.length);
	memmove(dst.ptr, src.ptr, dst.length * T.sizeof);
}

T[] vector(string op, T)(T[] a, T[] b)
{
	assert(a.length == b.length);
	T[] result = new T[a.length];
	foreach (i, ref r; result)
		r = mixin("a[i]" ~ op ~ "b[i]");
	return result;
}

T[] vectorAssign(string op, T)(T[] a, T[] b)
{
	assert(a.length == b.length);
	foreach (i, ref r; a)
		mixin("r " ~ op ~ "= b[i];");
	return a;
}

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

T[] repeatOne(T)(T c, size_t l)
{
	T[] result = new T[l];
	result[] = c;
	return result;
}

bool contains(T, V)(T[] arr, V val)
	if (is(typeof(arr[0]==val)))
{
	foreach (v; arr)
		if (v == val)
			return true;
	return false;
}

bool isIn(T)(T val, in T[] arr)
{
	return arr.contains(val);
}

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
	if (index >= arr)
		return defaultValue;
	return arr[index];
}

/// Slices an array. Throws an Exception (not an Error)
/// on out-of-bounds, even in release builds.
T[] slice(T)(T[] arr, size_t p0, size_t p1)
{
	enforce(p0 < p1 && p1 < arr.length, "Out-of-bounds array slice");
	return arr[p0..p1];
}

import std.random;

/// Select and return a random element from the array.
auto ref sample(T)(T[] arr)
{
	return arr[uniform(0, $)];
}

unittest
{
	assert([7, 7, 7].sample == 7);
	auto s = ["foo", "bar"].sample(); // Issue 13807
	const(int)[] a2 = [5]; sample(a2);
}

/// Select and return a random element from the array,
/// and remove it from the array.
T pluck(T)(ref T[] arr)
{
	auto pos = uniform(0, arr.length);
	auto result = arr[pos];
	arr = arr.remove(pos);
	return result;
}

unittest
{
	auto arr = [1, 2, 3];
	auto res = [arr.pluck, arr.pluck, arr.pluck];
	res.sort();
	assert(res == [1, 2, 3]);
}

import std.functional;

T[] countSort(alias value = "a", T)(T[] arr)
{
	alias unaryFun!value getValue;
	alias typeof(getValue(arr[0])) V;
	if (arr.length == 0) return arr;
	V min = getValue(arr[0]), max = getValue(arr[0]);
	foreach (el; arr[1..$])
	{
		auto v = getValue(el);
		if (min > v)
			min = v;
		if (max < v)
			max = v;
	}
	auto n = max-min+1;
	auto counts = new size_t[n];
	foreach (el; arr)
		counts[getValue(el)-min]++;
	auto indices = new size_t[n];
	foreach (i; 1..n)
		indices[i] = indices[i-1] + counts[i-1];
	T[] result = new T[arr.length];
	foreach (el; arr)
		result[indices[getValue(el)-min]++] = el;
	return result;
}

// ***************************************************************************

void stackPush(T)(ref T[] arr, T val)
{
	arr ~= val;
}
alias stackPush queuePush;

T stackPeek(T)(T[] arr) { return arr[$-1]; }

T stackPop(T)(ref T[] arr)
{
	auto ret = arr[$-1];
	arr = arr[0..$-1];
	return ret;
}

T queuePeek(T)(T[] arr) { return arr[0]; }

T queuePeekLast(T)(T[] arr) { return arr[$-1]; }

T queuePop(T)(ref T[] arr)
{
	auto ret = arr[0];
	arr = arr[1..$];
	if (!arr.length) arr = null;
	return ret;
}

T shift(T)(ref T[] arr) { T result = arr[0]; arr = arr[1..$]; return result; }
void unshift(T)(ref T[] arr, T value) { arr.insertInPlace(0, value); }

/// If arr starts with prefix, slice it off and return true.
/// Otherwise leave arr unchaned and return false.
bool eat(T)(ref T[] arr, T[] prefix)
{
	if (arr.startsWith(prefix))
	{
		arr = arr[prefix.length..$];
		return true;
	}
	return false;
}

enum OnEof { returnNull, returnRemainder, throwException }

template eatUntil(OnEof onEof = OnEof.throwException)
{
	T[] eatUntil(T, D)(ref T[] source, D delim)
	{
		auto parts = source.findSplit(delim);
		if (!parts[1].length)
		{
			if (onEof == OnEof.returnNull)
				return null;
			else
			if (onEof == OnEof.returnRemainder)
			{
				auto result = source;
				source = null;
				return result;
			}
			else
				//throw new Exception("%s not found in %s".format(delim, source));
				throw new Exception("Delimiter not found in source");
		}
		source = parts[2];
		return parts[0];
	}
}

unittest
{
	string s;

	s = "Mary had a little lamb";
	assert(s.eatUntil(" ") == "Mary");
	assert(s.eatUntil(" ") == "had");
	assert(s.eatUntil(" ") == "a");

	assertThrown!Exception(s.eatUntil("#"));
	assert(s.eatUntil!(OnEof.returnNull)("#") is null);
	assert(s.eatUntil!(OnEof.returnRemainder)("#") == "little lamb");
}

// ***************************************************************************

import std.algorithm;
import std.array;

// Equivalents of array(xxx(...)), but less parens and UFCS-able.
auto amap(alias pred, T)(T[] arr) { return array(map!pred(arr)); }
auto afilter(alias pred, T)(T[] arr) { return array(filter!pred(arr)); }
auto auniq(T)(T[] arr) { return array(uniq(arr)); }
auto asort(alias pred, T)(T[] arr) { sort!pred(arr); return arr; }

unittest
{
	assert([1, 2, 3].amap!`a*2`() == [2, 4, 6]);
	assert([1, 2, 3].amap!(n => n*n)() == [1, 4, 9]);
}
