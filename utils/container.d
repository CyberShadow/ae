/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2012
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

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
