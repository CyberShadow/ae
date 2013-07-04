/**
 * ae.utils.container
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

module ae.utils.container;

/// Unordered array with O(1) insertion and removal
struct Set(T, uint INITSIZE=64)
{
	T[] data;
	size_t size;

	void opOpAssign(string OP)(T item)
		if (OP=="~")
	{
		if (data.length == size)
			data.length = size ? size * 2 : INITSIZE;
		data[size++] = item;
	}

	void remove(size_t index)
	{
		assert(index < size);
		data[index] = data[--size];
	}

	@property T[] items()
	{
		return data[0..size];
	}
}

unittest
{
	Set!int s;
	s ~= 1;
	s ~= 2;
	s ~= 3;
	assert(s.items == [1, 2, 3]);
	s.remove(1);
	assert(s.items == [1, 3]);
}

// ***************************************************************************

/// Helper/wrapper for void[0][T]
struct HashSet(T)
{
	void[0][T] data;

	alias data this;

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

// ***************************************************************************

import ae.utils.alloc;

mixin template DListCommon(NODEREF)
{
	NODEREF head, tail;

	void add(NODEREF node)
	{
		node.next = null;
		node.prev = tail;
		if (tail !is null)
			tail.next = node;
		tail = node;
		if (head is null)
			head = node;
	}

	void remove(NODEREF node)
	{
		if (node.prev is null)
			head = node.next;
		else
			node.prev.next = node.next;
		if (node.next is null)
			tail = node.prev;
		else
			node.next.prev = node.prev;
	}

	int iterate(T, string EXPR)(int delegate(ref T) dg)
	{
		int res = 0;
		for (auto node = head; node; node = node.next)
		{
			res = dg(mixin(EXPR));
			if (res)
				break;
		}
		return res;
	}

	@property bool empty()
	{
		return head is null;
	}
}

/// Organizes a bunch of objects in a doubly-linked list.
/// Not very efficient for reference types, since it results in two allocations per object.
struct DList(T, alias ALLOCATOR = RegionAllocator)
{
	struct Node
	{
		Node* prev, next;
		T item;
	}

	mixin DListCommon!(Node*) common;

	ALLOCATOR!Node allocator;

	Node* add(T item)
	{
		auto node = allocator.allocate();
		node.item = item;
		common.add(node);
		return node;
	}

	static if (is(typeof(&allocator.free)))
	void remove(Node* node)
	{
		common.remove(node);
		allocator.free(node);
	}

	int opApply(int delegate(ref T) dg)
	{
		return iterate!(T, "node.item")(dg);
	}
}

unittest
{
	DList!int l;
	auto i1 = l.add(1);
	auto i2 = l.add(2);
	auto i3 = l.add(3);
	l.remove(i2);
	int[] a;
	foreach (i; l)
		a ~= i;
	assert(a == [1, 3]);
}

/// Container for user-specified doubly-linked-list nodes.
/// Use together with DListItem.
struct DListContainer(Node)
{
	mixin DListCommon!(RefType!Node) common;

	int opApply(int delegate(ref Node) dg)
	{
		return iterate!(Node, "node")(dg);
	}
}

/// Mixin containing doubly-linked-list fields.
/// Use together with DListContainer.
mixin template DListItem()
{
	import ae.utils.alloc : RefType;
	RefType!(typeof(this)) prev, next;
}

unittest
{
	class C
	{
		mixin DListItem;
		int x;
		this(int p) { x = p; }
	}

	DListContainer!C l;

	auto c1 = new C(1);
	l.add(c1);
	auto c2 = new C(2);
	l.add(c2);
	auto c3 = new C(3);
	l.add(c3);

	l.remove(c2);

	int[] a;
	foreach (c; l)
		a ~= c.x;
	assert(a == [1, 3]);
}

// ***************************************************************************

/// A hash table with a static size.
struct HashTable(K, V, uint SIZE, alias ALLOCATOR=RegionAllocator, alias HASHFUNC="k")
{
	alias K KEY;
	alias V VALUE;

	import std.functional;
	import std.exception;

	alias unaryFun!(HASHFUNC, false, "k") hashFunc;

	// hashFunc returns a hash, get its type
	alias typeof(hashFunc(K.init)) H;
	static assert(is(H : ulong), "Numeric hash type expected");

	struct Item
	{
		K k;
		Item* next;
		V v;
	}
	Item*[SIZE] items;

	ALLOCATOR!Item allocator;

	deprecated V* get(in K k) { return k in this; }

	V* opIn_r(in K k)
	{
		auto h = hashFunc(k) % SIZE;
		auto item = items[h];
		while (item)
		{
			if (item.k == k)
				return &item.v;
			item = item.next;
		}
		return null;
	}

	V get(in K k, V def)
	{
		auto pv = k in this;
		return pv ? *pv : def;
	}

	/// Returns a pointer to the value storage space for a new value.
	/// Assumes the key does not yet exist in the table.
	V* add(in K k)
	{
		auto h = hashFunc(k) % SIZE;
		auto newItem = allocator.allocate();
		newItem.k = k;
		newItem.next = items[h];
		items[h] = newItem;
		return &newItem.v;
	}

	/// Returns a pointer to the value storage space for a new
	/// or existing value.
	V* getOrAdd(in K k)
	{
		auto h = hashFunc(k) % SIZE;
		auto item = items[h];
		while (item)
		{
			if (item.k == k)
				return &item.v;
			item = item.next;
		}

		auto newItem = allocator.allocate();
		newItem.k = k;
		newItem.next = items[h];
		items[h] = newItem;
		return &newItem.v;
	}

	void set(in K k, ref V v) { *getOrAdd(k) = v; }

	int opApply(int delegate(ref K, ref V) dg)
	{
		int result = 0;

		outerLoop:
		for (uint h=0; h<SIZE; h++)
		{
			auto item = items[h];
			while (item)
			{
				result = dg(item.k, item.v);
				if (result)
					break outerLoop;
				item = item.next;
			}
		}
		return result;
	}

	ref V opIndex(in K k)
	{
		auto pv = k in this;
		enforce(pv, "Key not in HashTable");
		return *pv;
	}

	void opIndexAssign(ref V v, in K k) { set(k, v); }

	size_t getLength()
	{
		size_t count = 0;
		for (uint h=0; h<SIZE; h++)
		{
			auto item = items[h];
			while (item)
			{
				count++;
				item = item.next;
			}
		}
		return count;
	}

	void clear()
	{
		items[] = null;
	}

	void freeAll()
	{
		static if (is(typeof(allocator.freeAll())))
			allocator.freeAll();
	}
}

unittest
{
	HashTable!(int, string, 16, AllocatorAdapter!(RegionAllocator, 16)) ht;
	assert(5 !in ht);
	auto s = "five";
	ht[5] = s;
	assert(5 in ht);
	assert(ht[5] == "five");
}
