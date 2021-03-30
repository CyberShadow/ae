/**
 * Wrappers for raw _data located in unmanaged memory.
 *
 * Using the Data type will only place a small object in managed memory,
 * keeping the actual _data in unmanaged memory.
 * A proxy class (DataWrapper) is used to safely allow multiple references to
 * the same block of unmanaged memory.
 * When the DataWrapper object is destroyed (either manually or by the garbage
 * collector when there are no remaining Data references), the unmanaged
 * memory is deallocated.
 *
 * This has the following advantage over using managed memory:
 * $(UL
 *  $(LI Faster allocation and deallocation, since memory is requested from
 *       the OS directly as whole pages)
 *  $(LI Greatly reduced chance of memory leaks (on 32-bit platforms) due to
 *       stray pointers)
 *  $(LI Overall improved GC performance due to reduced size of managed heap)
 *  $(LI Memory is immediately returned to the OS when _data is deallocated)
 * )
 * On the other hand, using Data has the following disadvantages:
 * $(UL
 *  $(LI This module is designed to store raw _data which does not have any
 *       pointers. Storing objects containing pointers to managed memory is
 *       unsupported, and may result in memory corruption.)
 *  $(LI Small objects may be stored inefficiently, as the module requests
 *       entire pages of memory from the OS. Considering allocating one large
 *       object and use slices (Data instances) for individual objects.)
 *  $(LI Incorrect usage (i.e. retaining/escaping references to wrapped memory
 *       without keeping a reference to its corresponding DataWrapper) can
 *       result in dangling pointers and hard-to-debug memory corruption.)
 * )
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.data;

static import core.stdc.stdlib;
import core.stdc.string : memmove;
import std.traits;
import core.memory;
import core.exception;
debug import std.string;
public import ae.sys.dataset;
import ae.utils.math;

debug(DATA) import core.stdc.stdio;

// ideas/todo:
// * templatize (and forbid using aliased types)?
// * use heap (malloc/Windows heap API) for small objects?
// * reference counting?
// * "immutable" support?

/**
 * Wrapper for data located in external memory, to prevent faux references.
 * Represents a slice of data, which may or may not be in unmanaged memory.
 * Data in unmanaged memory is bound to a DataWrapper class instance.
 *
 * All operations on this class should be safe, except for accessing contents directly.
 * All operations on contents must be accompanied by a live reference to the Data object,
 * to keep a GC anchor towards the unmanaged data.
 *
 * Concatenations and appends to Data contents will cause reallocations on the heap, consider using Data instead.
 *
 * Be sure not to lose Data references while using their contents!
 * For example, avoid code like this:
 * ----
 * fun(cast(string)transformSomeData(someData).contents);
 * ----
 * The Data return value may be unreachable once .contents is evaluated.
 * Use .toHeap instead of .contents in such cases to get a safe heap copy.
 */
struct Data
{
private:
	/// Wrapped data
	const(void)[] _contents;
	/// Reference to the wrapper of the actual data - may be null to indicate wrapped data in managed memory.
	/// Used as a GC anchor to unmanaged data, and for in-place expands (for appends).
	DataWrapper wrapper;
	/// Indicates whether we're allowed to modify the data contents.
	bool mutable;

	/// Maximum preallocation for append operations.
	enum { MAX_PREALLOC = 4*1024*1024 } // must be power of 2

public:
	/**
	 * Create new instance wrapping the given data.
	 * Params:
	 *   data = initial data
	 *   forceReallocation = when false, the contents will be duplicated to
	 *     unmanaged memory only when it's not on the managed heap; when true,
	 *     the contents will be reallocated always.
	 */
	this(const(void)[] data, bool forceReallocation = false)
	{
		if (data is null)
			contents = null;
		else
		if (data.length == 0)
		{
			wrapper = emptyDataWrapper;
			wrapper.references++;
			contents = data;
		}
		else
		if (forceReallocation || GC.addrOf(data.ptr) is null)
		{
			// copy to unmanaged memory
			auto wrapper = unmanagedNew!MemoryDataWrapper(data.length, data.length);
			this.wrapper = wrapper;
			wrapper.contents[] = data[];
			contents = wrapper.contents;
			mutable = true;
		}
		else
		{
			// just save a reference
			contents = data;
			mutable = false;
		}

		assert(this.length == data.length);
	}

	/// ditto
	this(void[] data, bool forceReallocation = false)
	{
		const(void)[] cdata = data;
		this(cdata, forceReallocation);
		mutable = true;
	}

	/// Create a new instance with given size/capacity. Capacity defaults to size.
	this(size_t size, size_t capacity = 0)
	in
	{
		assert(capacity == 0 || size <= capacity);
	}
	do
	{
		if (!capacity)
			capacity = size;

		if (capacity)
		{
			auto wrapper = unmanagedNew!MemoryDataWrapper(size, capacity);
			this.wrapper = wrapper;
			contents = wrapper.contents;
			mutable = true;
		}
		else
		{
			wrapper = null;
			contents = null;
		}

		assert(this.length == size);
	}

	this(DataWrapper wrapper, bool mutable)
	{
		this.wrapper = wrapper;
		this.mutable = mutable;
		this.contents = wrapper.contents;
	}

	this(this)
	{
		if (wrapper)
		{
			wrapper.references++;
			debug (DATA_REFCOUNT) debugLog("%p -> %p: Incrementing refcount to %d", cast(void*)&this, cast(void*)wrapper, wrapper.references);
		}
		else
			debug (DATA_REFCOUNT) debugLog("%p -> %p: this(this) with no wrapper", cast(void*)&this, cast(void*)wrapper);
	}

	~this() pure
	{
		//clear();
		// https://issues.dlang.org/show_bug.cgi?id=13809
		(cast(void delegate() pure)&clear)();
	}

	debug(DATA) invariant
	{
		if (wrapper)
			assert(wrapper.references > 0, "Data referencing DataWrapper with bad reference count");
	}

/*
	/// Create new instance as a slice over an existing DataWrapper.
	private this(DataWrapper wrapper, size_t start = 0, size_t end = size_t.max)
	{
		this.wrapper = wrapper;
		this.start = start;
		this.end = end==size_t.max ? wrapper.capacity : end;
	}
*/

	@property const(void)[] contents() const
	{
		return _contents;
	}

	@property private const(void)[] contents(const(void)[] data)
	{
		return _contents = data;
	}

	/// Get mutable contents
	@property void[] mcontents()
	{
		if (!mutable && length)
		{
			reallocate(length, length);
			assert(mutable);
		}
		return cast(void[])_contents;
	}

	@property const(void)* ptr() const
	{
		return contents.ptr;
	}

	@property void* mptr()
	{
		return mcontents.ptr;
	}

	@property size_t length() const
	{
		return contents.length;
	}

	@property bool empty() const
	{
		return contents is null;
	}

	bool opCast(T)() const
		if (is(T == bool))
	{
		return !empty;
	}

	@property size_t capacity() const
	{
		if (wrapper is null)
			return length;
		// We can only safely expand if the memory slice is at the end of the used unmanaged memory block.
		auto pos = ptr - wrapper.contents.ptr; // start position in wrapper data
		auto end = pos + length;               // end   position in wrapper data
		assert(end <= wrapper.size);
		if (end == wrapper.size && end < wrapper.capacity)
			return wrapper.capacity - pos;
		else
			return length;
	}

	/// Put a copy of the data on D's managed heap, and return it.
	@property
	void[] toHeap() const
	{
		return _contents.dup;
	}

	private void reallocate(size_t size, size_t capacity)
	{
		auto wrapper = unmanagedNew!MemoryDataWrapper(size, capacity);
		wrapper.contents[0..this.length] = contents[];
		//(cast(ubyte[])newWrapper.contents)[this.length..value] = 0;

		clear();
		this.wrapper = wrapper;
		this.contents = wrapper.contents;
		mutable = true;
	}

	private void expand(size_t newSize, size_t newCapacity)
	in
	{
		assert(length < newSize);
		assert(newSize <= newCapacity);
	}
	out
	{
		assert(length == newSize);
	}
	do
	{
		if (newCapacity <= capacity)
		{
			auto pos = ptr - wrapper.contents.ptr; // start position in wrapper data
			wrapper.setSize(pos + newSize);
			contents = ptr[0..newSize];
		}
		else
			reallocate(newSize, newCapacity);
	}

	@property void length(size_t value)
	{
		if (value == length) // no change
			return;
		if (value < length)  // shorten
			_contents = _contents[0..value];
		else                 // lengthen
			expand(value, value);
	}
	alias length opDollar;

	@property Data dup() const
	{
		return Data(contents, true);
	}

	/// This used to be an unsafe method which deleted the wrapped data.
	/// Now that Data is refcounted, this simply calls clear() and
	/// additionally asserts that this Data is the only Data holding
	/// a reference to the wrapper.
	void deleteContents()
	out
	{
		assert(wrapper is null);
	}
	do
	{
		if (wrapper)
		{
			assert(wrapper.references == 1, "Attempting to call deleteContents with ");
			clear();
		}
	}

	void clear()
	{
		if (wrapper)
		{
			assert(wrapper.references > 0, "Dangling pointer to wrapper");
			wrapper.references--;
			debug (DATA_REFCOUNT) debugLog("%p -> %p: Decrementing refcount to %d", cast(void*)&this, cast(void*)wrapper, wrapper.references);
			if (wrapper.references == 0)
				wrapper.destroy();

			wrapper = null;
		}

		contents = null;
	}

	Data concat(const(void)[] data)
	{
		if (data.length==0)
			return this;
		Data result = Data(length + data.length);
		result.mcontents[0..this.length] = contents[];
		result.mcontents[this.length..$] = data[];
		return result;
	}

	template opBinary(string op) if (op == "~")
	{
		Data opBinary(T)(const(T)[] data)
		if (!hasIndirections!T)
		{
			return concat(data);
		}

		Data opBinary()(Data data)
		{
			return concat(data.contents);
		}
	}

	Data prepend(const(void)[] data)
	{
		Data result = Data(data.length + length);
		result.mcontents[0..data.length] = data[];
		result.mcontents[data.length..$] = contents[];
		return result;
	}

	template opBinaryRight(string op) if (op == "~")
	{
		Data opBinaryRight(T)(const(T)[] data)
		if (!hasIndirections!T)
		{
			return prepend(data);
		}
	}

	private static size_t getPreallocSize(size_t length)
	{
		if (length < MAX_PREALLOC)
			return nextPowerOfTwo(length);
		else
			return ((length-1) | (MAX_PREALLOC-1)) + 1;
	}

	Data append(const(void)[] data)
	{
		if (data.length==0)
			return this;
		size_t oldLength = length;
		size_t newLength = length + data.length;
		expand(newLength, getPreallocSize(newLength));
		auto newContents = cast(void[])_contents[oldLength..$];
		newContents[] = (cast(void[])data)[];
		return this;
	}

	/// Note that unlike concatenation (a ~ b), appending (a ~= b) will preallocate.
	template opOpAssign(string op) if (op == "~")
	{
		Data opOpAssign(T)(const(T)[] data)
		if (!hasIndirections!T)
		{
			return append(data);
		}

		Data opOpAssign()(Data data)
		{
			return append(data.contents);
		}

		Data opOpAssign()(ubyte value) // hack?
		{
			return append((&value)[0..1]);
		}
	}

	Data opSlice()
	{
		return this;
	}

	Data opSlice(size_t x, size_t y)
	in
	{
		assert(x <= y);
		assert(y <= length);
	}
// https://issues.dlang.org/show_bug.cgi?id=13463
//	out(result)
//	{
//		assert(result.length == y-x);
//	}
	do
	{
		if (x == y)
			return Data(emptyDataWrapper.data[]);
		else
		{
			Data result = this;
			result.contents = result.contents[x..y];
			return result;
		}
	}

	/// Return a new Data for the first size bytes, and slice this instance from size to end.
	Data popFront(size_t size)
	in
	{
		assert(size <= length);
	}
	do
	{
		Data result = this;
		result.contents = contents[0..size];
		this  .contents = contents[size..$];
		return result;
	}
}

unittest
{
	Data d = Data("aaaaa");
	assert(d.wrapper.references == 1);
	Data s = d[1..4];
	assert(d.wrapper.references == 2);
}

// ************************************************************************

static /*thread-local*/ size_t dataMemory, dataMemoryPeak;
static /*thread-local*/ uint   dataCount, allocCount;

// Abstract wrapper.
abstract class DataWrapper
{
	sizediff_t references = 1;
	abstract @property inout(void)[] contents() inout;
	abstract @property size_t size() const;
	abstract void setSize(size_t newSize);
	abstract @property size_t capacity() const;

	debug ~this()
	{
		debug(DATA_REFCOUNT) debugLog("%.*s.~this, references==%d", this.classinfo.name.length, this.classinfo.name.ptr, references);
		assert(references == 0, "Deleting DataWrapper with non-zero reference count");
	}
}

void setGCThreshold(size_t value) { MemoryDataWrapper.collectThreshold = value; }

C unmanagedNew(C, Args...)(auto ref Args args)
if (is(C == class))
{
	import std.conv : emplace;
	enum size = __traits(classInstanceSize, C);
	auto p = unmanagedAlloc(size);
	emplace!C(p[0..size], args);
	return cast(C)p;
}

void unmanagedDelete(C)(C c)
if (is(C == class))
{
	c.__xdtor();
	unmanagedFree(p);
}

private:

void* unmanagedAlloc(size_t sz)
{
	auto p = core.stdc.stdlib.malloc(sz);

	debug(DATA_REFCOUNT) debugLog("? -> %p: Allocating via malloc (%d bytes)", p, cast(uint)sz);

	if (!p)
		throw new OutOfMemoryError();

	//GC.addRange(p, sz);
	return p;
}

void unmanagedFree(void* p) @nogc
{
	if (p)
	{
		debug(DATA_REFCOUNT) debugLog("? -> %p: Deleting via free", p);

		//GC.removeRange(p);
		core.stdc.stdlib.free(p);
	}
}

version (Windows)
	import core.sys.windows.windows;
else
{
	import core.sys.posix.unistd;
	import core.sys.posix.sys.mman;
}

/// Wrapper for data in RAM, allocated from the OS.
final class MemoryDataWrapper : DataWrapper
{
	/// Pointer to actual data.
	void* data;
	/// Used size. Needed for safe appends.
	size_t _size;
	/// Allocated capacity.
	size_t _capacity;

	/// Threshold of allocated memory to trigger a collect.
	__gshared size_t collectThreshold = 8*1024*1024; // 8MB
	/// Counter towards the threshold.
	static /*thread-local*/ size_t allocatedThreshold;

	/// Create a new instance with given capacity.
	this(size_t size, size_t capacity)
	{
		data = malloc(/*ref*/ capacity);
		if (data is null)
		{
			debug(DATA) fprintf(stderr, "Garbage collect triggered by failed Data allocation of %llu bytes... ", cast(ulong)capacity);
			GC.collect();
			debug(DATA) fprintf(stderr, "Done\n");
			data = malloc(/*ref*/ capacity);
			allocatedThreshold = 0;
		}
		if (data is null)
			onOutOfMemoryError();

		dataMemory += capacity;
		if (dataMemoryPeak < dataMemory)
			dataMemoryPeak = dataMemory;
		dataCount ++;
		allocCount ++;

		this._size = size;
		this._capacity = capacity;

		// also collect
		allocatedThreshold += capacity;
		if (allocatedThreshold > collectThreshold)
		{
			debug(DATA) fprintf(stderr, "Garbage collect triggered by total allocated Data exceeding threshold... ");
			GC.collect();
			debug(DATA) fprintf(stderr, "Done\n");
			allocatedThreshold = 0;
		}
	}

	/// Destructor - destroys the wrapped data.
	~this()
	{
		free(data, capacity);
		data = null;
		// If DataWrapper is created and manually deleted, there is no need to cause frequent collections
		if (allocatedThreshold > capacity)
			allocatedThreshold -= capacity;
		else
			allocatedThreshold = 0;

		dataMemory -= capacity;
		dataCount --;
	}

	@property override
	size_t size() const { return _size; }

	@property override
	size_t capacity() const { return _capacity; }

	override void setSize(size_t newSize)
	{
		assert(newSize <= capacity);
		_size = newSize;
	}

	@property override
	inout(void)[] contents() inout
	{
		return data[0..size];
	}

	// https://github.com/D-Programming-Language/druntime/pull/759
	version(OSX)
		enum _SC_PAGE_SIZE = 29;

	// https://github.com/D-Programming-Language/druntime/pull/1140
	version(FreeBSD)
		enum _SC_PAGE_SIZE = 47;

	version(Windows)
	{
		static immutable size_t pageSize;

		shared static this()
		{
			SYSTEM_INFO si;
			GetSystemInfo(&si);
			pageSize = si.dwPageSize;
		}
	}
	else
	static if (is(typeof(_SC_PAGE_SIZE)))
	{
		static immutable size_t pageSize;

		shared static this()
		{
			pageSize = sysconf(_SC_PAGE_SIZE);
		}
	}

	static void* malloc(ref size_t size)
	{
		if (is(typeof(pageSize)))
			size = ((size-1) | (pageSize-1))+1;

		version(Windows)
		{
			return VirtualAlloc(null, size, MEM_COMMIT, PAGE_READWRITE);
		}
		else
		version(Posix)
		{
			version(linux)
				import core.sys.linux.sys.mman : MAP_ANON;
			auto p = mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
			return (p == MAP_FAILED) ? null : p;
		}
		else
			return core.stdc.malloc(size);
	}

	static void free(void* p, size_t size)
	{
		debug
		{
			(cast(ubyte*)p)[0..size] = 0xDB;
		}
		version(Windows)
			VirtualFree(p, 0, MEM_RELEASE);
		else
		version(Posix)
			munmap(p, size);
		else
			core.stdc.free(size);
	}
}

// ************************************************************************

/// DataWrapper implementation used for the empty (but non-null) Data slice.
class EmptyDataWrapper : DataWrapper
{
	void[0] data;

	override @property inout(void)[] contents() inout { return data[]; }
	override @property size_t size() const { return data.length; }
	override void setSize(size_t newSize) { assert(false); }
	override @property size_t capacity() const { return data.length; }
}

__gshared EmptyDataWrapper emptyDataWrapper = new EmptyDataWrapper;

// ************************************************************************

// Source: Win32 bindings project
version(Windows)
{
	struct SYSTEM_INFO {
		union {
			DWORD dwOemId;
			struct {
				WORD wProcessorArchitecture;
				WORD wReserved;
			}
		}
		DWORD dwPageSize;
		PVOID lpMinimumApplicationAddress;
		PVOID lpMaximumApplicationAddress;
		DWORD dwActiveProcessorMask;
		DWORD dwNumberOfProcessors;
		DWORD dwProcessorType;
		DWORD dwAllocationGranularity;
		WORD  wProcessorLevel;
		WORD  wProcessorRevision;
	}
	alias SYSTEM_INFO* LPSYSTEM_INFO;

	extern(Windows) VOID GetSystemInfo(LPSYSTEM_INFO);
}

debug(DATA_REFCOUNT) import ae.utils.exception, ae.sys.memory, std.stdio;

debug(DATA_REFCOUNT) void debugLog(Args...)(const char* s, Args args) @nogc
{
	fprintf(stderr, s, args);
	fprintf(stderr, "\n");
	if (inCollect())
		fprintf(stderr, "\t(in GC collect)\n");
	else
		(cast(void function() @nogc)&debugStackTrace)();
	fflush(core.stdc.stdio.stderr);
}

debug(DATA_REFCOUNT) void debugStackTrace()
{
	try
		foreach (line; getStackTrace())
			writeln("\t", line);
	catch (Throwable e)
		writeln("\t(stacktrace error: ", e.msg, ")");
}
