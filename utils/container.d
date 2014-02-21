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

import std.range : isInputRange;
import ae.utils.alloc;

struct ListCommon
{
	mixin template Data(NODEREF, bool HASPREV, bool HASTAIL)
	{
		// non-copyable because head/tail can go out of sync
		// commented-out until AAs can support non-copyable values
		//@disable this(this) {}

		NODEREF head;
		static if (HASTAIL) NODEREF tail;

		invariant()
		{
			static if (HASPREV) if (head) assert(!head.prev);
			static if (HASTAIL) if (tail) assert(!tail.next);
		}
	}

	mixin template Impl(NODEREF, bool HASPREV, bool HASTAIL, alias data)
	{
		void pushFront(NODEREF node)
		{
			static if (HASPREV) node.prev = null;
			node.next = data.head;
			static if (HASPREV)
				if (data.head)
					data.head.prev = node;
			data.head = node;
			static if (HASTAIL)
				if (!data.tail)
					data.tail = node;
		}

		static if (HASTAIL)
		void pushBack(NODEREF node)
		{
			node.next = null;
			static if (HASPREV) node.prev = data.tail;
			if (data.tail)
				data.tail.next = node;
			data.tail = node;
			if (data.head is null)
				data.head = node;
		}

		static if (HASTAIL)
		deprecated alias pushBack add;

		NODEREF popFront()
		{
			assert(data.head);
			auto result = data.head;

			auto next = data.head.next;
			if (next)
			{
				static if (HASPREV) next.prev = null;
			}
			else
			{
				static if (HASTAIL) data.tail = null;
			}
			data.head = next;
			result.next = null;
			return result;
		}

		static if (HASTAIL && HASPREV)
		NODEREF popBack()
		{
			assert(data.tail);
			auto result = data.tail;

			auto prev = data.tail.prev;
			if (prev)
				prev.next = null;
			else
				data.head = null;
			data.tail = prev;
			result.prev = null;
			return result;
		}

		static if (HASPREV)
		void remove(NODEREF node)
		{
			if (node.prev)
				node.prev.next = node.next;
			else
				data.head = node.next;
			if (node.next)
				node.next.prev = node.prev;
			else
				static if (HASTAIL) data.tail = node.prev;
			node.next = node.prev = null;
		}

		static struct Iterator(bool FORWARD)
		{
			NODEREF cursor;

			@property bool empty() { return !cursor; }
			@property auto ref front() { return mixin(q{cursor} ~ ITEM_EXPR); }
			void popFront()
			{
				static if (FORWARD)
					cursor = cursor.next;
				else
					cursor = cursor.prev;
			}
		}

		alias Iterator!true ForwardIterator;
		static assert(isInputRange!ForwardIterator);

		static if (HASPREV)
			alias Iterator!false ReverseIterator;

		@property auto iterator() { return ForwardIterator(data.head); }
		static if (HASPREV && HASTAIL)
		@property auto reverseIterator() { return ReverseIterator(data.tail); }

		static if (HASPREV)
		void remove(I)(I iterator)
			if (is(I==ForwardIterator) || is(I==ReverseIterator))
		{
			return remove(iterator.cursor);
		}

		int opApply(int delegate(ref typeof(mixin(q{NODEREF.init} ~ ITEM_EXPR))) dg)
		{
			int res = 0;
			for (auto node = data.head; node; node = node.next)
			{
				res = dg(mixin(q{node} ~ ITEM_EXPR));
				if (res)
					break;
			}
			return res;
		}

		@property bool empty()
		{
			return data.head is null;
		}

		@property auto ref front() { return mixin(q{data.head} ~ ITEM_EXPR); }
		static if (HASTAIL)
		@property auto ref back () { return mixin(q{data.tail} ~ ITEM_EXPR); }
	}
}

/// Mixin containing the linked-list fields.
/// When using *ListContainer, inject it into your custom type.
mixin template ListLink(bool HASPREV)
{
	import ae.utils.meta : RefType;
	alias RefType!(typeof(this)) NODEREF;
	NODEREF next;
	static if (HASPREV) NODEREF prev;
}

mixin template SListLink() { mixin ListLink!false; }
mixin template DListLink() { mixin ListLink!true ; }
deprecated alias DListLink DListItem;

struct ListNode(T, bool HASPREV)
{
	mixin ListLink!(HASPREV);
	T value;
	deprecated alias value item;
}

/// Organizes a bunch of objects in a linked list.
/// Not very efficient for reference types, since it results in two allocations per object.
struct ListParts(T, bool HASPREV, bool HASTAIL, alias ALLOCATOR=heapAllocator)
{
	alias ListNode!(T, HASPREV) Node;
	enum ITEM_EXPR = q{.value};

	struct Data
	{
		mixin ListCommon.Data!(Node*, HASPREV, HASTAIL);
	}

	static template Impl(alias data)
	{
		mixin ListCommon.Impl!(Node*, HASPREV, HASTAIL, data) common;

		Node* pushFront(T v)
		{
			auto node = ALLOCATOR.allocate!Node();
			node.value = v;
			common.pushFront(node);
			return node;
		}

		static if (HASTAIL)
		Node* pushBack(T v)
		{
			auto node = ALLOCATOR.allocate!Node();
			node.value = v;
			common.pushBack(node);
			return node;
		}

		static if (HASTAIL)
		deprecated alias pushBack add;

		static if (HASPREV)
		void remove(Node* node)
		{
			common.remove(node);
			static if (is(typeof(&ALLOCATOR.free)))
				ALLOCATOR.free(node);
		}
	}
}

alias PartsWrapper!ListParts List;

/// Singly-ended singly-linked list. Usable as a stack.
template SList(T)
{
	alias List!(T, false, false) SList;
}

/// Double-ended singly-linked list. Usable as a stack or queue.
template DESList(T)
{
	alias List!(T, false, true) DESList;
}

/// Doubly-linked list. Usable as a stack, queue or deque.
template DList(T)
{
	alias List!(T, true, true) DList;
}

/// Doubly-linked but single-ended list.
/// Can't be used as a queue or deque, but supports arbitrary removal.
template SEDList(T)
{
	alias List!(T, true, false) SEDList;
}

unittest
{
	DList!int l;
	auto i1 = l.pushBack(1);
	auto i2 = l.pushBack(2);
	auto i3 = l.pushBack(3);
	l.remove(i2);

	int[] a;
	foreach (i; l)
		a ~= i;
	assert(a == [1, 3]);

	import std.algorithm;
	assert(equal(l.iterator, [1, 3]));
}

/// Container for user-specified list nodes.
/// Use together with *ListLink.
struct ListContainer(Node, bool HASPREV, bool HASTAIL)
{
	enum ITEM_EXPR = q{};
	mixin ListCommon.Data!(RefType!Node, HASPREV, HASTAIL) commonData;
	mixin ListCommon.Impl!(RefType!Node, HASPREV, HASTAIL, commonData) commonImpl;
}


/// *List variations for containers of user linked types.
template SListContainer(T)
{
	alias ListContainer!(T, false, false) SListContainer;
}

/// ditto
template DESListContainer(T)
{
	alias ListContainer!(T, false, true) DESListContainer;
}

/// ditto
template DListContainer(T)
{
	alias ListContainer!(T, true, true) DListContainer;
}

/// ditto
template SEDListContainer(T)
{
	alias ListContainer!(T, true, false) SEDListContainer;
}

unittest
{
	class C
	{
		mixin DListLink;
		int x;
		this(int p) { x = p; }
	}

	DListContainer!C l;

	auto c1 = new C(1);
	l.pushBack(c1);
	auto c2 = new C(2);
	l.pushBack(c2);
	auto c3 = new C(3);
	l.pushBack(c3);

	l.remove(c2);

	int[] a;
	foreach (c; l)
		a ~= c.x;
	assert(a == [1, 3]);

	import std.algorithm;
	assert(equal(l.iterator.map!(c => c.x)(), [1, 3]));
}

// ***************************************************************************

struct HashTableItem(K, V)
{
	K k;
	HashTableItem* next;
	V v;
}

/// A hash table with a static size.
struct HashTable(K, V, uint SIZE, alias ALLOCATOR, alias HASHFUNC="k")
{
	alias K KEY;
	alias V VALUE;

	import std.functional;
	import std.exception;

	alias unaryFun!(HASHFUNC, false, "k") hashFunc;

	// hashFunc returns a hash, get its type
	alias typeof(hashFunc(K.init)) H;
	static assert(is(H : ulong), "Numeric hash type expected");

	alias HashTableItem!(K, V) Item;

	struct Data
	{
		Item*[SIZE] items;
	}

	static template Impl(alias data)
	{
		V* get(in K k)
		{
			auto h = hashFunc(k) % SIZE;
			auto item = data.items[h];
			while (item)
			{
				if (item.k == k)
					return &item.v;
				item = item.next;
			}
			return null;
		}

		V* opIn_r(in K k) { return get(k); } // Issue 11842

		V get(in K k, V def)
		{
			auto pv = get(k);
			return pv ? *pv : def;
		}

		/// Returns a pointer to the value storage space for a new value.
		/// Assumes the key does not yet exist in the table.
		V* add(in K k)
		{
			auto h = hashFunc(k) % SIZE;
			auto newItem = ALLOCATOR.allocate!Item();
			newItem.k = k;
			newItem.next = data.items[h];
			data.items[h] = newItem;
			return &newItem.v;
		}

		/// Returns a pointer to the value storage space for a new
		/// or existing value.
		V* getOrAdd(in K k)
		{
			auto h = hashFunc(k) % SIZE;
			auto item = data.items[h];
			while (item)
			{
				if (item.k == k)
					return &item.v;
				item = item.next;
			}

			auto newItem = ALLOCATOR.allocate!Item();
			newItem.k = k;
			newItem.next = data.items[h];
			data.items[h] = newItem;
			return &newItem.v;
		}

		void set(in K k, ref V v) { *getOrAdd(k) = v; }

		int opApply(int delegate(ref K, ref V) dg)
		{
			int result = 0;

			outerLoop:
			for (uint h=0; h<SIZE; h++)
			{
				auto item = data.items[h];
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
			auto pv = get(k);
			enforce(pv, "Key not in HashTable");
			return *pv;
		}

		void opIndexAssign(ref V v, in K k) { set(k, v); }

		size_t getLength()
		{
			size_t count = 0;
			for (uint h=0; h<SIZE; h++)
			{
				auto item = data.items[h];
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
			data.items[] = null;
		}

		void freeAll()
		{
			static if (is(typeof(ALLOCATOR.freeAll())))
				ALLOCATOR.freeAll();
		}
	}
}

unittest
{
	static struct Test
	{
		WrapParts!(RegionAllocator!()) allocator;
		alias HashTable!(int, string, 16, allocator) HT;
		HT.Data htData;
		alias ht = HT.Impl!htData;

		mixin(mixAliasForward!(ht, q{ht}));
	}
	Test ht;

	assert(5 !in ht);
	auto s = "five";
	ht[5] = s;
	assert(5 in ht);
	assert(ht[5] == "five");
}
