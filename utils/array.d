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

public import ae.utils.aa;
public import ae.utils.appender;

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

/// Return arr until the first instance of separator (excluding it),
/// and set arr to the remaining part (again, excluding the separator).
/// Throws if the separator is not found.
T[] eatUntil(T)(ref T[] arr, T[] separator)
{
	import std.exception;
	import std.string;

	auto p = arr.countUntil(separator);
	enforce(p >= 0, "%s not found in %s".format(separator, arr));
	auto result = arr[0..p];
	arr = arr[p+separator.length..$];
	return result;
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
