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
 * Most allocators have two parts: data and implementation. The split is
 * done to allow all implementation layers to share the same "this"
 * pointer. Each "Impl" part takes its "data" part as an alias.
 *
 * The underlying allocator (or its implementation instantiation) is
 * passed in as an alias template parameter. This means that it has to be
 * a symbol, the address of which is known in the scope of the allocator
 * - thus, something scoped in the same class/struct, or a global variable.
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

/// Generates code to create forwarding aliases to the given mixin/template member.
/// Used as a replacement for "alias M this", which doesn't seem to work with mixins
/// and templates.
static template mixAliasForward(alias M, string name = __traits(identifier, M))
{
	static string mixAliasForward()
	{
		import std.string, std.algorithm;
		return [__traits(allMembers, M)]
			.filter!(n => n.length)
			.map!(n => "alias %s.%s %s;\n".format(name, n, n))
			.join();
	}
}

/// Instantiates a struct from a type containing a Data/Impl template pair.
struct WrapParts(T)
{
	T.Data data;
	alias impl = T.Impl!data;
//	pragma(msg, __traits(identifier, impl));
//	pragma(msg, mixAliasForward!(impl, q{impl}));

	mixin({
		import std.string, std.algorithm, std.range;
		return
			chain(
				[__traits(allMembers, T.Impl!data)]
				.filter!(n => n.length)
				.map!(n => "alias %s.%s %s;\n".format("impl", n, n))
			,
				[__traits(allMembers, T)]
				.filter!(n => n.length)
				.filter!(n => n != "Impl")
				.filter!(n => n != "Data")
				.map!(n => "alias %s.%s %s;\n".format("T", n, n))
			)
			.join()
		;}()
	);
}

/// Creates a template which, when instantiated, forwards its arguments to T
/// and uses WrapParts on the result.
template PartsWrapper(alias T)
{
	template PartsWrapper(Args...)
	{
		alias PartsWrapper = WrapParts!(T!Args);
	}
}

// TODO:
// - GROWFUN callable alias parameter instead of BLOCKSIZE?
// - Consolidate RegionAllocator and GrowingBufferAllocator
// - Add new primitive for bulk allocation which returns a range?
//   (to allow non-contiguous bulk allocation, but avoid
//   allocating an array of pointers to store the result)
// - Forbid allocating types with indirections when the base type
//   is not a pointer?
// - More thorough testing

/// Common declarations for an allocator mixin
mixin template AllocatorCommon()
{
	alias ae.utils.alloc.StorageType StorageType;

	static if (is(ALLOCATOR_TYPE))
		alias StorageType!ALLOCATOR_TYPE VALUE_TYPE;

	static if (is(BASE_TYPE))
		alias StorageType!BASE_TYPE BASE_VALUE_TYPE;
}

/// Default "create" implementation.
RefType!T create(T, A, Args...)(ref A a, Args args)
	if (is(typeof(a.allocate!T())))
{
	alias StorageType!T V;

	auto r = a.allocate!T();
	emplace!T(cast(void[])((cast(V*)r)[0..1]), args);
	return r;
}

void destroy(R, A)(ref A a, R r)
//	TODO: contract
{
	clear(r);
	static if (is(typeof(&a.free)))
		a.free(r);
}

/// Creates T/R/V aliases from context, and checks ALLOCATOR_TYPE if appropriate.
mixin template AllocTypes()
{
	static if (is(R) && !is(T)) alias FromRefType!R T;
	static if (is(T) && !is(R)) alias RefType!T R;
	static if (is(T) && !is(V)) alias StorageType!T V;
	static if (is(ALLOCATOR_TYPE)) static assert(is(ALLOCATOR_TYPE==T), "This allocator can "
		"only allocate instances of " ~ ALLOCATOR_TYPE.stringof ~ ", not " ~ T.stringof);
	static if (is(BASE_TYPE) && is(V))
	{
		enum ALLOC_SIZE = (V.sizeof + BASE_TYPE.sizeof-1) / BASE_TYPE.sizeof;
	}
}

/// Allocator proxy which injects custom code after object creation.
/// Context of INIT_CODE:
///   p - newly-allocated value.
struct InitializingAllocatorProxy(string INIT_CODE, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	RefType!T allocate(T)()
	{
		auto p = ALLOCATOR.allocate!T();
		mixin(INIT_CODE);
		return p;
	}

	// TODO: Proxy other methods
}

/// Allocator proxy which keeps track how many allocations were made.
struct StatAllocatorProxy(alias ALLOCATOR = heapAllocator)
{
    mixin AllocatorCommon;

	size_t allocated;

	RefType!T allocate(T)()
	{
		allocated += StorageType!T.sizeof;
		return ALLOCATOR.allocate!T();
	}

	StorageType!T[] allocateMany(T)(size_t n)
	{
		allocated += n * StorageType!T.sizeof;
		return ALLOCATOR.allocateMany!T(n);
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
		V data;
		FreeListNode* next; /// Next free node
		static FreeListNode* fromRef(R r) { return cast(FreeListNode*)r; }
	}

	debug
		struct FreeListNode { mixin NodeContents; }
	else
		union  FreeListNode { mixin NodeContents; }
}


/// Homogenous linked list allocator.
/// Supports O(1) deletion.
/// Does not support bulk allocation.
struct FreeListAllocator(ALLOCATOR_TYPE, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	alias FreeListNode!ALLOCATOR_TYPE Node;

	struct Data
	{
		Node* head = null; /// First free node
	}

	static template Impl(alias data)
	{
		RefType!T allocate(T)()
		{
			mixin AllocTypes;

			if (data.head is null)
			{
				auto node = ALLOCATOR.allocate!Node();
				return cast(R)&node.data;
			}
			auto node = data.head;
			data.head = data.head.next;
			return cast(R)&node.data;
		}

		void free(R)(R r)
		{
			auto node = Node.fromRef(r);
			node.next = data.head;
			data.head = node;
		}
	}
}

/// Backend allocator Allocates from D's managed heap directly.
struct HeapAllocator
{
// static: // https://d.puremagic.com/issues/show_bug.cgi?id=12207
const:
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

immutable HeapAllocator heapAllocator;

RefType!T allocate(T, A)(ref A a)
	if (is(typeof(&a.allocateMany!T)))
{
	return cast(RefType!T)(a.allocateMany!T(1).ptr);
}

void free(A, R)(ref A a, R r)
	if (is(typeof(&a.freeMany)))
{
	a.freeMany((cast(V*)r)[0..1]);
}

/// Backend allocator using the Data type from ae.sys.data.
struct DataAllocator
{
	mixin AllocatorCommon;

	import ae.sys.data : SysData = Data;

	struct Data
	{
		// Needed to make data referenced in Data instances reachable by the GC
		SysData[] datas; // TODO: use linked list or something
	}

	static template Impl(alias data)
	{
		StorageType!T[] allocateMany(T)(size_t n)
		{
			mixin AllocTypes;

			auto sysData = SysData(V.sizeof * n);
			data.datas ~= sysData;
			return cast(V[])sysData.mcontents;
		}

		void freeAll()
		{
			foreach (sysData; data.datas)
				sysData.deleteContents();
			data.datas = null;
		}
	}
}

struct GCRootAllocatorProxy(alias ALLOCATOR)
{
	mixin AllocatorCommon;

	import core.memory;

	StorageType!T[] allocateMany(T)(size_t n)
	{
		auto result = ALLOCATOR.allocateMany!T(n);
		auto bytes = cast(ubyte[])result;
		GC.addRange(bytes.ptr, bytes.length);
		return result;
	}

	void freeMany(V)(V[] v)
	{
		GC.removeRange(v.ptr);
		ALLOCATOR.freeMany(v);
	}
}

/// Backend for direct OS page allocation.
struct PageAllocator
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

	void freeMany(V)(V[] v)
	{
		mixin AllocTypes;

		version(Windows)
			VirtualFree(v.ptr, 0, MEM_RELEASE);
		else
		version(Posix)
			munmap(v.ptr, v.length * V.sizeof);
	}
}

/// Common code for pointer-bumping allocator implementations.
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
	///   data - alias to struct holding ptr and end
	///   Size - number of BASE_TYPE items to allocate
	///     (can be a constant or variable).
	private enum mixAllocateN =
	q{
		if (data.ptr + Size > data.end)
			bufferExhausted(Size > BLOCKSIZE ? Size : BLOCKSIZE);

		auto result = data.ptr[0..Size];
		data.ptr += Size;
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
struct RegionAllocator(BASE_TYPE=void*, size_t BLOCKSIZE=1024, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	struct Data
	{
		BASE_VALUE_TYPE* ptr=null, end=null;
	}

	static template Impl(alias data)
	{
		/// Forget we ever allocated anything
		void reset() { data.ptr=data.end=null; }

		private void newBlock(size_t size) // size counts BASE_VALUE_TYPE
		{
			BASE_VALUE_TYPE[] arr = ALLOCATOR.allocateMany!BASE_TYPE(size);
			data.ptr = arr.ptr;
			data.end = data.ptr + arr.length;
		}

		alias newBlock bufferExhausted;
		mixin PointerBumpCommon;
	}
}

/// Allocator proxy which keeps track of all allocations,
/// and implements freeAll by discarding them all at once
/// via the underlying allocator's freeMany.
struct TrackingAllocatorProxy(ALLOCATOR_TYPE, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	struct Data
	{
		VALUE_TYPE[][] blocks; // TODO: use linked list or something
	}

	static template Impl(alias data)
	{
		VALUE_TYPE[] allocateMany(T)(size_t n)
		{
			mixin AllocTypes;

			VALUE_TYPE[] arr = ALLOCATOR.allocateMany!ALLOCATOR_TYPE(n);
			data.blocks ~= arr;
			return arr;
		}

		RefType!T allocate(T)()
		{
			mixin AllocTypes;

			return cast(R)(allocateMany!T(1).ptr);
		}

		void freeAll()
		{
			foreach (block; data.blocks)
				ALLOCATOR.freeMany(block);
			data.blocks = null;
		}
	}
}

/// Growing buffer bulk allocator.
/// Allows reusing the same buffer, which is grown and retained as needed.
/// Requires .resize support from underlying allocator.
/// Smaller buffers are discarded (neither freed nor reused).
struct GrowingBufferAllocator(BASE_TYPE=void*, alias ALLOCATOR = heapAllocator)
{
	mixin AllocatorCommon;

	struct Data
	{
		BASE_VALUE_TYPE* buf, ptr, end;
	}

	static template Impl(alias data)
	{
		void bufferExhausted(size_t n)
		{
			import std.algorithm;
			auto newSize = max(4096 / BASE_VALUE_TYPE.sizeof, (data.end-data.buf)*2, n);
			auto pos = data.ptr - data.buf;
			auto arr = ALLOCATOR.resize(data.buf[0..data.end-data.buf], newSize);
			data.buf = arr.ptr;
			data.end = data.buf + arr.length;
			data.ptr = data.buf + pos;
		}

		void clear()
		{
			data.ptr = data.buf;
		}

		enum BLOCKSIZE=0;
		mixin PointerBumpCommon;
	}
}

/// Thrown when the buffer of an allocator is exhausted.
class BufferExhaustedException : Exception { this() { super("Allocator buffer exhausted"); } }

/// Homogenous allocator which uses a given buffer.
/// Throws BufferExhaustedException if the buffer is exhausted.
struct BufferAllocator(BASE_TYPE=ubyte)
{
	mixin AllocatorCommon;

	struct Data
	{
		BASE_VALUE_TYPE* ptr=null, end=null;
	}

	static template Impl(alias data)
	{
		void setBuffer(BASE_VALUE_TYPE[] buf)
		{
			data.ptr = buf.ptr;
			data.end = data.ptr + buf.length;
		}

		this(BASE_VALUE_TYPE[] buf) { setBuffer(buf); }

		static void bufferExhausted(size_t n)
		{
			throw new BufferExhaustedException();
		}

		enum BLOCKSIZE=0;
		mixin PointerBumpCommon;
	}
}

/// Homogenous allocator which uses a static buffer of a given size.
/// Throws BufferExhaustedException if the buffer is exhausted.
/// Needs to be manually initialized before use.
struct StaticBufferAllocator(size_t SIZE, BASE_TYPE=ubyte)
{
	mixin AllocatorCommon;

	struct Data
	{
		StorageType!BASE_TYPE[SIZE] buffer;
		StorageType!BASE_TYPE* ptr;
		@property StorageType!BASE_TYPE* end() { return buffer.ptr + buffer.length; }
	}

	static template Impl(alias data)
	{
		void initialize()
		{
			data.ptr = data.buffer.ptr;
		}

		void bufferExhausted(size_t n)
		{
			throw new BufferExhaustedException();
		}

		enum BLOCKSIZE=0;
		mixin PointerBumpCommon;

		alias initialize clear;
	}
}

/// A bulk allocator which behaves like a StaticBufferAllocator initially,
/// but once the static buffer is exhausted, it switches to a fallback
/// bulk allocator.
/// Needs to be manually initialized before use.
/// ALLOCATOR is the fallback allocator.
struct HybridBufferAllocator(size_t SIZE, BASE_TYPE=ubyte, alias ALLOCATOR=heapAllocator)
{
	mixin AllocatorCommon;

	struct Data
	{
		BASE_VALUE_TYPE[SIZE] buffer;
		BASE_VALUE_TYPE* ptr, end;
	}

	static template Impl(alias data)
	{
		void initialize()
		{
			data.ptr = data.buffer.ptr;
			data.end = data.buffer.ptr + data.buffer.length;
		}

		void bufferExhausted(size_t n)
		{
			auto arr = ALLOCATOR.allocateMany!BASE_TYPE(n);
			data.ptr = arr.ptr;
			data.end = data.ptr + arr.length;
		}

		enum BLOCKSIZE = SIZE;
		mixin PointerBumpCommon;

		static if (is(typeof(&ALLOCATOR.clear)))
		{
			void clear()
			{
				if (data.end == data.buffer.ptr + data.buffer.length)
					data.ptr = data.buffer.ptr;
				else
					ALLOCATOR.clear();
			}
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

	testAllocator!(WrapParts!(FreeListAllocator!C))();
	testAllocator!(           HeapAllocator)();
	testAllocator!(WrapParts!(DataAllocator))();
	testAllocator!(           PageAllocator)();
	testAllocator!(WrapParts!(RegionAllocator!()))();
	testAllocator!(WrapParts!(GrowingBufferAllocator!()))();
	testAllocator!(WrapParts!(StaticBufferAllocator!1024), q{a.initialize();})();
	testAllocator!(WrapParts!(HybridBufferAllocator!1024))();
}
