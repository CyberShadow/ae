/**
 * Bulk allocators
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
		Node* next; /// Next free node
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

	Node* head; /// First free node

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
