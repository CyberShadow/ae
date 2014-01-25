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
 * )
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

module ae.sys.data;

static import std.c.stdlib;
import std.c.string : memmove;
import std.traits;
import core.memory;
import core.exception;
debug(DATA) import std.stdio;
debug(DATA) import std.string;
public import ae.sys.dataset;
import ae.utils.math;

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
		if (data.length == 0)
			contents = null;
		else
		if (forceReallocation || GC.addrOf(data.ptr) is null)
		{
			// copy to unmanaged memory
			wrapper = new DataWrapper(data.length, data.length);
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
	this(size_t size = 0, size_t capacity = 0)
	in
	{
		assert(capacity == 0 || size <= capacity);
	}
	body
	{
		if (!capacity)
			capacity = size;

		if (capacity)
		{
			wrapper = new DataWrapper(size, capacity);
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

	bool opCast(T)()
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
		wrapper = new DataWrapper(size, capacity);
		wrapper.contents[0..this.length] = contents[];
		//(cast(ubyte[])newWrapper.contents)[this.length..value] = 0;
		contents = wrapper.contents;
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
	body
	{
		if (newCapacity <= capacity)
		{
			auto pos = ptr - wrapper.contents.ptr; // start position in wrapper data
			wrapper.size = pos + newSize;
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

	@property Data dup() const
	{
		return Data(contents, true);
	}

	/// UNSAFE! Use only when you know there is only one reference to the data.
	void deleteContents()
	out
	{
		assert(wrapper is null);
	}
	body
	{
		delete wrapper;
		contents = null;
	}

	void clear()
	{
		wrapper = null;
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

	Data opCat(T)(const(T)[] data)
		if (!hasIndirections!T)
	{
		return concat(data);
	}

	Data opCat()(Data data)
	{
		return concat(data.contents);
	}

	Data prepend(const(void)[] data)
	{
		Data result = Data(data.length + length);
		result.mcontents[0..data.length] = data[];
		result.mcontents[data.length..$] = contents[];
		return result;
	}

	Data opCat_r(T)(const(T)[] data)
		if (!hasIndirections!T)
	{
		return prepend(data);
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

	/// Note that unlike opCat (a ~ b), opCatAssign (a ~= b) will preallocate.
	Data opCatAssign(T)(const(T)[] data)
		if (!hasIndirections!T)
	{
		return append(data);
	}

	Data opCatAssign()(Data data)
	{
		return append(data.contents);
	}

	Data opCatAssign()(ubyte value) // hack?
	{
		return append((&value)[0..1]);
	}

	Data opSlice(size_t x, size_t y)
	in
	{
		assert(x <= y);
		assert(y <= length);
	}
	out(result)
	{
		assert(result.length == y-x);
	}
	body
	{
		if (x == y)
			return Data();
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
	body
	{
		Data result = this;
		result.contents = contents[0..size];
		this  .contents = contents[size..$];
		return result;
	}
}

// ************************************************************************

static /*thread-local*/ size_t dataMemory, dataMemoryPeak;
static /*thread-local*/ uint   dataCount, allocCount;

private:

version (Windows)
	import std.c.windows.windows;
else
{
	import core.sys.posix.unistd;
	import core.sys.posix.sys.mman;
}

/// Actual wrapper.
final class DataWrapper
{
	/// Pointer to actual data.
	void* data;
	/// Used size. Needed for safe appends.
	size_t size;
	/// Allocated capacity.
	size_t capacity;

	/// Threshold of allocated memory to trigger a collect.
	enum { COLLECT_THRESHOLD = 8*1024*1024 } // 8MB
	/// Counter towards the threshold.
	static /*thread-local*/ size_t allocatedThreshold;

	/// Create a new instance with given capacity.
	this(size_t size, size_t capacity)
	{
		data = malloc(/*ref*/ capacity);
		if (data is null)
		{
			debug(DATA) printf("Garbage collect triggered by failed Data allocation... ");
			GC.collect();
			debug(DATA) printf("Done\n");
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

		this.size = size;
		this.capacity = capacity;

		// also collect
		allocatedThreshold += capacity;
		if (allocatedThreshold > COLLECT_THRESHOLD)
		{
			debug(DATA) printf("Garbage collect triggered by total allocated Data exceeding threshold... ");
			GC.collect();
			debug(DATA) printf("Done\n");
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

	@property
	inout(void)[] contents() inout
	{
		return data[0..size];
	}

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
			auto mapFlags = MAP_PRIVATE;
			version(linux)
			{
				import core.sys.linux.sys.mman;
				mapFlags |= MAP_ANON;
			}
			auto p = mmap(null, size, PROT_READ | PROT_WRITE, mapFlags, -1, 0);
			return (p == MAP_FAILED) ? null : p;
		}
		else
			return std.c.malloc(size);
	}

	static void free(void* p, size_t size)
	{
		debug
		{
			(cast(ubyte*)p)[0..size] = 0xDA;
		}
		version(Windows)
			VirtualFree(p, 0, MEM_RELEASE);
		else
		version(Posix)
			munmap(p, size);
		else
			std.c.free(size);
	}
}

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
