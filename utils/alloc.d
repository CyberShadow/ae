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

/// Bulk allocators
module ae.utils.alloc;

import std.conv : emplace;

/// typeof(new T)
template RefType(T)
{
	static if (is(T == class))
		alias T RefType;
	else
		alias T* RefType;
}

template ValueType(T)
{
	static if (is(T == class))
	{
		static if (__traits(classInstanceSize, T) % size_t.sizeof == 0)
			alias void*[__traits(classInstanceSize, T) / size_t.sizeof] ValueType;
		else
			static assert(0, "TODO"); // union with a pointer
	}
	else
		alias T ValueType;
}

mixin template AllocatorCommon()
{
	alias RefType!T R;
	alias ValueType!T V;

	R create(A...)(A args)
	{
		auto r = allocate();
		emplace!T(cast(void[])((cast(V*)r)[0..1]), args);
		return r;
	}

	static if (is(typeof(&free)))
	void destroy(R r)
	{
		clear(r);
		free(r);
	}
}

/// Linked list allocator. Supports O(1) deletion.
struct LinkedBulkAllocator(T, uint BLOCKSIZE=1024, alias ALLOCATOR = HeapAllocator)
{
	mixin AllocatorCommon;

	mixin template NodeContents()
	{
		Node* next;
		V data;
	}

	debug
		struct Node
		{
			mixin NodeContents;
			static Node* fromRef(R r) { return cast(Node*)( (cast(ubyte*)r) - (size_t.sizeof) ); }
		}
	else
		union Node
		{
			mixin NodeContents;
			static Node* fromRef(R r) { return cast(Node*)r; }
		}

	Node* head;

	struct Block { Node[BLOCKSIZE] nodes; }
	ALLOCATOR!Block allocator;

	R allocate()
	{
		if (head is null)
		{
			head = allocator.allocate().nodes.ptr;
			foreach (i; 0..BLOCKSIZE-1)
				head[i].next = &head[i+1];
			head[BLOCKSIZE-1].next = null;
		}
		auto node = head;
		head = head.next;
		return cast(R)&node.data;
	}

	void free(R r)
	{
		auto node = Node.fromRef(r);
		node.next = head;
		head = node;
	}
}

/// No deletion, but is slightly faster that LinkedBulkAllocator
struct ArrayBulkAllocator(T, uint BLOCKSIZE=1024, alias ALLOCATOR = HeapAllocator)
{
	mixin AllocatorCommon;

	struct Block { V[BLOCKSIZE] data; }

	V* lastBlock;
	uint index = BLOCKSIZE;

	V*[] blocks; // TODO: use linked list?

	ALLOCATOR!Block allocator;

	R allocate()
	{
		if (index==BLOCKSIZE)
			newBlock();
		return cast(R)(lastBlock + index++);
	}

	void newBlock()
	{
		lastBlock = (allocator.allocate()).data.ptr;
		blocks ~= lastBlock;
		index = 0;
	}

	static if (is(typeof(&allocator.freeAll)))
	{
		void freeAll()
		{
			allocator.freeAll();
		}
	}
	else
	static if (is(typeof(&allocator.free)))
	{
		void freeAll()
		{
			foreach (block; blocks)
				allocator.free(cast(Block*)block);
		}
	}
}

struct HeapAllocator(T)
{
	alias RefType!T R;
	alias ValueType!T V;

	R allocate()
	{
		return new T;
	}

	R create(A...)(A args)
	{
		return new T(args);
	}

	void free(R v)
	{
		delete v;
	}
	alias free destroy;
}

struct DataAllocator(T)
{
	mixin AllocatorCommon;

	import ae.sys.data;

	Data[] datas;

	R allocate()
	{
		auto data = Data(V.sizeof);
		datas ~= data;
		return cast(R)data.ptr;
	}

	void freeAll()
	{
		foreach (data; datas)
			data.deleteContents();
	}
}

unittest
{
    void test(alias A)()
    {
		static class C { int x=2; this() {} this(int p) { x = p; } }
		A!C bc;
		auto c1 = bc.create();
		assert(c1.x == 2);

		auto c2 = bc.create(5);
		assert(c2.x == 5);
    }
	
	test!HeapAllocator();	
//	test!DataAllocator();
	test!LinkedBulkAllocator();
	test!ArrayBulkAllocator();
}
