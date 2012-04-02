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

bool inArray(T)(T[] arr, T val)
{
	foreach (v; arr)
		if (v == val)
			return true;
	return false;
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

/// Get a value from an AA, and throw an exception (not an error) if not found
V aaGet(K, V)(V[K] aa, K key)
{
	import std.conv;

	auto p = key in aa;
	if (p)
		return *p;
	else
		static if (is(typeof(text(key))))
			throw new Exception("Absent value: " ~ text(key));
		else
			throw new Exception("Absent value");
}

/// Get a value from an AA, with a fallback default value
V aaGet(K, V)(V[K] aa, K key, V def)
{
	auto p = key in aa;
	if (p)
		return *p;
	else
		return def;
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

T queuePop(T)(ref T[] arr)
{
	auto ret = arr[0];
	arr = arr[1..$];
	if (!arr.length) arr = null;
	return ret;
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
