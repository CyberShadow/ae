/**
 * Associative Array utility functions
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

module ae.utils.aa;

import std.algorithm;

// ***************************************************************************

/// Get a value from an AA, and throw an exception (not an error) if not found
ref V aaGet(K, V)(V[K] aa, K key)
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

/// If key is not in aa, add it with defaultValue.
/// Returns a reference to the value corresponding to key.
ref V getOrAdd(K, V)(ref V[K] aa, K key, V defaultValue = V.init)
{
	auto p = key in aa;
	if (!p)
	{
		aa[key] = defaultValue;
		p = key in aa;
	}
	return *p;
}

unittest
{
	int[int] aa;
	aa.getOrAdd(1, 2) = 3;
	assert(aa[1] == 3);
	assert(aa.getOrAdd(1, 4) == 3);
}

struct KeyValuePair(K, V) { K key; V value; }

/// Get key/value pairs from AA
KeyValuePair!(K, V)[] pairs(K, V)(V[K] aa)
{
	KeyValuePair!(K, V)[] result;
	foreach (key, value; aa)
		result ~= KeyValuePair!(K, V)(key, value);
	return result;
}

/// Get key/value pairs from AA, sorted by keys
KeyValuePair!(K, V)[] sortedPairs(K, V)(V[K] aa)
{
	KeyValuePair!(K, V)[] result;
	foreach (key; aa.keys.sort)
		result ~= KeyValuePair!(K, V)(key, aa[key]);
	return result;
}

/// Get values from AA, sorted by keys
V[] sortedValues(K, V)(V[K] aa)
{
	V[] result;
	foreach (key; aa.keys.sort)
		result ~= aa[key];
	return result;
}

/// Merge b into a. Return a.
V[K] merge(K, V)(V[K] a, V[K] b)
{
	foreach (k, v; b)
		a[k] = v;
	return a;
}

// ***************************************************************************

/// An associative array which retains the order in which elements were added.
struct OrderedMap(K, V)
{
	K[] keys;
	V[] values;
	size_t[K] index;

	ref V opIndex(ref K k)
	{
		return values[index[k]];
	}

	ref V opIndexAssign()(auto ref V v, auto ref K k)
	{
		auto pi = k in index;
		if (pi)
		{
			auto pv = &values[*pi];
			*pv = v;
			return *pv;
		}

		index[k] = values.length;
		keys ~= k;
		values ~= v;
		return values[$-1];
	}

	void remove()(auto ref K k)
	{
		auto i = index[k];
		index.remove(k);
		keys = keys.remove(i);
		values = values.remove(i);
	}

	@property size_t length() { return values.length; }

	int opApply(int delegate(ref K k, ref V v) dg)
	{
		int result = 0;

		foreach (i, ref v; values)
		{
			result = dg(keys[i], v);
			if (result)
				break;
		}
		return result;
	}
}

unittest
{
	OrderedMap!(string, int) m;
	m["a"] = 1;
	m["b"] = 2;
	m["c"] = 3;
	assert(m.length == 3);
	m.remove("a");
	assert(m.length == 2);
}

// ***************************************************************************

/// Helper/wrapper for void[0][T]
struct HashSet(T)
{
	void[0][T] data;

	alias data this;

	this(R)(R r)
	{
		foreach (k; r)
			add(k);
	}

	void add(T k)
	{
		void[0] v;
		data[k] = v;
	}

	void remove(T k)
	{
		data.remove(k);
	}

	@property HashSet!T dup() const
	{
		// Can't use .dup with void[0] value
		HashSet!T result;
		foreach (k, v; data)
			result.add(k);
		return result;
	}

	int opApply(scope int delegate(ref T) dg)
	{
		int result;
		foreach (k, v; data)
			if ((result = dg(k)) != 0)
				break;
		return result;
	}
}

unittest
{
	HashSet!int s;
	assert(s.length == 0);
	assert(!(1 in s));
	assert(1 !in s);
	s.add(1);
	assert(1 in s);
	assert(s.length == 1);
	foreach (k; s)
		assert(k == 1);
	s.remove(1);
	assert(s.length == 0);

	s.add(1);
	auto t = s.dup;
	s.add(2);
	assert(t.length==1);
	t.remove(1);
	assert(t.length==0);
}
