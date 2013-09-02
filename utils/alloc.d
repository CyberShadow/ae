/**
 * Composable allocators
 *
 * This module uses a composing system - allocators implementing various
 * strategies allocate memory in bulk from another backend allocator,
 * "chained" in as a template alias or string parameter.
 *
 * Various allocation strategies allow for various capabilities - e.g.
 * some strategies may not keep metadata required to free the memory of
 * individual instances. Code should test the presence of primitives
 * (methods in allocator mixin instances) accordingly.
 *
 * Allocators are mixin templates. This allows for multiple composed
 * allocators, as well as data structures using them, to have the same
 * "this" pointer, which would avoid additional indirections.
 *
 * The underlying allocator can be passed in as an alias template
 * parameter. This means that it has to be a symbol, the address of which
 * is known in the scope of the allocator - thus, a mixin in the same
 * class/struct, or a global variable.
 *
 * The underlying allocator can also be passed in as a string template
 * parameter. A string can be used instead of an alias parameter to allow
 * using complex expressions - for example, using a named mixin inside a
 * struct pointer.
 *
 * Allocator kinds:
 *
 * * Homogenous allocators, once instantiated, can only allocate values
 *   only of the type specified in the template parameter. Attempting to
 *   allocate a different type will result in a compile-time error.
 *
 * * Heterogenous allocators are not bound by one type. One instance can
 *   allocate values of multiple types.
 *
 * Allocator primitives:
 *
 * allocate
 *   Return a pointer to a new instance.
 *   The returned object is not initialized.
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
import std.traits : fullyQualifiedName;

import ae.utils.meta : RefType, FromRefType, StorageType;

// TODO:
// - GROWFUN callable alias parameter instead of BLOCKSIZE?
// - Consolidate RegionAllocator and GrowingBufferAllocator
// - Add new primitive for bulk allocation which returns a range?
//   (to allow non-contiguous bulk allocation, but avoid
//   allocating an array of pointers to store the result)
// - Forbid allocating types with indirections when the base type
//   is not a pointer?
// - More thorough testing

/// Declares a WrapMixin template in the current scope, which will
/// create a struct containing an instance of the mixin template M,
/// instantiated with the given ARGS.
/// WrapMixin is not reusable across scopes. Each scope should have an
/// instance of WrapMixin, as the context of M's instantiation will be
/// the scope declaring WrapMixin, not the scope declaring M.
mixin template AddWrapMixin()
{
	private struct WrapMixin(alias M, ARGS...) { mixin M!ARGS; }
}

mixin AddWrapMixin;

/// Declares a MixinWrapper template in the current scope, which will
/// create a struct template containing an instance of the mixin template
/// M, instantiated with the arguments passed to the struct template.
/// Similar to WrapMixin, MixinWrapper is not reusable across scopes.
/// Each scope should have an instance of MixinWrapper, as the context of
/// M's instantiation will be the scope declaring MixinWrapper, not the
/// scope declaring M.
mixin template AddMixinWrapper()
{
	private template MixinWrapper(alias M)
	{
		struct MixinWrapper(ARGS...)
		{
			mixin M!ARGS;
		}
	}
}

/// Generates code to create forwarding aliases to the given mixin member.
/// Used as a replacement for "alias M this", which doesn't seem to work with mixins.
string mixAliasForward(alias M)()
{
	import std.string;
	enum mixinName = __traits(identifier, M);
	string result;
	foreach (fieldName; __traits(allMembers, M))
		result ~= "alias " ~ mixinName ~ "." ~ fieldName ~ " " ~ fieldName ~ ";\n";
	return result;
}

/// Declares ALLOCATOR_EXPR, a string mixin which, when mixin()'d,
/// resolves to the ALLOCATOR string mixin (if it's a string) or
/// alias (otherwise).
/// Facilitates allocator users to accept allocators as both aliases
/// or expressions specified as string mixins.
mixin template AllocatorExpr()
{
	static if (is(typeof(ALLOCATOR) == string))
		enum ALLOCATOR_EXPR = ALLOCATOR;
	else
		enum ALLOCATOR_EXPR = q{ALLOCATOR};
}

/// Common declarations for an allocator mixin
mixin template AllocatorCommon()
{
	alias ae.utils.alloc.StorageType StorageType;

	RefType!T create(T, A...)(A args)
	{
		alias StorageType!T V;

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

	static if (is(ALLOCATOR_TYPE))
		alias StorageType!ALLOCATOR_TYPE VALUE_TYPE;

	static if (is(BASE_TYPE))
		alias StorageType!BASE_TYPE BASE_VALUE_TYPE;

	static if (is(typeof(ALLOCATOR)))
		mixin AllocatorExpr;
}

/// Creates T/R/V aliases from context, and checks ALLOCATOR_TYPE if appropriate.
mixin template AllocTypes()
{
	static if (is(R) && !is(T)) alias FromRefType!R T;
	static if (is(T) && !is(R)) alias RefType!T R;
	static if (is(T) && !is(V)) alias StorageType!T V;
	static if (is(ALLOCATOR_TYPE)) static assert(is(ALLOCATOR_TYPE==T), "This allocator can only allocate instances of " ~ ALLOCATOR_TYPE.stringof ~ ", not " ~ T.stringof);
	static if (is(BASE_TYPE) && is(V))
	{
		enum ALLOC_SIZE = (V.sizeof + BASE_TYPE.sizeof-1) / BASE_TYPE.sizeof;
	}
}

/// Allocator proxy which injects custom code after object creation.
/// Context of INIT_CODE:
///   p - newly-allocated value.
mixin template InitializingAllocatorProxy(string INIT_CODE, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	RefType!T allocate(T)()
	{
		auto p = mixin(ALLOCATOR_EXPR).allocate!T();
		mixin(INIT_CODE);
		return p;
	}

	// TODO: Proxy other methods
}

/// Allocator proxy which keeps track how many allocations were made.
mixin template StatAllocatorProxy(alias ALLOCATOR = heapAllocator)
{
    mixin AllocatorCommon;

	size_t allocated;

	RefType!T allocate(T)()
	{
		allocated += StorageType!T.sizeof;
		return mixin(ALLOCATOR_EXPR).allocate!T();
	}

	StorageType!T[] allocateMany(T)(size_t n)
	{
		allocated += n * StorageType!T.sizeof;
		return mixin(ALLOCATOR_EXPR).allocateMany!T(n);
	}

	// TODO: Proxy other methods
}

/// The internal unit allocation type of FreeListAllocator.
/// (Exposed to allow specializing underlying allocators on it.)
template FreeListNode(T)
{
	mixin AllocTypes;

	mixin template NodeContents()
	{
		FreeListNode* next; /// Next free node
		V data;
	}

	debug
		struct FreeListNode
		{
			mixin NodeContents;
			static FreeListNode* fromRef(R r) { return cast(FreeListNode*)( (cast(ubyte*)r) - (data.offsetof) ); }
		}
	else
		union FreeListNode
		{
			mixin NodeContents;
			static FreeListNode* fromRef(R r) { return cast(FreeListNode*)r; }
		}
}


/// Homogenous linked list allocator.
/// Supports O(1) deletion.
/// Does not support bulk allocation.
mixin template FreeListAllocator(ALLOCATOR_TYPE, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	alias FreeListNode!ALLOCATOR_TYPE Node;

	Node* head = null; /// First free node

	RefType!T allocate(T)()
	{
		mixin AllocTypes;

		if (head is null)
		{
			auto node = mixin(ALLOCATOR_EXPR).allocate!Node();
			return cast(R)&node.data;
		}
		auto node = head;
		head = head.next;
		return cast(R)&node.data;
	}

	void free(R)(R r)
	{
		auto node = Node.fromRef(r);
		node.next = head;
		head = node;
	}
}

/// Backend allocator Allocates from D's managed heap directly.
mixin template HeapAllocator()
{
	RefType!T allocate(T)()
	{
		return new T;
	}

	StorageType!T[] allocateMany(T)(size_t n)
	{
		return new StorageType!T[n];
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

WrapMixin!HeapAllocator heapAllocator;

mixin template AllocateOneViaMany()
{
	RefType!T allocate(T)()
	{
		mixin AllocTypes;

		return cast(R)(allocateMany(1).ptr);
	}
}

mixin template FreeOneViaMany()
{
	void free(R)(R r)
	{
		mixin AllocTypes;

		freeMany((cast(V*)r)[0..1]);
	}
}

/// Backend allocator using the Data type from ae.sys.data.
mixin template DataAllocator()
{
	mixin AllocatorCommon;

	import ae.sys.data;

	// Needed to make data referenced in Data instances reachable by the GC
	Data[] datas; // TODO: use linked list or something

	StorageType!T[] allocateMany(T)(size_t n)
	{
		mixin AllocTypes;

		auto data = Data(V.sizeof * n);
		datas ~= data;
		return cast(V[])data.mcontents;
	}

	mixin AllocateOneViaMany;

	void freeAll()
	{
		foreach (data; datas)
			data.deleteContents();
		datas = null;
	}
}

mixin template GCRootAllocatorProxy(alias ALLOCATOR)
{
	mixin AllocatorCommon;

	import core.memory;

	StorageType!T[] allocateMany(T)(size_t n)
	{
		auto result = mixin(ALLOCATOR_EXPR).allocateMany!T(n);
		auto bytes = cast(ubyte[])result;
		GC.addRange(bytes.ptr, bytes.length);
		return result;
	}

	mixin AllocateOneViaMany;

	void freeMany(V)(V[] v)
	{
		GC.removeRange(v.ptr);
		mixin(ALLOCATOR_EXPR).freeMany(v);
	}

	mixin FreeOneViaMany;
}

/// Backend for direct OS page allocation.
mixin template PageAllocator()
{
	version(Windows)
		import std.c.windows.windows;
	else
	version(Posix)
		import core.sys.posix.sys.mman;

	StorageType!T[] allocateMany(T)(size_t n)
	{
		mixin AllocTypes;

		auto size = V.sizeof * n;

		version(Windows)
		{
			auto p = VirtualAlloc(null, size, MEM_COMMIT, PAGE_READWRITE);
		}
		else
		version(Posix)
		{
			auto p = mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
			p = (p == MAP_FAILED) ? null : p;
		}

		return (cast(V*)p)[0..n];
	}

	mixin AllocateOneViaMany;

	void freeMany(V)(V[] v)
	{
		mixin AllocTypes;

		version(Windows)
			VirtualFree(v.ptr, 0, MEM_RELEASE);
		else
		version(Posix)
			munmap(v.ptr, v.length * V.sizeof);
	}

	mixin FreeOneViaMany;
}

/// Common code for pointer-bumping allocators.
///
/// Context:
///   ptr - pointer to next free element
///   end - pointer to end of buffer
///   bufferExhausted - method called when ptr==end
///     (takes new size to allocate as parameter)
///   BLOCKSIZE - default parameter to bufferExhausted
mixin template PointerBumpCommon()
{
	/// Shared code for allocate / allocateMany.
	/// Context:
	///   Size - number of BASE_TYPE items to allocate
	///     (can be a constant or variable).
	private enum mixAllocateN =
	q{
		if (ptr + Size > end)
			bufferExhausted(Size > BLOCKSIZE ? Size : BLOCKSIZE);

		auto result = ptr[0..Size];
		ptr += Size;
	};

	RefType!T allocate(T)()
	{
		mixin AllocTypes;

		static if (ALLOC_SIZE == 1)
		{
			if (ptr==end)
				bufferExhausted(BLOCKSIZE);
			return cast(R)(ptr++);
		}
		else
		{
			enum Size = ALLOC_SIZE;
			mixin(mixAllocateN);
			return cast(R)result.ptr;
		}
	}

	StorageType!T[] allocateMany(T)(size_t n)
	{
		mixin AllocTypes;
		static assert(V.sizeof % BASE.sizeof == 0, "Aligned/contiguous allocation impossible");
		auto Size = ALLOC_SIZE * n;
		mixin(mixAllocateN);
		return cast(V[])result;
	}
}

/// Classic region.
/// Compose over another allocator to allocate values in bulk (minimum of BLOCKSIZE).
/// No deletion, but is slightly faster that FreeListAllocator.
/// BASE_TYPE indicates the type used for upstream allocations.
/// It is not possible to bulk-allocate types smaller than BASE_TYPE,
/// or those the size of which is not divisible by BASE_TYPE's size.
/// (This restriction allows for allocations of single BASE_TYPE-sized items to be
/// a little faster.)
// TODO: support non-bulk allocators (without allocateMany support)?
mixin template RegionAllocator(BASE_TYPE=void*, size_t BLOCKSIZE=1024, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	BASE_VALUE_TYPE* ptr=null, end=null;

	/// Forget we ever allocated anything
	void reset() { ptr=end=null; }

	private void newBlock(size_t size) // size counts BASE_VALUE_TYPE
	{
		BASE_VALUE_TYPE[] arr = mixin(ALLOCATOR_EXPR).allocateMany!BASE_TYPE(size);
		ptr = arr.ptr;
		end = ptr + arr.length;
	}

	alias newBlock bufferExhausted;
	mixin PointerBumpCommon;
}

/// Allocator proxy which keeps track of all allocations,
/// and implements freeAll by discarding them all at once
/// via the underlying allocator's freeMany.
mixin template TrackingAllocatorProxy(ALLOCATOR_TYPE, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	VALUE_TYPE[][] blocks; // TODO: use linked list or something

	VALUE_TYPE[] allocateMany(T)(size_t n)
	{
		mixin AllocTypes;

		VALUE_TYPE[] arr = mixin(ALLOCATOR_EXPR).allocateMany!ALLOCATOR_TYPE(n);
		blocks ~= arr;
		return arr;
	}

	RefType!T allocate(T)()
	{
		mixin AllocTypes;

		return cast(R)(allocateMany!T(1).ptr);
	}

	void freeAll()
	{
		foreach (block; blocks)
			mixin(ALLOCATOR_EXPR).freeMany(block);
		blocks = null;
	}
}

/// Growing buffer bulk allocator.
/// Allows reusing the same buffer, which is grown and retained as needed.
/// Requires .resize support from underlying allocator.
/// Smaller buffers are discarded (neither freed nor reused).
mixin template GrowingBufferAllocator(BASE_TYPE=void*, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	BASE_VALUE_TYPE* buf, ptr, end;

	void bufferExhausted(size_t n)
	{
		import std.algorithm;
		auto newSize = max(4096 / BASE_VALUE_TYPE.sizeof, (end-buf)*2, n);
		auto pos = ptr - buf;
		auto arr = mixin(ALLOCATOR_EXPR).resize(buf[0..end-buf], newSize);
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

/// Thrown when the buffer of an allocator is exhausted.
class BufferExhaustedException : Exception { this() { super("Allocator buffer exhausted"); } }

/// Homogenous allocator which uses a given buffer.
/// Throws BufferExhaustedException if the buffer is exhausted.
mixin template BufferAllocator(BASE_TYPE=ubyte)
{
	mixin AllocatorCommon;

	void setBuffer(BASE_VALUE_TYPE[] buf)
	{
		ptr = buf.ptr;
		end = ptr + buf.length;
	}

	this(BASE_VALUE_TYPE[] buf) { setBuffer(buf); }

	BASE_VALUE_TYPE* ptr=null, end=null;

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
mixin template StaticBufferAllocator(size_t SIZE, BASE_TYPE=ubyte)
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
/// ALLOCATOR is the fallback allocator.
mixin template HybridBufferAllocator(size_t SIZE, BASE_TYPE=ubyte, alias ALLOCATOR=heapAllocator)
{
	mixin AllocatorCommon;

	BASE_VALUE_TYPE[SIZE] buffer;
	BASE_VALUE_TYPE* ptr, end;

	void initialize()
	{
		ptr = buffer.ptr;
		end = buffer.ptr + buffer.length;
	}

	void bufferExhausted(size_t n)
	{
		auto arr = mixin(ALLOCATOR_EXPR).allocateMany!BASE_TYPE(n);
		ptr = arr.ptr;
		end = ptr + arr.length;
	}

	enum BLOCKSIZE = SIZE;
	mixin PointerBumpCommon;

	static if (is(typeof(&mixin(ALLOCATOR_EXPR).clear)))
	{
		void clear()
		{
			if (end == buffer.ptr + buffer.length)
				ptr = buffer.ptr;
			else
				mixin(ALLOCATOR_EXPR).clear();
		}
	}
}

unittest
{
	static class C { int x=2; this() {} this(int p) { x = p; } }

	void testAllocator(A, string INIT="")()
	{
		A a;
		mixin(INIT);
		auto c1 = a.create!C();
		assert(c1.x == 2);

		auto c2 = a.create!C(5);
		assert(c2.x == 5);
	}

	testAllocator!(WrapMixin!(HeapAllocator))();
	testAllocator!(WrapMixin!(FreeListAllocator, C))();
	testAllocator!(WrapMixin!(GrowingBufferAllocator))();
	testAllocator!(WrapMixin!(HybridBufferAllocator, 1024))();
}
