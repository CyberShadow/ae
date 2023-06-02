/**
 * Reference-counted objects for handling large amounts of raw _data.
 *
 * Using the `Data` type will only place a small object in managed
 * memory, keeping the actual bytes in unmanaged memory.
 *
 * A proxy class (`Memory`) is used to safely allow multiple
 * references to the same block of unmanaged memory.
 *
 * When the `Memory` object is destroyed, the unmanaged memory is
 * deallocated.
 *
 * This has the following advantage over using managed memory (regular
 * D arrays):
 *
 * - Faster allocation and deallocation, since memory is requested from
 *   the OS directly as whole pages.
 *
 * - Greatly reduced chance of memory leaks (on 32-bit platforms) due to
 *   stray pointers.
 *
 * - Overall improved GC performance due to reduced size of managed heap.
 *
 * - Memory is immediately returned to the OS when no more references
 *   remain.
 *
 * - Unlike D arrays, `Data` objects know their reference count,
 *   enabling things like copy-on-write.
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

import core.memory : GC;
import core.exception : OutOfMemoryError, onOutOfMemoryError;

import std.algorithm.mutation : move;
import std.traits : hasIndirections, Unqual;

import ae.utils.array : emptySlice;

debug(DATA) import core.stdc.stdio;

// TODO:
// - [X] review terminology
// - [X] templatize (and forbid using types with pointers)
// - [X] support const/immutable
// - [X] support void
// - [X] deprecate unsafe APIs
// - [ ] @safe compatibility
// - [ ] @nogc compatibility?
// - [ ] use heap (malloc/Windows heap API) for small objects
// - [ ]   remove UNMANAGED_THRESHOLD in ae.net.asockets
// - [ ] allow expanding over existing memory when we are the only reference
// - [ ] make ae.net.asockets only reallocate when needed
// - [ ] make capacity work with GC spans

/**
 * A reference to a reference-counted block of memory.
 * Represents a slice of data, which may be backed by managed memory,
 * unmanaged memory, memory-mapped files, etc.
 *
 * Params:
 *  T = the element type. "void" has a special meaning in that memory
 *      will not be default-initialized.
 */
struct TData(T)
if (!hasIndirections!T)
{
private:
	/// Wrapped data
	T[] data;

	/// Reference to the memory of the actual data - may be null to
	/// indicate wrapped data in managed memory.
	/// Used to maintain the reference count to unmanaged data, and
	/// for in-place expands (for appends).
	Memory memory;

	// --- Typed Memory construction helpers

	static T[] allocateMemory(U)(out Memory memory, size_t initialSize, size_t capacity, scope void delegate(Unqual!U[] contents) fill)
	{
		memory = unmanagedNew!OSMemory(initialSize * T.sizeof, capacity * T.sizeof);
		fill(cast(Unqual!U[])memory.contents);
		return cast(T[])memory.contents;
	}

	static T[] allocateMemory(U)(out Memory memory, U[] initialData)
	{
		assert(initialData.length * U.sizeof % T.sizeof == 0, "Unaligned allocation size");
		auto initialSize = initialData.length * U.sizeof / T.sizeof;
		return allocateMemory!U(memory, initialSize, initialSize, (contents) { contents[] = initialData[]; });
	}

	static T[] allocateMemory(out Memory memory, size_t initialSize, size_t capacity)
	{
		return allocateMemory!T(memory, initialSize, capacity, (contents) {
			static if (!is(Unqual!T == void))
				contents[] = T.init;
		});
	}

	// --- Concatenation / appending helpers

	void reallocate(size_t size, size_t capacity, scope void delegate(Unqual!T[] contents) fill)
	{
		Memory newMemory;
		auto newData = allocateMemory!T(newMemory, size, capacity, (contents) {
			contents[0 .. this.data.length] = this.data;
			fill(contents[this.data.length .. $]);
		});

		clear();
		this.memory = newMemory;
		this.memory.referenceCount++;
		this.data = newData;
	}

	void expand(size_t newSize, size_t newCapacity, scope void delegate(Unqual!T[] contents) fill)
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
			import ae.utils.array : bytes;
			auto dataBytes = this.data.bytes;
			auto pos = dataBytes.ptr - memory.contents.ptr; // start position in memory data in bytes
			memory.setSize(pos + newSize * T.sizeof);
			auto oldSize = data.length;
			data = data.ptr[0..newSize];
			fill(cast(Unqual!T[])data[oldSize .. $]);
		}
		else
			reallocate(newSize, newCapacity, fill);
	}

	// Maximum preallocation for append operations.
	enum maxPrealloc = 4*1024*1024; // must be power of 2

	alias Appendable = const(Unqual!T)[];
	static assert(is(typeof((T[]).init ~ Appendable.init)));

	static TData createConcatenation(Appendable left, Appendable right)
	{
		auto newSize = left.length + right.length;
		Memory newMemory;
		allocateMemory!T(newMemory, newSize, newSize, (contents) {
			contents[0 .. left.length] = left[];
			contents[left.length .. $] = right[];
		});
		return TData(newMemory);
	}

	TData concat(Appendable right)
	{
		if (right.length == 0)
			return this;
		return createConcatenation(this.data, right);
	}

	TData prepend(Appendable left)
	{
		if (left.length == 0)
			return this;
		return createConcatenation(left, this.data);
	}

	static size_t getPreallocSize(size_t length)
	{
		import ae.utils.math : isPowerOfTwo, nextPowerOfTwo;
		static assert(isPowerOfTwo(maxPrealloc));

		if (length < maxPrealloc)
			return nextPowerOfTwo(length);
		else
			return ((length-1) | (maxPrealloc-1)) + 1;
	}

	TData append(Appendable right)
	{
		if (right.length == 0)
			return this;
		size_t newLength = length + right.length;
		expand(newLength, getPreallocSize(newLength), (contents) {
			contents[] = right[];
		});
		return this;
	}

	// --- Conversion helpers

	void assertUnique() const
	{
		assert(
			(data is null)
			||
			(memory && memory.referenceCount == 1)
		);
	}

	void becomeUnique()
	out
	{
		assertUnique();
	}
	do
	{
		if (!length)
			this = TData(data);
		else
		if (!memory)
			this = TData.wrapGC(data);
		else
		if (memory.referenceCount > 1)
			this = TData(data);
	}

	debug(DATA) invariant
	{
		if (memory)
			assert(memory.referenceCount > 0, "Data referencing Memory with bad reference count");
	}

public:
	// --- Lifetime - construction

	// TODO: overload the constructor on scope/non-scope to detect when to reallocate?
	// https://issues.dlang.org/show_bug.cgi?id=23941

	/**
	 * DWIM constructor for creating a new instance wrapping the given data.
	 *
	 * In the current implementation, `data` is always copied into the
	 * new instance, however past and future implementations may not
	 * guarantee this (`wrapGC`-like construction may be used
	 * opportunistically instead).
	 */
	this(U)(U[] data)
	if (is(typeof({ U[] u; T[] t = u.dup; })))
	{
		if (data is null)
			this.data = null;
		else
		if (data.length == 0)
			this.data = emptySlice!T;
		else
		// if (forceReallocation || GC.addrOf(data.ptr) is null)
		{
			// copy (emplace) into unmanaged memory
			this.data = allocateMemory(this.memory, data);
			this.memory.referenceCount++;
		}
		// else
		// {
		// 	// just save a reference
		// 	this.data = data;
		// }

		assert(this.length * T.sizeof == data.length * U.sizeof);
	}

	/// Create a new null-like instance.
	this(typeof(null) n)
	{
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
			this.data = allocateMemory(this.memory, size, capacity);
			this.memory.referenceCount++;
		}
		else
		{
			memory = null;
			this.data = null;
		}

		assert(this.length == size);
	}

	/// Create a new instance which slices some range of managed (GC-owned) memory.
	/// Does not copy the data.
	static TData wrapGC(T[] data)
	{
		assert(data.length == 0 || GC.addrOf(data.ptr) !is null, "wrapGC data must be GC-owned");
		TData result;
		result.data = data;
		return result;
	}

	// Create a new instance slicing all of the given memory's contents.
	package this(Memory memory)
	{
		this.memory = memory;
		this.memory.referenceCount++;
		this.data = cast(T[])memory.contents;
	}

	this(this)
	{
		if (memory)
		{
			memory.referenceCount++;
			debug (DATA_REFCOUNT) debugLog("%p -> %p: Incrementing refcount to %d", cast(void*)&this, cast(void*)memory, memory.referenceCount);
		}
		else
			debug (DATA_REFCOUNT) debugLog("%p -> %p: this(this) with no memory", cast(void*)&this, cast(void*)memory);
	}

	// --- Lifetime - destruction

	~this() pure
	{
		//clear();
		// https://issues.dlang.org/show_bug.cgi?id=13809
		(cast(void delegate() pure)&clear)();
	}

	/// Unreference contents, freeing it if this was the last reference.
	void clear()
	{
		if (memory)
		{
			assert(memory.referenceCount > 0, "Dangling pointer to Memory");
			memory.referenceCount--;
			debug (DATA_REFCOUNT) debugLog("%p -> %p: Decrementing refcount to %d", cast(void*)&this, cast(void*)memory, memory.referenceCount);
			if (memory.referenceCount == 0)
				unmanagedDelete(memory);

			memory = null;
		}

		this.data = null;
	}

	// This used to be an unsafe method which deleted the wrapped data.
	// Now that Data is refcounted, this simply calls clear() and
	// additionally asserts that this Data is the only Data holding
	// a reference to the memory.
	deprecated void deleteContents()
	out
	{
		assert(memory is null);
	}
	do
	{
		if (memory)
		{
			assert(memory.referenceCount == 1, "Attempting to call deleteContents with more than one reference");
			clear();
		}
	}

	// --- Lifetime - conversion

	/// Returns an instance with the same data as the current instance, and a reference count of 1.
	/// The current instance is cleared.
	/// If the current instance already has a reference count of 1, no copying is done.
	TData ensureUnique()
	{
		becomeUnique();
		return move(this);
	}

	/// Cast contents to another type, and returns an instance with that contents.
	/// The current instance is cleared.
	/// The current instance must be the only one holding a reference to the data
	/// (call `ensureUnique` first).  No copying is done.
	TData!U castTo(U)()
	if (!hasIndirections!U)
	{
		assertUnique();

		TData!U result;
		result.data = cast(U[])data;
		result.memory = this.memory;
		this.data = null;
		this.memory = null;
		return result;
	}

	// --- Contents access

	/// Get temporary access to the data referenced by this Data instance.
	void enter(scope void delegate(scope inout(T)[]) fn) inout
	{
		// We must make a copy of ourselves to ensure that, should
		// `fn` overwrite the `this` instance, the passed contents
		// slice remains valid.
		auto self = this;
		fn(self.data);
	}

	/// Put a copy of the data on D's managed heap, and return it.
	T[] toGC() const
	{
		return data.dup;
	}

	// deprecated alias toHeap = toGC;
	// https://issues.dlang.org/show_bug.cgi?id=23954
	deprecated T[] toHeap() const { return toGC(); }

	/**
	   Get the referenced data. Unsafe!

	   All operations on the returned contents must be accompanied by
	   a live reference to the `Data` object, in order to keep a
	   reference towards the Memory owning the contents.

	   Be sure not to lose `Data` references while using their contents!
	   For example, avoid code like this:
	   ----
	   getSomeData()        // returns Data
		   .unsafeContents  // returns ubyte[]
		   .useContents();  // uses the ubyte[] ... while there is no Data to reference it
	   ----
	   The `Data` return value may be unreachable once `.unsafeContents` is evaluated.
	   Use `.toGC` instead of `.unsafeContents` in such cases to safely get a GC-owned copy,
	   or use `.enter(contents => ...)` to safely get a temporary reference.
	*/
	@property inout(T)[] unsafeContents() inout @system { return this.data; }

	// deprecated alias contents = unsafeContents;
	// https://issues.dlang.org/show_bug.cgi?id=23954
	deprecated @property inout(T)[] contents() inout @system { return this.data; }

	deprecated @property Unqual!T[] mcontents() @system
	{
		becomeUnique();
		return cast(Unqual!T[])data;
	}

	// --- Array-like operations

	/// 
	@property size_t length() const
	{
		return data.length;
	}
	alias opDollar = length; /// ditto

	deprecated @property inout(T)* ptr() inout { return unsafeContents.ptr; }

	deprecated @property Unqual!T* mptr() @system { return mcontents.ptr; }

	bool opCast(T)() const
		if (is(T == bool))
	{
		return data !is null;
	} ///

	/// Return the maximum value that can be set to `length` without causing a reallocation
	@property size_t capacity() const
	{
		if (memory is null)
			return length;
		// We can only safely expand if the memory slice is at the end of the used unmanaged memory block.
		// TODO: the above is only true if we are not the only reference; if we are, we can always expand.
		import ae.utils.array : bytes;
		auto dataBytes = this.data.bytes;
		auto pos = dataBytes.ptr - memory.contents.ptr; // start position in memory data in bytes
		auto end = pos + dataBytes.length;              // end   position in memory data in bytes
		assert(end <= memory.size);
		if (end == memory.size && end < memory.capacity)
			return (memory.capacity - pos) / T.sizeof; // integer division truncating towards zero
		else
			return length;
	}

	/// Resize contents
	@property void length(size_t newLength)
	{
		if (newLength == length) // no change
			return;
		if (newLength < length)  // shorten
			data = data[0..newLength];
		else                 // lengthen
			expand(newLength, newLength, (contents) {
				static if (!is(Unqual!T == void))
					contents[] = T.init;
			});
	}

	/// Create a copy of the data
	@property This dup(this This)()
	{
		return This(this.data, true);
	}

	/// Create a new `Data` containing the concatenation of `this` and `data`.
	/// Does not preallocate for successive appends.
	template opBinary(string op) if (op == "~")
	{
		TData opBinary(Appendable data)
		{
			return concat(data);
		} ///

		TData opBinary(TData data)
		{
			return concat(data.data);
		} ///

		static if (!is(Unqual!T == void))
		TData opBinary(T value)
		{
			return concat((&value)[0..1]);
		} ///
	}

	/// Create a new `Data` containing the concatenation of `data` and `this`.
	/// Does not preallocate for successive appends.
	template opBinaryRight(string op) if (op == "~")
	{
		TData opBinaryRight(Appendable data)
		{
			return prepend(data);
		} ///

		static if (!is(Unqual!T == void))
		TData opBinaryRight(T value)
		{
			return prepend((&value)[0..1]);
		} ///
	}

	/// Append data to this `Data`.
	/// Unlike concatenation (`a ~ b`), appending (`a ~= b`) will preallocate.
	template opOpAssign(string op) if (op == "~")
	{
		TData opOpAssign(Appendable data)
		{
			return append(data);
		} ///

		TData opOpAssign(TData data)
		{
			return append(data.data);
		} ///

		static if (!is(Unqual!T == void))
		TData opOpAssign(T value)
		{
			return append((&value)[0..1]);
		} ///
	}

	/// Access an individual item.
	static if (!is(Unqual!T == void))
	T opIndex(size_t index)
	{
		return data[index];
	}

	/// Write an individual item.
	static if (is(typeof(data[0] = T.init)))
	T opIndexAssign(T value, size_t index)
	{
		return data[index] = value;
	}

	/// Returns a `Data` pointing at a slice of this `Data`'s contents.
	TData opSlice()
	{
		return this;
	}

	/// ditto
	TData opSlice(size_t x, size_t y)
	in
	{
		assert(x <= y);
		assert(y <= length);
	}
	out(result)
	{
		assert(result.length == y-x);
	}
	do
	{
		if (x == y)
			return TData(emptySlice!T);
		else
		{
			TData result = this;
			result.data = result.data[x .. y];
			return result;
		}
	}

	// --- Range operations

	/// Range primitive.
	@property bool empty() const { return length == 0; }
	T front() { return data[0]; } ///
	void popFront() { data = data[1 .. $]; } ///

	// /// Return a new `Data` for the first `size` bytes, and slice this instance from size to end.
	// Data popFront(size_t size)
	// in
	// {
	// 	assert(size <= length);
	// }
	// do
	// {
	// 	Data result = this;
	// 	result.contents = contents[0..size];
	// 	this  .contents = contents[size..$];
	// 	return result;
	// }
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	alias AliasSeq(TList...) = TList;
	foreach (B; AliasSeq!(ubyte, uint, char, void))
	{
		alias Ts = AliasSeq!(B, const(B), immutable(B));
		foreach (T; Ts)
		{
			// Template instantiation
			{
				TData!T d;
				cast(void) d;
			}
			// Construction from typeof(null)
			{
				auto d = TData!T(null);
				assert(d.length == 0);
				assert(d.unsafeContents.ptr is null);
			}
			// Construction from null slice
			{
				T[] arr = null;
				auto d = TData!T(arr);
				assert(d.length == 0);
				assert(d.unsafeContents.ptr is null);
			}
			// Construction from non-null empty
			{
				T[0] arr;
				auto d = TData!T(arr[]);
				assert(d.length == 0);
				assert(d.unsafeContents.ptr !is null);
			}
			// Construction from non-empty non-GC slice
			{
				T[5] arr = void;
				assert(GC.addrOf(arr.ptr) is null);
				auto d = TData!T(arr[]);
				assert(d.length == 5);
				assert(d.unsafeContents.ptr !is null);
				assert(GC.addrOf(d.unsafeContents.ptr) is null);
			}
			// Construction from non-empty GC slice
			{
				T[] arr = new T[5];
				assert(GC.addrOf(arr.ptr) !is null);
				auto d = TData!T(arr);
				assert(d.length == 5);
				assert(d.unsafeContents.ptr !is null);
				assert(GC.addrOf(d.unsafeContents.ptr) is null);
			}
			// wrapGC from GC slice
			{
				T[] arr = new T[5];
				auto d = TData!T.wrapGC(arr);
				assert(d.length == 5);
				assert(d.unsafeContents.ptr is arr.ptr);
			}
			// wrapGC from non-GC slice
			{
				static T[5] arr = void;
				assertThrown!AssertError(TData!T.wrapGC(arr[]));
			}

			// Try a bunch of operations with different kinds of instances
			static T[5] arr = void;
			auto generators = [
				delegate () => TData!T(),
				delegate () => TData!T(null),
				delegate () => TData!T(T[].init),
				delegate () => TData!T(arr[]),
				delegate () => TData!T(arr[0 .. 0]),
				delegate () => TData!T(arr[].dup),
				delegate () => TData!T(arr[].dup[0 .. 0]),
				delegate () => TData!T.wrapGC(arr[].dup),
				delegate () => TData!T.wrapGC(arr[].dup[0 .. 0]),
			];
			static if (is(B == void))
				foreach (B2; AliasSeq!(ubyte, uint, char, void))
					foreach (T2; AliasSeq!(B2, const(B2), immutable(B2)))
						static if (is(typeof({ T2[] u; T[] t = u; })))
						{
							static T2[5] arr2 = void;
							generators ~= [
								delegate () => TData!T(T2[].init),
								delegate () => TData!T(arr2[]),
								delegate () => TData!T(arr2[0 .. 0]),
								delegate () => TData!T(arr2[].dup),
								delegate () => TData!T(arr2[].dup[0 .. 0]),
								delegate () => TData!T.wrapGC(arr2[].dup),
							//	delegate () => TData!T.wrapGC(arr2[].dup[0 .. 0]), // TODO: why not?
							];
						}
			foreach (generator; generators)
			{
				// General coherency
				{
					auto d = generator();
					auto length = d.length;
					auto contents = d.unsafeContents;
					assert(contents.length == length);
					size_t entered;
					d.enter((enteredContents) {
						assert(enteredContents is contents);
						entered++;
					});
					assert(entered == 1);
				}
				// Lifetime with enter
				{
					auto d = generator();
					d.enter((scope contents) {
						d = typeof(d)(null);
						(cast(ubyte[])contents)[] = 42;
					});
				}
				// toGC
				{
					auto d = generator();
					auto contents = d.unsafeContents;
					assert(d.toGC() == contents);
				}
				// In-place expansion (resize to capacity)
				{
					auto d = generator();
					auto oldContents = d.unsafeContents;
					d.length = d.capacity;
					assert(d.unsafeContents.ptr == oldContents.ptr);
				}
				// Copying expansion (resize past capacity)
				{
					auto d = generator();
					auto oldContents = d.unsafeContents;
					d.length = d.capacity + 1;
					assert(d.unsafeContents.ptr != oldContents.ptr);
				}
				// Concatenation
				{
					void test(L, R)(L left, R right)
					{
						{
							auto result = left ~ right;
							assert(result.length == left.length + right.length);
							// TODO: test contents, need opEquals?
						}
						static if (!is(Unqual!T == void))
						{
							if (left.length)
							{
								auto result = left[0] ~ right;
								assert(result.length == 1 + right.length);
							}
							if (right.length)
							{
								auto result = left ~ right[0];
								assert(result.length == left.length + 1);
							}
						}
					}

					foreach (generator2; generators)
					{
						test(generator(), generator2());
						test(generator().toGC, generator2());
						test(generator(), generator2().toGC);
					}
				}
				// Appending
				{
					void test(L, R)(L left, R right)
					{
						{
							auto result = left;
							result ~= right;
							assert(result.length == left.length + right.length);
							// TODO: test contents, need opEquals?
						}
						static if (!is(Unqual!T == void))
						{
							if (right.length)
							{
								auto result = left;
								result ~= right[0];
								assert(result.length == left.length + 1);
							}
						}
					}

					foreach (generator2; generators)
					{
						test(generator(), generator2());
						// test(generator().toGC, generator2());
						test(generator(), generator2().toGC);
					}
				}
				// Reference count
				{
					auto d = generator();
					if (d.memory)
					{
						assert(d.memory.referenceCount == 1);
						{
							auto s = d[1..4];
							assert(d.memory.referenceCount == 2);
							cast(void) s;
						}
						assert(d.memory.referenceCount == 1);
					}
				}
			}

			// Test effects of construction from various sources
			{
				void testSource(S)(S s)
				{
					void testData(TData!T d)
					{
						// Test true-ish-ness
						assert(!! s == !! d);
						// Test length
						static if (is(typeof(s.length)))
							assert(s.length * s[0].sizeof == d.length * T.sizeof);
						// Test content
						assert(s == d.unsafeContents);
					}
					// Construction
					testData(TData!T(s));
					// wrapGC
					static if (is(typeof(*s.ptr) == T))
						if (GC.addrOf(s.ptr))
							testData(TData!T.wrapGC(s));
					// Appending
					{
						TData!T d;
						d ~= s;
					}
				}
				testSource(null);
				testSource(T[].init);
				testSource(arr[]);
				testSource(arr[0 .. 0]);
				testSource(arr[].dup);
				testSource(arr[].dup[0 .. 0]);
				testSource(arr[].idup);
				testSource(arr[].idup[0 .. 0]);
				static if (is(B == void))
					foreach (B2; AliasSeq!(ubyte, uint, char, void))
						foreach (T2; AliasSeq!(B2, const(B2), immutable(B2)))
							static if (is(typeof({ T2[] u; T[] t = u; })))
							{
								static T2[5] arr2 = void;
								testSource(T2[].init);
								testSource(arr2[]);
								testSource(arr2[0 .. 0]);
								testSource(arr2[].dup);
								testSource(arr2[].dup[0 .. 0]);
							}
			}

			foreach (U; Ts)
			{
				// Construction from compatible slice
				{
					U[] u;
					TData!T(u);
					static if (is(typeof({ T[] t = u; })))
						cast(void) TData!T.wrapGC(u);
				}
			}
		}
	}
}

// /// The most common use case of manipulating unmanaged memory is
// /// working with raw bytes, whether they're received from the network,
// /// read from a file, or elsewhere.
// alias Data = TData!ubyte;

alias Data = TData!void;

// ************************************************************************

deprecated public import ae.sys.dataset : copyTo, joinData, joinToHeap, DataVec, shift, bytes, DataSetBytes;

deprecated alias DataWrapper = Memory;

// Temporary forward-compatibility shims.
// Will be deprecated when Data is switched to using ubyte.
ref inout(T) fromBytes(T, E)(inout(E)[] bytes)
if (!hasIndirections!T && is(Unqual!E == void))
{
	assert(bytes.length == T.sizeof, "Data length mismatch for " ~ T.stringof);
	return *cast(inout(T)*)bytes.ptr;
}

inout(T) fromBytes(T, E)(inout(E)[] bytes)
if (is(T U : U[]) && !hasIndirections!U && is(Unqual!E == void))
{
	return cast(inout(T))bytes;
}

// ************************************************************************

package:

/// Base abstract class which owns a block of memory.
abstract class Memory
{
	sizediff_t referenceCount = 0; /// Reference count.
	abstract @property inout(ubyte)[] contents() inout; /// The owned memory
	abstract @property size_t size() const;  /// Length of `contents`.
	abstract void setSize(size_t newSize); /// Resize `contents` up to `capacity`.
	abstract @property size_t capacity() const; /// Maximum possible size.

	debug ~this() @nogc
	{
		debug(DATA_REFCOUNT) debugLog("%.*s.~this, referenceCount==%d", this.classinfo.name.length, this.classinfo.name.ptr, referenceCount);
		assert(referenceCount == 0, "Deleting Memory with non-zero reference count");
	}
}

// ************************************************************************

/// How many bytes are currently in `Data`-owned memory.
static /*thread-local*/ size_t dataMemory, dataMemoryPeak;
/// How many `Memory` instances there are live currently.
static /*thread-local*/ uint   dataCount;
/// How many allocations have been done so far.
static /*thread-local*/ uint   allocCount;

/// Set threshold of allocated memory to trigger a garbage collection.
void setGCThreshold(size_t value) { OSMemory.collectThreshold = value; }

/// Allocate and construct a new class in `malloc`'d memory.
C unmanagedNew(C, Args...)(auto ref Args args)
if (is(C == class))
{
	import std.conv : emplace;
	enum size = __traits(classInstanceSize, C);
	auto p = unmanagedAlloc(size);
	emplace!C(p[0..size], args);
	return cast(C)p;
}

/// Delete a class instance created with `unmanagedNew`.
void unmanagedDelete(C)(C c)
if (is(C == class))
{
	c.destroy();
	unmanagedFree(cast(void*)c);
}

void* unmanagedAlloc(size_t sz)
{
	import core.stdc.stdlib : malloc;

	auto p = malloc(sz);

	debug(DATA_REFCOUNT) debugLog("? -> %p: Allocating via malloc (%d bytes)", p, cast(uint)sz);

	if (!p)
		throw new OutOfMemoryError();

	//GC.addRange(p, sz);
	return p;
}

void unmanagedFree(void* p) @nogc
{
	import core.stdc.stdlib : free;

	if (p)
	{
		debug(DATA_REFCOUNT) debugLog("? -> %p: Deleting via free", p);

		//GC.removeRange(p);
		free(p);
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
final class OSMemory : Memory
{
	/// Pointer to actual data.
	ubyte* data;
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
		data = cast(ubyte*)malloc(/*ref*/ capacity);
		if (data is null)
		{
			debug(DATA) fprintf(stderr, "Garbage collect triggered by failed Data allocation of %llu bytes... ", cast(ulong)capacity);
			GC.collect();
			debug(DATA) fprintf(stderr, "Done\n");
			data = cast(ubyte*)malloc(/*ref*/ capacity);
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
	~this() @nogc
	{
		free(data, capacity);
		data = null;
		// If Memory is created and manually deleted, there is no need to cause frequent collections
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
	size_t capacity() const @nogc { return _capacity; }

	override void setSize(size_t newSize)
	{
		assert(newSize <= capacity);
		_size = newSize;
	}

	@property override
	inout(ubyte)[] contents() inout
	{
		return data[0..size];
	}

	static immutable size_t pageSize;

	shared static this()
	{
		version (Windows)
		{
			import core.sys.windows.winbase : GetSystemInfo, SYSTEM_INFO;

			SYSTEM_INFO si;
			GetSystemInfo(&si);
			pageSize = si.dwPageSize;
		}
		else
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

	static void free(void* p, size_t size) @nogc
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

debug(DATA_REFCOUNT) import ae.utils.exception, ae.sys.memory, core.stdc.stdio;

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
			fprintf(stderr, "\t%.*s\n", cast(int)line.length, line.ptr);
	catch (Throwable e)
		fprintf(stderr, "\t(stacktrace error: %.*s)", cast(int)e.msg.length, e.msg.ptr);
}
