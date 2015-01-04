/**
 * Linked list containers
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

public import ae.utils.container.listnode;

import ae.utils.alloc;

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

