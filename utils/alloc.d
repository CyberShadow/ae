/**
 * Composable allocators
 *
 * This module uses a composing system - allocators implementing various
 * strategies allocate memory in bulk from another backend allocator,
 * "chained" in as a template parameter.
 *
 * Various allocation strategies allow for various capabilities - e.g.
 * some strategies may not keep metadata required to free the memory of
 * individual instances. Code should test the presence of primitives
 * (methods in allocator type instances) accordingly.
 *
 * Composing allocators (and other allocator consumers) expect the
 * underlying allocator alias parameter to be a template which is
 * instantiated with a single parameter (the base type to allocate, which
 * is intrinsic to the composing allocator). Thus, to pass underlying
 * allocators that take more than one parameter, an adapter template must
 * be used. The AllocatorAdapter template will perform template currying
 * and create such adapter templates.
 *
 * To configure the underlying allocator of a composing allocator, the
 * "allocator" field is "public" for that purpose. Note that the
 * underlying allocator type might be a pointer, to allow using diverse
 * strategies using the same backend allocator pool.
 *
 * Allocator kinds:
 *
 * * Homogenous allocators, once instantiated, can only allocate values
 *   only of the type specified in the template parameter.
 *
 * * Heterogenous allocators are not bound by one type. One instance can
 *   allocate values of multiple types (the type is a template parameter
 *   of the allocate method). By convention, heterogenous allocators have
 *   "Multi" in their template name.
 *
 * Allocator primitives:
 *
 * allocate
 *   Return a pointer to a new instance.
 *   The only mandatory primitive.
 *
 * create
 *   Allocate and initialize/construct a new instance of T, with the
 *   supplied parameters.
 *
 * free
 *   Free memory at the given pointer, assuming it was allocated by the
 *   same allocator.
 *
 * destroy
 *   Finalize and free the given pointer.
 *
 * allocateMany
 *   Allocate an array of values, with the given size. Allocators which
 *   support this primitive are referred to as "bulk allocators".
 *
 * freeMany
 *   Free memory for the given array of values.
 *
 * resize
 *   Resize an array of values. Reallocate if needed.
 *
 * freeAll
 *   Free all memory allocated using the given allocator, at once.
 *   Deallocates storage from underlying allocator, if applicable.
 *
 * clear
 *   Mark all memory allocated by the top-layer allocator as free.
 *   Does not deallocate memory from underlying allocator.
 *
 * References:
 *   http://accu.org/content/conf2008/Alexandrescu-memory-allocation.screen.pdf
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

// TODO:
// - GROWFUN callable alias parameter instead of BLOCKSIZE?
// - Consolidate RegionAllocator and GrowingBufferAllocator
// - Add new primitive for bulk allocation which returns a range?
//   (to allow non-contiguous bulk allocation, but avoid
//   allocating an array of pointers to store the result)
// - Perhaps, instead of the AllocatorAdapter craziness, make all
//   homogenous allocators a template template?

/// typeof(new T) - what we use to refer to an allocated instance
template RefType(T)
{
	static if (is(T == class))
		alias T RefType;
	else
		alias T* RefType;
}

/// Reverse of RefType
template FromRefType(R)
{
	static if (is(T == class))
		alias T FromRefType;
	else
	{
		static assert(is(typeof(*(R.init))), R.stringof ~ " is not dereferenceable");
		alias typeof(*(R.init)) FromRefType;
	}
}

/// What we use to store an allocated instance
template ValueType(T)
{
	static if (is(T == class))
	{
		//alias void*[(__traits(classInstanceSize, T) + size_t.sizeof-1) / size_t.sizeof] ValueType;
		static assert(__traits(classInstanceSize, T) % size_t.sizeof == 0, "TODO"); // union with a pointer

		// Use a struct to allow new-ing the type (you can't new a static array directly)
		struct ValueType
		{
			void*[__traits(classInstanceSize, T) / size_t.sizeof] data;
		}
	}
	else
		alias T ValueType;
}

/// Curries an allocator template and creates a template
/// that takes only one T parameter. (See module DDoc for details.)
template AllocatorAdapter(alias ALLOCATOR, ARGS...)
{
	template AllocatorAdapter(T)
	{
		alias ALLOCATOR!(T, ARGS) AllocatorAdapter;
	}
}

/// As above, but result resolves to a pointer to the allocator.
template AllocatorPointer(alias ALLOCATOR, ARGS...)
{
	template AllocatorPointer(T)
	{
		alias ALLOCATOR!(T, ARGS)* AllocatorPointer;
	}
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

mixin template MultiAllocatorCommon()
{
	RefType!T create(T, A...)(A args)
	{
		alias ValueType!T V;

		auto r = allocate!T();
		emplace!T(cast(void[])((cast(V*)r)[0..1]), args);
		return r;
	}

	static if (is(typeof(&free)))
	void destroy(R)(R r)
	{
		clear(r);
		free(r);
	}
}

/// Homogenous linked list allocator.
/// Supports O(1) deletion.
/// Does not support bulk allocation.
struct FreeListAllocator(T, alias ALLOCATOR = HeapAllocator)
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

	Node* head = null; /// First free node

	ALLOCATOR!Node allocator;

	R allocate()
	{
		if (head is null)
		{
			auto node = allocator.allocate();
			return cast(R)&node.data;
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

mixin template PointerBumpCommon()
{
	// Context:
	//   ptr - pointer to next free element
	//   end - pointer to end of buffer
	//   bufferExhausted - method called when ptr==end
	//     (takes new size to allocate as parameter)
	//   BLOCKSIZE - default parameter to bufferExhausted

	R allocate()
	{
		if (ptr==end)
			bufferExhausted(BLOCKSIZE);
		return cast(R)(ptr++);
	}

	V[] allocateMany(size_t n)
	{
		if (n > (end-ptr))
			bufferExhausted(n > BLOCKSIZE ? n : BLOCKSIZE);

		auto result = ptr[0..n];
		ptr += n;
		return result;
	}
}

/// Homogenous array bulk allocator.
/// Compose over another allocator to allocate values in bulk (minimum of BLOCKSIZE).
/// No deletion, but is slightly faster that FreeListAllocator
/// NEED_FREE controls whether freeAll support is needed.
// TODO: support non-bulk allocators (without allocateMany support)
struct RegionAllocator(T, size_t BLOCKSIZE=1024, alias ALLOCATOR = HeapAllocator, bool NEED_FREE=true)
{
	mixin AllocatorCommon;

	V* ptr=null, end=null;

	static if (NEED_FREE) V[][] blocks; // TODO: use linked list?

	ALLOCATOR!V allocator;

	private void newBlock(size_t size)
	{
		auto arr = allocator.allocateMany(size);
		ptr = arr.ptr;
		end = ptr + arr.length;
		static if (NEED_FREE) blocks ~= arr;
	}

	static if (is(typeof(&allocator.freeAll)))
	{
		void freeAll()
		{
			allocator.freeAll();
		}
	}
	else
	static if (NEED_FREE && is(typeof(&allocator.freeMany)))
	{
		void freeAll()
		{
			foreach (block; blocks)
				allocator.freeMany(block);
		}
	}

	alias newBlock bufferExhausted;
	mixin PointerBumpCommon;
}

/// Heterogenous allocator adapter over a homogenous bulk allocator.
/// The BASE type (the type passed to the underlying allocator)
/// controls the alignment and whether the data will contain pointers.
struct MultiAllocator(alias ALLOCATOR, BASE=void*)
{
	mixin MultiAllocatorCommon;

	ALLOCATOR!BASE allocator;

	RefType!T allocate(T)()
	{
		alias RefType!T R;
		alias ValueType!T V;
		enum ALLOC_SIZE = (V.sizeof + BASE.sizeof-1) / BASE.sizeof;

		//return cast(RefType!T)(allocateMany!T(1).ptr);
		return cast(R)(allocator.allocateMany(ALLOC_SIZE).ptr);
	}

	ValueType!T[] allocateMany(T)(size_t n)
	{
		alias RefType!T R;
		alias ValueType!T V;
		enum ALLOC_SIZE = (V.sizeof + BASE.sizeof-1) / BASE.sizeof;

		static assert(V.sizeof % BASE.sizeof == 0, "Aligned/contiguous allocation impossible");

		auto s = n * ALLOC_SIZE; // how many of BASE do we need?
		return cast(V[])allocator.allocateMany(s);
	}

	static if (is(typeof(&allocator.freeAll)))
	{
		void freeAll()
		{
			allocator.freeAll();
		}
	}

	static if (is(typeof(&allocator.freeMany)))
	{
		void free(R)(R r)
		{
			alias FromRefType!R T;
			alias ValueType!T V;
			enum ALLOC_SIZE = (V.sizeof + BASE.sizeof-1) / BASE.sizeof;

			allocator.freeMany((cast(BASE*)r)[0..ALLOC_SIZE]);
		}

		void freeMany(V)(V[] v)
		{
			allocator.freeMany(cast(BASE[])v);
		}
	}
}

/// Heterogenous array bulk allocator (combines RegionAllocator with MultiAllocator).
/// Uses "bump-the-pointer" approach for bulk allocation of arbitrary types.
template RegionMultiAllocator(size_t BLOCKSIZE=1024, alias ALLOCATOR = HeapAllocator, BASE=void*, bool NEED_FREE=true)
{
	alias MultiAllocator!(AllocatorAdapter!(RegionAllocator, BLOCKSIZE, ALLOCATOR, NEED_FREE), BASE) RegionMultiAllocator;
}

/// Reuse a multi-allocator with a typed allocator.
/// Reverse of MultiAllocator.
struct TypedAllocator(T, alias ALLOCATOR)
{
	ALLOCATOR allocator;

	mixin AllocatorCommon;

	R allocate() { return allocator.allocate!T(); }

	static if (is(typeof(&allocator.free!R)))
		void free(R r) { allocator.free(r); }

	static if (is(typeof(&allocator.allocateMany!T)))
		V[] allocateMany(size_t n) { return allocator.allocateMany!T(n); }

	static if (is(typeof(&allocator.freeMany!V)))
		void freeMany(V[] v) { allocator.freeMany(v); }

	static if (is(typeof(&allocator.resize!V)))
		V[] resize(V[] v, size_t n) { return allocator.resize(v, n); }
}

/// Growing buffer bulk allocator.
/// Allows reusing the same buffer, which is grown and retained as needed.
/// Requires .resize support from underlying allocator.
/// Smaller buffers are discarded (neither freed nor reused).
struct GrowingBufferAllocator(T, alias ALLOCATOR = HeapAllocator)
{
	mixin AllocatorCommon;

	ALLOCATOR!V allocator;

	V* buf, ptr, end;

	void bufferExhausted(size_t n)
	{
		import std.algorithm;
		auto newSize = max(4096 / V.sizeof, (end-buf)*2, n);
		auto pos = ptr - buf;
		auto arr = allocator.resize(buf[0..end-buf], newSize);
		buf = arr.ptr;
		end = buf + arr.length;
		ptr = buf + pos;
	}

	void clear()
	{
		ptr = buf;
	}

	enum BLOCKSIZE=0;
	mixin PointerBumpCommon;
}

/// Backend homogenous allocator using the managed GC heap.
struct HeapAllocator(T)
{
	alias RefType!T R;
	alias ValueType!T V;

	R allocate()
	{
		return new T;
	}

	V[] allocateMany(size_t n)
	{
		return new V[n];
	}

	V[] resize(V[] v, size_t n)
	{
		v.length = n;
		return v;
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

	void freeMany(V[] v)
	{
		delete v;
	}
}

/// A substitute heterogenous allocator which uses the managed GC heap directly.
struct HeapMultiAllocator
{
	RefType!T allocate(T)()
	{
		return new T;
	}

	ValueType!T[] allocateMany(T)(size_t n)
	{
		return new ValueType!T[n];
	}

	RefType!T create(T, A...)(A args)
	{
		return new T(args);
	}

	V[] resize(V)(V[] v, size_t n)
	{
		v.length = n;
		return v;
	}

	void free(R)(R r)
	{
		delete r;
	}
	alias free destroy;

	void freeMany(V)(V[] v)
	{
		delete v;
	}
}

/// Backend allocator using the Data type from ae.sys.data.
struct DataAllocator(T)
{
	mixin AllocatorCommon;

	import ae.sys.data;

	// Needed to make data referenced in Data instances reachable by the GC
	Data[] datas;

	V[] allocateMany(size_t n)
	{
		auto data = Data(V.sizeof * n);
		datas ~= data;
		return cast(V[])data.mcontents;
	}

	R allocate()
	{
		return cast(R)(allocateMany(1).ptr);
	}

	void freeAll()
	{
		foreach (data; datas)
			data.deleteContents();
	}
}

/// Thrown when the buffer of an allocator is exhausted.
class BufferExhaustedException : Exception { this() { super("Allocator buffer exhausted"); } }

/// Homogenous allocator which uses a given buffer.
/// Throws BufferExhaustedException if the buffer is exhausted.
struct BufferAllocator(T)
{
	mixin AllocatorCommon;

	void setBuffer(V[] buf)
	{
		ptr = buf.ptr;
		end = ptr + buf.length;
	}

	this(V[] buf) { setBuffer(buf); }

	V* ptr, end;

	static void bufferExhausted(size_t n)
	{
		throw new BufferExhaustedException();
	}

	enum BLOCKSIZE=0;
	mixin PointerBumpCommon;
}

/// Homogenous allocator which uses a static buffer of a given size.
/// Throws BufferExhaustedException if the buffer is exhausted.
/// Needs to be manually initialized before use.
struct StaticBufferAllocator(T, size_t SIZE)
{
	mixin AllocatorCommon;

	V[SIZE] buffer;
	V* ptr;
	@property V* end() { return buffer.ptr + buffer.length; }

	void initialize()
	{
		ptr = buffer.ptr;
	}

	void bufferExhausted(size_t n)
	{
		throw new BufferExhaustedException();
	}

	enum BLOCKSIZE=0;
	mixin PointerBumpCommon;

	alias initialize clear;
}

/// A bulk allocator which behaves like a StaticBufferAllocator initially,
/// but once the static buffer is exhausted, it switches to a fallback
/// bulk allocator.
/// Needs to be manually initialized before use.
struct HybridBufferAllocator(T, size_t SIZE, alias FALLBACK_ALLOCATOR)
{
	mixin AllocatorCommon;

	FALLBACK_ALLOCATOR!V fallbackAllocator;

	V[SIZE] buffer;
	V* ptr, end;

	void initialize()
	{
		ptr = buffer.ptr;
		end = buffer.ptr + buffer.length;
	}

	void bufferExhausted(size_t n)
	{
		auto arr = fallbackAllocator.allocateMany(n);
		ptr = arr.ptr;
		end = ptr + arr.length;
	}

	enum BLOCKSIZE = SIZE;
	mixin PointerBumpCommon;

	static if (is(typeof(&fallbackAllocator.clear)))
	{
		void clear()
		{
			if (end == buffer.ptr + buffer.length)
				ptr = buffer.ptr;
			else
				fallbackAllocator.clear();
		}
	}
}

version(unittest) import ae.sys.data;

unittest
{
	void testAllocator(alias A, string INIT="")()
	{
		static class C { int x=2; this() {} this(int p) { x = p; } }
		A!C a;
		mixin(INIT);
		auto c1 = a.create();
		assert(c1.x == 2);

		auto c2 = a.create(5);
		assert(c2.x == 5);
	}

	void testMultiAllocator(A, string INIT="")()
	{
		static class C { int x=2; this() {} this(int p) { x = p; } }
		A a;
		mixin(INIT);
		auto c1 = a.create!C();
		assert(c1.x == 2);

		auto c2 = a.create!C(5);
		assert(c2.x == 5);
	}

	testAllocator!HeapAllocator();
	testAllocator!DataAllocator();
	testAllocator!FreeListAllocator();
	testAllocator!RegionAllocator();
	testAllocator!GrowingBufferAllocator();
	testAllocator!(BufferAllocator, q{a.setBuffer(new a.V[1024]);})();
	testAllocator!(AllocatorAdapter!(StaticBufferAllocator, 4096), q{a.initialize();})();
	testAllocator!(AllocatorAdapter!(HybridBufferAllocator, 4096, HeapAllocator), q{a.initialize();})();
	testAllocator!(AllocatorAdapter!(TypedAllocator, HeapMultiAllocator))();

	testMultiAllocator!HeapMultiAllocator();
	testMultiAllocator!(RegionMultiAllocator!())();
}
