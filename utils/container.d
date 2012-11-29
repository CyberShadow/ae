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
struct DList(T, alias ALLOCATOR = LinkedBulkAllocator)
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

/// BulkAllocator adapter for HashTable.
/// HashTable needs an allocator template that simply accepts a type parameter,
/// so this template declares a template which instantiates a given allocator
/// template (ALLOCATOR) using the type passed by HashTable (T).
template HashTableBulkAllocator(uint BLOCKSIZE, alias ALLOCATOR = HeapAllocator)
{
	template HashTableBulkAllocator(T)
	{
		alias ArrayBulkAllocator!(T, BLOCKSIZE, ALLOCATOR) HashTableBulkAllocator;
	}
}

struct HashTable(K, V, uint SIZE, alias ALLOCATOR, string HASHFUNC="k")
{
	// HASHFUNC returns a hash, get its type
	alias typeof(((){ K k; return mixin(HASHFUNC); })()) H;
	static assert(is(H : ulong), "Numeric hash type expected");

	struct Item
	{
		K k;
		Item* next;
		V v;
	}
	Item*[SIZE] items;

	ALLOCATOR!(Item) allocator;

	V* get(ref K k)
	{
		auto h = mixin(HASHFUNC) % SIZE;
		auto item = items[h];
		while (item)
		{
			if (item.k == k)
				return &item.v;
			item = item.next;
		}
		return null;
	}

	V* add(ref K k)
	{
		auto h = mixin(HASHFUNC) % SIZE;
		auto newItem = allocator.allocate();
		newItem.k = k;
		newItem.next = items[h];
		items[h] = newItem;
		return &newItem.v;
	}

	V* getOrAdd(ref K k)
	{
		auto h = mixin(HASHFUNC) % SIZE;
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

	void freeAll()
	{
		static if (is(typeof(allocator.freeAll())))
			allocator.freeAll();
	}
}
