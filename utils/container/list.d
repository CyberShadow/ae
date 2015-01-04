/**
 * ae.utils.container.list
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

module ae.utils.container.list;

import std.range : isInputRange;
import ae.utils.alloc;
import ae.utils.meta.reference;

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
