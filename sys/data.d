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
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2009-2011
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

module ae.sys.data;

static import std.c.stdlib;
import std.c.string : memmove;
import core.memory;
import core.exception;
debug(DATA) import std.stdio;
debug(DATA) import std.string;

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
 * Be sure not to lose Data references while using their contents!
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
	out
	{
		assert(this.length == data.length);
	}
	body
	{
		if (data.length == 0)
			contents = null;
		else
		if (forceReallocation || GC.addrOf(data.ptr) is null)
		{
			// copy to unmanaged memory
			wrapper = new DataWrapper(data.length, data.length);
			wrapper.contents[] = data;
			contents = wrapper.contents;
			mutable = true;
		}
		else
		{
			// just save a reference
			contents = data;
			mutable = false;
		}
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
	out
	{
		assert(this.length == size);
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
		if (!mutable)
			reallocate(length, length);
		assert(mutable);
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

	private void reallocate(size_t size, size_t capacity)
	{
		wrapper = new DataWrapper(size, capacity);
		wrapper.contents[0..this.length] = contents;
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
		if (wrapper is null)
			return reallocate(newSize, newCapacity);
		// We can only safely expand if the memory slice is at the end of the used unmanaged memory block.
		auto pos = ptr - wrapper.contents.ptr;
		assert(pos + length <= wrapper.size);
		if (pos + length == wrapper.size && pos + newSize <= wrapper.capacity)
		{
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
			_contents.length = value;
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

	Data opCat(const(void)[] data)
	{
		if (data.length==0)
			return this;
		Data result = Data(length + data.length);
		result.mcontents[0..this.length] = contents;
		result.mcontents[this.length..$] = data;
		return result;
	}

	Data opCat(Data data)
	{
		return this.opCat(data.contents);
	}

	Data opCat_r(const(void)[] data)
	{
		Data result = Data(data.length + length);
		result.mcontents[0..data.length] = data;
		result.mcontents[data.length..$] = contents;
		return result;
	}

	private static size_t getPreallocSize(size_t length)
	{
		if (length < MAX_PREALLOC)
			return nextPowerOfTwo(length);
		else
			return ((length-1) | (MAX_PREALLOC-1)) + 1;
	}

	/// Note that unlike opCat (a ~ b), opCatAssign (a ~= b) will preallocate.
	Data opCatAssign(const(void)[] data)
	{
		if (data.length==0)
			return this;
		size_t oldLength = length;
		size_t newLength = length + data.length;
		expand(newLength, getPreallocSize(newLength));
		auto newContents = cast(void[])_contents[oldLength..$];
		newContents[] = data;
		return this;
	}

	Data opCatAssign(Data data)
	{
		return this.opCatAssign(data.contents);
	}

	Data opCatAssign(ubyte value) // hack?
	{
		return this.opCatAssign((&value)[0..1]);
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

	void[] contents()
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
			auto p = mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
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

// Source: http://bits.stephan-brumme.com/roundUpToNextPowerOfTwo.html
size_t nextPowerOfTwo(size_t x)
{
	x |= x >> 1;  // handle  2 bit numbers
	x |= x >> 2;  // handle  4 bit numbers
	x |= x >> 4;  // handle  8 bit numbers
	x |= x >> 8;  // handle 16 bit numbers
	x |= x >> 16; // handle 32 bit numbers
	static if (size_t.sizeof==8)
		x |= x >> 32; // handle 64 bit numbers
	x++;

	return x;
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
