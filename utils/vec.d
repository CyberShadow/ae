/**
 * An std::vector-like type for deterministic lifetime.
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

module ae.utils.vec;

import core.lifetime : move, moveEmplace, copyEmplace;

import std.array;
import std.meta : allSatisfy;

/*
  An array type with deterministic lifetime.

  Properties:
  - Owns its data
  - Not implicitly copyable
    - Use pointers / `ref` or `opSlice` to avoid copying
    - Use `.dup` to copy explicitly
    - Use `std.typecons.RefCounted` for reference counting
  - If destroyed, will destroy (clobber) its contents
  - O(1) indexing

  Differences from `std.containers.array.Array`:
  - Memory-safe
  - Like D arrays, has an initial null state (distinct from the empty state)
  - No reference counting
  - Uses the D GC heap
  - Separates object lifetime from memory lifetime:
    the latter is still managed by the GC,
    so `Vec` is always memory-safe regardless of how you try to (mis-)use it

  Usage notes:
  - If the type has a destructor, it must be valid to
    call it on the `.init` value.
  - `Vec` allows slicing and `ref` access to its members.
    Due to this, stale pointers do not result in UB;
    they will simply point to a default value (`.init`).
*/
struct Vec(T)
{
	private enum elementsHaveDefaultValue = is(typeof({ T t; }));
	private enum elementsAreCopyable = is(typeof({ T t = void; T u = t; }));

	// Lifetime

	/// Construct from a list or slice of values
	static if (elementsAreCopyable)
	this(scope T[] values...)
	{
		data = values.dup;
	}

	private enum bool isConstituent(C) = is(C == T) || is(C == T[]) || is(C == Vec!T);

	/// Construct from any combination of values, slices of values, or
	/// other `Vec` instances
	this(Args...)(auto ref scope Args args)
	if (allSatisfy!(isConstituent, Args))
	{
		size_t length;
		foreach (ref arg; args)
			static if (is(typeof(arg) == T))
				length++;
			else
				length += arg.length;
		data = new T[length];
		size_t p = 0;
		foreach (ref arg; args)
			static if (is(typeof(arg) == T))
				data[p++] = arg;
			else
			{
				static if (is(typeof(arg) == Vec!T))
					data[p .. p + arg.length] = arg.data[];
				else
					data[p .. p + arg.length] = arg[];
				p += arg.length;
			}
	}

	/// To avoid performance pitfalls, implicit copying is disabled.
	/// Use `.dup` instead.
	@disable this(this);

	/// Create a shallow copy of this `Vec`.
	static if (elementsAreCopyable)
	Vec!T dup()
	{
		typeof(return) result;
		result.data = data.dup;
		return result;
	}

	~this()
	{
		data[] = T.init;
		data = null;
	}

	/// Array primitives

	private void ensureCapacity(size_t newCapacity)
	out(; data.capacity >= newCapacity)
	{
		if (newCapacity > data.capacity)
		{
			T[] newData;
			newData.reserve(newCapacity);
			assert(newData.capacity >= newCapacity);
			newData = newData.ptr[0 .. data.length];
			newData.assumeSafeAppend();
			foreach (i; 0 .. data.length)
				moveEmplace(data[i], newData[i]);
			data = newData[0 .. data.length];
		}
	}

	private T[] extendUninitialized(size_t howMany)
	out(result; result.length == howMany)
	{
		auto oldLength = data.length;
		auto newLength = oldLength + howMany;
		ensureCapacity(newLength);
		data = data.ptr[0 .. newLength];
		return data[oldLength .. newLength];
	}

	@property size_t length() const { return data.length; }
	alias opDollar = length; /// ditto

	static if (elementsHaveDefaultValue)
	@property size_t length(size_t newLength)
	{
		if (newLength < data.length)
		{
			data[newLength .. $] = T.init;
			data = data[0 .. newLength];
		}
		else
		if (newLength > data.length)
		{
			ensureCapacity(newLength);
			auto newData = data;
			newData.length = newLength;
			assert(newData.ptr == data.ptr);
			data = newData;
		}
		return data.length;
	} /// ditto

	T opCast(T)() const if (is(T == bool))
	{
		return !!data;
	} /// ditto

	ref inout(T) opIndex(size_t index) inout
	{
		return data[index];
	} /// ditto

	typeof(null) opAssign(typeof(null)) { data[] = T.init; data = null; return null; } /// ditto

	static if (elementsAreCopyable)
	ref Vec opOpAssign(string op : "~")(scope T[] values...)
	{
		foreach (i, ref target; extendUninitialized(values.length))
			copyEmplace(values[i], target);
		return this;
	} /// ditto

	static if (!elementsAreCopyable)
	ref Vec opOpAssign(string op : "~")(T value)
	{
		moveEmplace(value, extendUninitialized(1)[0]);
		return this;
	} /// ditto

	/// Range-like primitives

	@property bool empty() const { return !data.length; }

	ref inout(T) front() inout { return data[0]; } /// ditto
	ref inout(T) back() inout { return data[$-1]; } /// ditto

	void popFront()
	{
		data[0] = T.init;
		data = data[1 .. $];
	} /// ditto

	void popBack()
	{
		data[$-1] = T.init;
		data = data[0 .. $-1];
	} /// ditto

	// Other operations

	/// Return a slice of the held items.
	/// Ownership is unaffected, so this is a "view" into the contents.
	/// Can be used to perform range operations and iteration.
	inout(T)[] opSlice() inout
	{
		return data;
	}

	/// Remove the element with the given `index`, shifting all
	/// elements after it to the left.
	void remove(size_t index)
	{
		foreach (i; index + 1 .. data.length)
			move(data[i], data[i - 1]);
		data = data[0 .. $ - 1];
	}

private:
	T[] data;
}

// Test object lifetime
debug(ae_unittest) unittest
{
	struct S
	{
		static int numLive;
		bool alive;
		this(bool) { alive = true; numLive++; }
		this(this) { if (alive) numLive++; }
		~this() { if (alive) numLive--; }
	}

	Vec!S v;
	assert(S.numLive == 0);
	v = Vec!S(S(true));
	assert(S.numLive == 1);
	v ~= S(true);
	assert(S.numLive == 2);
	auto v2 = v.dup;
	assert(S.numLive == 4);
	v2 = null;
	assert(S.numLive == 2);
	v.popFront();
	assert(S.numLive == 1);
	v.popBack();
	assert(S.numLive == 0);
}

// Test iteration
debug(ae_unittest) unittest
{
	// Ensure iterating twice over a Vec does not consume it.
	auto v = Vec!int(1, 2, 3);
	foreach (i; v) {}
	int sum;
	foreach (i; v) sum += i;
	assert(sum == 6);
}

// Test non-copyable elements
debug(ae_unittest) unittest
{
	struct S
	{
		@disable this();
		@disable this(this);
		this(int) {}
	}

	Vec!S v;
	v ~= S(1);
}
