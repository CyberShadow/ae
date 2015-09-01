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
import std.range;
import std.typecons;

// ***************************************************************************

/// Get a value from an AA, and throw an exception (not an error) if not found
ref auto aaGet(AA, K)(AA aa, K key)
	if (is(typeof(key in aa)))
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

/// Merge source into target. Return target.
V[K] merge(K, V)(auto ref V[K] target, in V[K] source)
{
	foreach (k, v; source)
		target[k] = v;
	return target;
}

unittest
{
	int[int] target;
	int[int] source = [2:4];
	merge(target, source);
	assert(source == target);

	target = [1:1, 2:2, 3:3];
	merge(target, source);
	assert(target == [1:1, 2:4, 3:3]);

	assert(merge([1:1], [2:2]) == [1:1, 2:2]);
}

/// Slurp a range of two elements (or two-element struct/class) into an AA.
auto toAA(R)(R r)
	if (is(typeof(r.front[1])))
{
	alias K = typeof(r.front[0]);
	alias V = typeof(r.front[1]);
	V[K] result;
	foreach (pair; r)
	{
		assert(pair.length == 2);
		result[pair[0]] = pair[1];
	}
	return result;
}

/// ditto
auto toAA(R)(R r)
	if (is(typeof(r.front.tupleof)) && r.front.tupleof.length == 2 && !is(typeof(r.front[1])))
{
	return r.map!(el => tuple(el.tupleof)).toAA();
}

unittest
{
	assert([[2, 4]].toAA() == [2:4]);
	assert([2:4].pairs.toAA() == [2:4]);
}

// ***************************************************************************

/// An associative array which retains the order in which elements were added.
struct OrderedMap(K, V)
{
	K[] keys;
	V[] values;
	size_t[K] index;

	ref inout(V) opIndex()(auto ref K k) inout
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

	ref V getOrAdd()(auto ref K k)
	{
		auto pi = k in index;
		V* pv;
		if (pi)
			pv = &values[*pi];
		else
		{
			index[k] = values.length;
			keys ~= k;
			values ~= V.init;
			pv = &values[$-1];
		}
		return *pv;
	}

	ref V opIndexUnary(string op)(auto ref K k)
	{
		auto pv = &getOrAdd(k);
		mixin("(*pv) " ~ op ~ ";");
		return *pv;
	}

	ref V opIndexOpAssign(string op)(auto ref V v, auto ref K k)
	{
		auto pv = &getOrAdd(k);
		mixin("(*pv) " ~ op ~ "= v;");
		return *pv;
	}

	inout(V) get()(auto ref K k, inout(V) defaultValue) inout
	{
		auto p = k in index;
		return p ? values[*p] : defaultValue;
	}

	inout(V)* opIn_r()(auto ref K k) inout
	{
		auto p = k in index;
		return p ? &values[*p] : null;
	}

	void remove()(auto ref K k)
	{
		auto i = index[k];
		index.remove(k);
		keys = keys.remove(i);
		values = values.remove(i);
	}

	@property size_t length() const { return values.length; }

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
	assert("a" in m);
	assert("d" !in m);
	m.remove("a");
	assert(m.length == 2);
	m["x"] -= 1;
	assert(m["x"] == -1);
	++m["y"];
	assert(m["y"] == 1);
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

auto toSet(R)(R r)
{
	alias E = ElementType!R;
	return HashSet!E(r);
}

unittest
{
	auto set = [1, 2, 3].toSet();
	assert(2 in set);
	assert(4 !in set);
}

// ***************************************************************************

/// An object which acts mostly as an associative array,
/// with the added property of being able to hold keys with
/// multiple values. These are only exposed explicitly and
/// through iteration
struct MultiAA(K, V)
{
	V[][K] items;

	/// If multiple items with this name are present,
	/// only the first one is returned.
	ref inout(V) opIndex(K key) inout
	{
		return items[key][0];
	}

	V opIndexAssign(V value, K key)
	{
		items[key] = [value];
		return value;
	}

	inout(V)* opIn_r(K key) inout @nogc
	{
		auto pvalues = key in items;
		if (pvalues && (*pvalues).length)
			return &(*pvalues)[0];
		return null;
	}

	void remove(K key)
	{
		items.remove(key);
	}

	// D forces these to be "ref"
	int opApply(int delegate(ref K key, ref V value) dg)
	{
		int ret;
		outer:
		foreach (key, values; items)
			foreach (ref value; values)
			{
				ret = dg(key, value);
				if (ret)
					break outer;
			}
		return ret;
	}

	// Copy-paste because of https://issues.dlang.org/show_bug.cgi?id=7543
	int opApply(int delegate(ref const(K) key, ref const(V) value) dg) const
	{
		int ret;
		outer:
		foreach (key, values; items)
			foreach (ref value; values)
			{
				ret = dg(key, value);
				if (ret)
					break outer;
			}
		return ret;
	}

	void add(K key, V value)
	{
		if (key !in items)
			items[key] = [value];
		else
			items[key] ~= value;
	}

	V get(K key, lazy V def) const
	{
		auto pvalue = key in this;
		return pvalue ? *pvalue : def;
	}

	inout(V)[] getAll(K key) inout
	{
		inout(V)[] result;
		foreach (ref value; items.get(key, null))
			result ~= value;
		return result;
	}

	this(typeof(null) Null)
	{
	}

	this(V[K] aa)
	{
		foreach (ref key, ref value; aa)
			add(key, value);
	}

	this(V[][K] aa)
	{
		foreach (ref key, values; aa)
			foreach (ref value; values)
				add(key, value);
	}

	@property auto keys() inout { return items.keys; }

	// https://issues.dlang.org/show_bug.cgi?id=14626

	@property V[] values()
	{
		return items.byValue.join;
	}

	@property const(V)[] values() const
	{
		return items.byValue.join;
	}

	@property typeof(V[K].init.pairs) pairs()
	{
		alias Pair = typeof(V[K].init.pairs[0]);
		Pair[] result;
		result.reserve(length);
		foreach (ref k, ref v; this)
			result ~= Pair(k, v);
		return result;
	}

	@property size_t length() const { return items.byValue.map!(item => item.length).sum(); }

	auto byKey() { return items.byKey(); }
	auto byValue() { return items.byValue().joiner(); }

	bool opCast(T)() inout
		if (is(T == bool))
	{
		return !!items;
	}

	/// Warning: discards repeating items
	V[K] opCast(T)() const
		if (is(T == V[K]))
	{
		V[K] result;
		foreach (key, value; this)
			result[key] = value;
		return result;
	}

	V[][K] opCast(T)() inout
		if (is(T == V[][K]))
	{
		V[][K] result;
		foreach (k, v; this)
			result[k] ~= v;
		return result;
	}
}

unittest
{
	MultiAA!(string, string) aa;
}
