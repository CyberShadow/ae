module ae.utils.appender;

import core.memory;
import std.array;
import std.traits;
import std.algorithm;
import std.range;
import std.exception;
import core.bitop;

/// Rob Jacques' std.array.Appender rewrite, with a few tweaks.
/// http://d.puremagic.com/issues/show_bug.cgi?id=5813
/// Never reallocates - faster for high amount of data.
/// Presumably under the Boost license.

struct FastAppender(A : T[], T) {
	private {
		enum  PageSize = 4096;          // Memory page size
		alias Unqual!T E;               // Internal element type

		struct Data {
			Data*       next;           // The next data segment
			size_t      capacity;       // Capacity of this segment
			E[]         arr;            // This segment's array

			// Initialize a segment using an existing array
			void opAssign(E[] _arr) {
				next           = null;
				capacity       = _arr.capacity;
				arr            = _arr;
				if(_arr.length < capacity) {
					arr.length = capacity;
					arr.length = _arr.length;
				}
				assert(_arr.ptr is arr.ptr,"Unexpected reallocation occurred");
			}

			// Create a new segment using an existing array
			this(Unqual!T[] _arr) { this = _arr; }

			// Create a new segment with at least size bytes
			this(size_t size) {
				if(size > PageSize)
					size = (size +  PageSize-1) & ~(PageSize-1);
				debug(APPENDER) std.stdio.writeln("Allocating");
				auto bi  = GC.qalloc(size, !hasIndirections!T * 2);
				next     = null;
				capacity = bi.size / T.sizeof;
				arr      = (cast(E*)bi.base)[0..0];
				static assert(!false*2 == GC.BlkAttr.NO_SCAN);
			}
		}
		Data*  _head = null;                   // The head data segment
		Data*  _tail = null;                   // The last data segment

		// Returns: the total number of elements in the appender
		size_t _length() {
			size_t len = 0;
			for(auto d = _head; d !is null; d = d.next)
				len   += d.arr.length;
			return len;
		}

		// Flatten all the data segments into a single array
		E[] flatten() {
			if(!_head) return null;
			if( _head && _head.next is null)
				return _head.arr;

			size_t N   = _length;
			size_t len = N;
			size_t i   = 0;
			auto arr   = new E[N];
			for(auto d = _head; N > 0; d = d.next, N -= len, i += len) {
				len    = min(N, d.arr.length);
				memcpy(arr.ptr+i, d.arr.ptr, len * T.sizeof);
			}
			return arr;
		}

		// Returns: the next capacity size
		size_t nextCapacity() nothrow pure {
			auto   cap = _tail.capacity * T.sizeof * 2;
			return cap < PageSize ? cap : PageSize;
		}
	}

	/** Construct an appender with a given array.  Note that this does not copy
	 *  the data.  If the array has a larger capacity as determined by
	 *  arr.capacity, it will be used by the appender.  After initializing an
	 *  appender on an array, appending to the original array will reallocate.
	 */
	this(T[] arr) {
		if(arr is null) _head = _tail = new Data( 16 * T.sizeof );
		else            _head = _tail = new Data( cast(E[]) arr );
	}

	/// Construct an appender with a capacity of at least N elements.
	this(size_t N) { _head = _tail = new Data( N * T.sizeof ); }

	/// Returns: the maximum length that can be accommodated without allocation
	size_t capacity() {
		size_t cap = 0;
		for(auto d = _head; d !is null; d = d.next)
			cap   += d.capacity;
		return cap;
	}

	/// Returns: a mutable copy of the data.
	E[] dup()  {
		if(_head && _head.next is null)
			return flatten.dup;
		return flatten;
	}

	/// Returns: a immutable copy of the data.
	immutable(E)[] idup() {
		return cast(immutable(E)[]) dup;
	}

	/// Returns: the appender's data as an array.
	T[] data() {
		auto arr = flatten;
		if(_head !is _tail) {
			*_head = arr;
			 _tail = _head;
		}
		return cast(T[]) arr;
	}

	/** Reserve at least newCapacity elements for appending.  Note that more
	 *  elements may be reserved than requested.  If newCapacity < capacity,
	 *  then nothing is done.
	 */
	void reserve(size_t newCapacity) {
		auto cap  = capacity;
		if(  cap >= newCapacity) return;

		auto size = ( newCapacity - cap) * T.sizeof;

		// Initialize if not done so.
		if(!_head) { _head = _tail = new Data( size ); return; }

		// Update tail
		while(_tail.next !is null) _tail = _tail.next;

		// Try extending
		debug(APPENDER) std.stdio.writeln("reserve - extending");
		if( auto u = GC.extend(_tail.arr.ptr, size, size) )
			{ _tail.capacity = u / T.sizeof; return; }

		// If full, add a segment
		if(_tail.arr.length == _tail.capacity)
			{ _tail = _tail.next = new Data( size ); return; }

		// Allocate & copy
		auto next = Data(size);
		memcpy(next.arr.ptr, _tail.arr.ptr, _tail.arr.length * T.sizeof);
		_tail.arr       = next.arr.ptr[0.._tail.arr.length];
		_tail.capacity  = next.capacity;
	}

	/// Appends to the output range
	void put(U)(U item) //if ( isOutputRange!(Unqual!T[],U) )
	{
		// Transcoding is required to support char[].put(dchar)
		static if(isSomeChar!T && isSomeChar!U &&  T.sizeof < U.sizeof){
			E[T.sizeof == 1 ? 4 : 2] encoded;
			auto len = std.utf.encode(encoded, item);
			return put(encoded[0 .. len]);

		// put(T)
		} else static if(isImplicitlyConvertible!(U, E)) {
			if(!_head)
				_head = _tail  = new Data( 16 * T.sizeof );
			else if( _tail.arr.length == _tail.capacity  ) {   // Try extending
				while(_tail.next !is null) _tail = _tail.next; // Update tail
				debug(APPENDER) std.stdio.writeln("put(1) - extending");
				if( auto u = GC.extend(_tail.arr.ptr, T.sizeof, nextCapacity) )
					 _tail.capacity     = u / T.sizeof;
				else _tail = _tail.next = new Data( nextCapacity );
			}
			auto          len  = _tail.arr.length;
			_tail.arr.ptr[len] = item;
			_tail.arr          = _tail.arr.ptr[0 .. len + 1];

		// fast put(T[])
		} else static if (is(typeof(_tail.arr[0..1] = item[0..1]))) {
			auto items  = cast(E[]) item[];
			if(!_head)
				_head   = _tail = new Data(  items.length * T.sizeof );
			auto arr    = _tail.arr.ptr[_tail.arr.length.._tail.capacity];
			size_t len  = items.length;
			if(arr.length < len) {                             // Try extending
				while(_tail.next !is null) {                   // Update tail
					_tail = _tail.next;
					arr   = _tail.arr.ptr[_tail.arr.length.._tail.capacity];
				}
				auto size  = max(items.length*T.sizeof, nextCapacity);
				debug(APPENDER) std.stdio.writeln("put[] - extending");
				if( auto u = GC.extend(_tail.arr.ptr, T.sizeof, size) ) {
					_tail.capacity = u / T.sizeof;
					arr    = _tail.arr.ptr[_tail.arr.length.._tail.capacity];
				}
				if(arr.length < len) len = arr.length;
			}
			arr[0..len] = items[0..len];
			items       = items[len..$];
			_tail.arr   = _tail.arr.ptr[0 .. _tail.arr.length + len];
			if( items.length > 0 ) {               // Add a segment and advance
				_tail.next = new Data(max(items.length*T.sizeof,nextCapacity));
				_tail      = _tail.next;
				_tail.arr.ptr[0..items.length] = items[];
				_tail.arr   = _tail.arr.ptr[0..items.length];
			}

		// Kitchen sink
		} else {
			.put!(typeof(this),U,true)(this,item);
		}
	}

	/// Multi-put
	void put(U...)(U items) //if ( isOutputRange!(Unqual!T[],U) )
		if (U.length > 1)
	{
		size_t totalLength;
		A[U.length] itemData;
		foreach (i, item; items)
			static if (is(Unqual!(typeof(item)) == E))
			{
				totalLength += 1;
				itemData[i] = cast(A)((&items[i])[0..1]);
			}
			else
			//static if (is(Unqual!(typeof(item)) == E[]))
			static if (is(typeof(_tail.arr[0..1] = item[0..1])))
			{
				totalLength += item.length;
				itemData[i] = cast(A)item;
			}
			else
				static assert(0, "Can't append " ~ typeof(item).stringof);

		// TODO: dchar etc.

		putArray(itemData[], totalLength);
	}

	void putArray(A[] items, size_t totalLength)
	{
		if(!_head)
			_head   = _tail = new Data( totalLength * T.sizeof );
		auto arr    = _tail.arr.ptr[_tail.arr.length.._tail.capacity];
		debug(APPENDER) std.stdio.writefln("totalLength = %s; tail capacity = %s; write space = %s", totalLength, _tail.capacity, arr.length);
		if(totalLength > arr.length) {                     // Try extending
			while(_tail.next !is null) {                   // Update tail
				_tail = _tail.next;
				arr   = _tail.arr.ptr[_tail.arr.length.._tail.capacity];
			}
			auto size  = max(totalLength*T.sizeof, nextCapacity);
			debug(APPENDER) std.stdio.writeln("putArray - extending");
			if( auto u = GC.extend(_tail.arr.ptr, T.sizeof, size) ) {
				_tail.capacity = u / T.sizeof;
				arr    = _tail.arr.ptr[_tail.arr.length.._tail.capacity];
			}
		}

		if (totalLength <= arr.length)
		{
			_tail.arr   = _tail.arr.ptr[0 .. _tail.arr.length + totalLength];
		}
		else
		{
			_tail.arr   = _tail.arr.ptr[0 .. _tail.arr.capacity];
			size_t extraLength = totalLength - arr.length;

			foreach (i, item; items)
			{
				size_t ilen = item.length;
				if (ilen <= arr.length) // Item fits entirely?
				{
					arr[0..ilen] = item;
					arr = arr[ilen..$];
				}
				else
				{
					// Write first half to current block
					arr[] = item[0..arr.length];
					item = item[arr.length..$];

					// Allocate new block
					_tail.next = new Data(max(extraLength*T.sizeof, nextCapacity));
					_tail      = _tail.next;
					debug assert(_tail.capacity >= extraLength);
					auto p     = _tail.arr.ptr;
					_tail.arr  = _tail.arr.ptr[0..extraLength];

					// Write second half to the new block
					p[0..item.length] = item;
					p += item.length;

					// Now write the rest of the items
					foreach (item2; items[i+1..$])
					{
						p[0..item2.length] = item2;
						p += item2.length;
					}
					debug assert(p is _tail.arr.ptr + extraLength);

					return;
				}				
			}
			assert(0);
		}
	}

	// only allow overwriting data on non-immutable and non-const data
	static if(!is(T == immutable) && !is(T == const)) {
		/** Clears the managed array. This function may reduce the appender's
		 *  capacity.
		 */
		void clear() {
			_head     = _tail;            // Save the largest chunk and move on
			if(_head) {
				_head.arr  = _head.arr.ptr[0..0];
				_head.next = null;
			}
		}

		/** Shrinks the appender to a given length. Passing in a length that's
		 *  greater than the current array length throws an enforce exception.
		 *  This function may reduce the appender's capacity.
		 */
		void shrinkTo(size_t newlength) {
			for(auto d = _head; d !is null; d = d.next) {
				if(d.arr.length >= newlength) {
					d.arr  = d.arr.ptr[0..newlength];
					d.next = null;
				}
				newlength -= d.arr.length;
			}
			enforce(newlength == 0, "Appender.shrinkTo: newlength > capacity");
		}
	}

	// VP 2011.12.02
	void opOpAssign(string op, U)(U item)
		if (is(typeof(put!U)))
	{
		put(item);
	}
}

/// An ugly hack of Phobos' appender from std.array (Boost license).
/// Changes:
/// * Rewrote put method (ditched range support, added static array support)
/// * Multi-put
/// * Constructor with capacity
/// * Added assign, append and opCall operator support
/// * Added reset (like clear(this))
/// * Added getString (assumeUnique + reset)
/// * Ditched reference semantics to get rid of one level of indirection
/// * Ditched Data structure

/**
Implements an output range that appends data to an array. This is
recommended over $(D a ~= data) when appending many elements because it is more
efficient.

Example:
----
auto app = appender!string();
string b = "abcdefg";
foreach (char c; b) app.put(c);
assert(app.data == "abcdefg");

int[] a = [ 1, 2 ];
auto app2 = appender(a);
app2.put(3);
app2.put([ 4, 5, 6 ]);
assert(app2.data == [ 1, 2, 3, 4, 5, 6 ]);
----
 */
struct Appender2(A : T[], T)
{
	private
	{
		size_t _capacity;
		Unqual!(T)[] _arr;
	}

	void opAssign(U)(U item)
	{
		static if (is(typeof(_arr = item)))
		{
			// initialize to a given array.
			_arr = cast(Unqual!(T)[])item;

			if (__ctfe)
				return;

			// We want to use up as much of the block the array is in as possible.
			// if we consume all the block that we can, then array appending is
			// safe WRT built-in append, and we can use the entire block.
			auto cap = item.capacity;
			if(cap > item.length)
				item.length = cap;
			// we assume no reallocation occurred
			assert(item.ptr is _arr.ptr);
			_capacity = item.length;
		}
		else
		static if (is(typeof(_arr[] = item[])))
		{
			allocate(item.length);
			_arr = _arr.ptr[0..item.length];
			_arr[] = item[];
		}
		else
		static if (is(typeof(_arr[0] = item)))
		{
			allocate(1);
			_arr[0] = item;
		}
	}

	// Does not copy data.
	private void allocate(size_t capacity)
	{
		if (__ctfe)
		{
			_arr.length = capacity;
			_arr = _arr[0..0];
			_capacity = capacity;
			return;
		}
		auto bi = GC.qalloc(capacity * T.sizeof,
				(typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
		_capacity = bi.size / T.sizeof;
		_arr = (cast(Unqual!(T)*)bi.base)[0..0];
	}

/**
Construct an appender with a given array.  Note that this does not copy the
data.  If the array has a larger capacity as determined by arr.capacity,
it will be used by the appender.  After initializing an appender on an array,
appending to the original array will reallocate.
*/
	this(T[] arr)
	{
		opAssign(arr);
	}

	/// Preallocate with given capacity.
	this(size_t capacity)
	{
		allocate(capacity);
	}

	// Value semantics will probably result in undefined behavior on copy.
	// this(this) conflicts with opAssign
	//@disable this(this) {}

/**
Reserve at least newCapacity elements for appending.  Note that more elements
may be reserved than requested.  If newCapacity < capacity, then nothing is
done.
*/
	void reserve(size_t newCapacity)
	{
		if(_capacity < newCapacity)
		{
			// need to increase capacity
			immutable len = _arr.length;
			if (__ctfe)
			{
				_arr.length = newCapacity;
				_arr = _arr[0..len];
				_capacity = newCapacity;
				return;
			}
			immutable growsize = (newCapacity - len) * T.sizeof;
			auto u = GC.extend(_arr.ptr, growsize, growsize);
			if(u)
			{
				// extend worked, update the capacity
				_capacity = u / T.sizeof;
			}
			else
			{
				// didn't work, must reallocate
				auto bi = GC.qalloc(newCapacity * T.sizeof,
						(typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
				_capacity = bi.size / T.sizeof;
				if(len)
					memcpy(bi.base, _arr.ptr, len * T.sizeof);
				_arr = (cast(Unqual!(T)*)bi.base)[0..len];
				// leave the old data, for safety reasons
			}
		}
	}

/**
Returns the capacity of the array (the maximum number of elements the
managed array can accommodate before triggering a reallocation).  If any
appending will reallocate, $(D capacity) returns $(D 0).
 */
	@property size_t capacity()
	{
		return _capacity;
	}

/**
Returns the managed array.
 */
	@property T[] data()
	{
		return cast(typeof(return))(_arr);
	}

	// ensure we can add nelems elements, resizing as necessary
	private void ensureAddable(size_t nelems)
	{
		immutable len = _arr.length;
		immutable reqlen = len + nelems;
		if (reqlen > _capacity)
		{
			if (__ctfe)
			{
				_arr.length = reqlen;
				_arr = _arr[0..len];
				_capacity = reqlen;
				return;
			}
			// Time to reallocate.
			// We need to almost duplicate what's in druntime, except we
			// have better access to the capacity field.
			auto newlen = newCapacity(reqlen);
			// first, try extending the current block
			auto u = GC.extend(_arr.ptr, nelems * T.sizeof, (newlen - len) * T.sizeof);
			if(u)
			{
				// extend worked, update the capacity
				_capacity = u / T.sizeof;
			}
			else
			{
				// didn't work, must reallocate
				auto bi = GC.qalloc(newlen * T.sizeof,
						(typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
				_capacity = bi.size / T.sizeof;
				if(len)
					memcpy(bi.base, _arr.ptr, len * T.sizeof);
				_arr = (cast(Unqual!(T)*)bi.base)[0..len];
				// leave the old data, for safety reasons
			}
		}
	}

	private static size_t newCapacity(size_t newlength)
	{
		long mult = 100 + (1000L) / (bsr(newlength * T.sizeof) + 1);
		// limit to doubling the length, we don't want to grow too much
		if(mult > 200)
			mult = 200;
		auto newext = cast(size_t)((newlength * mult + 99) / 100);
		return newext > newlength ? newext : newlength;
	}
/+
/**
Appends one item to the managed array.
 */
	void put(U)(U item) if (isImplicitlyConvertible!(U, T) ||
			isSomeChar!T && isSomeChar!U)
	{
		static if (isSomeChar!T && isSomeChar!U && T.sizeof < U.sizeof)
		{
			// must do some transcoding around here
			Unqual!T[T.sizeof == 1 ? 4 : 2] encoded;
			auto len = std.utf.encode(encoded, item);
			put(encoded[0 .. len]);
		}
		else
		{
			ensureAddable(1);
			immutable len = _arr.length;
			_arr.ptr[len] = cast(Unqual!T)item;
			_arr = _arr.ptr[0 .. len + 1];
		}
	}

	// Const fixing hack.
	void put(Range)(Range items)
	if(isInputRange!(Unqual!Range) && !isInputRange!Range) {
		alias put!(Unqual!Range) p;
		p(items);
	}

/**
Appends an entire range to the managed array.
 */
	void put(Range)(Range items)
		if (isInputRange!Range && is(typeof(Appender2.init.put(items.front))))
	{
		// note, we disable this branch for appending one type of char to
		// another because we can't trust the length portion.
		static if (!(isSomeChar!T && isSomeChar!(ElementType!Range) &&
					 !is(Range == Unqual!T[]) &&
					 !is(Range == const(T)[]) &&
					 !is(Range == immutable(T)[])) &&
					is(typeof(items.length) == size_t))
		{
			// optimization -- if this type is something other than a string,
			// and we are adding exactly one element, call the version for one
			// element.
			static if(!isSomeChar!T)
			{
				if(items.length == 1)
				{
					put(items.front);
					return;
				}
			}

			// make sure we have enough space, then add the items
			ensureAddable(items.length);
			immutable len = _arr.length;
			immutable newlen = len + items.length;
			_arr = _arr.ptr[0..newlen];
			static if(is(typeof(_arr[] = items)))
			{
				_arr.ptr[len..newlen] = items;
			}
			else
			{
				for(size_t i = len; !items.empty; items.popFront(), ++i)
					_arr.ptr[i] = cast(Unqual!T)items.front;
			}
		}
		else
		{
			//pragma(msg, Range.stringof);
			// Generic input range
			for (; !items.empty; items.popFront())
			{
				put(items.front);
			}
		}
	}
+/

	/// Single-put
	void put(U)(U item)
	{
		static if (is(typeof(_arr[0   ] = item      )))
		{
			ensureAddable(1);
			immutable len = _arr.length;
			_arr.ptr[len] = item;
			_arr = _arr.ptr[0 .. len + 1];
		}
		else
		static if (is(typeof(_arr[0..1] = item[0..1])))
		{
			ensureAddable(item.length);
			immutable len = _arr.length;
			immutable newlen = len + item.length;
			_arr = _arr.ptr[0..newlen];
			_arr.ptr[len..newlen] = item;
		}
		else
		static if (isSomeChar!T && isSomeChar!U && T.sizeof < U.sizeof)
		{
			Unqual!T[T.sizeof == 1 ? 4 : 2] encoded;
			auto len = std.utf.encode(encoded, item);
			put(encoded[0 .. len]);
		}
		else
			static assert(0, "Can't append " ~ typeof(item).stringof);
	}

	/// Multi-put
	void put(U...)(U items) //if ( isOutputRange!(Unqual!T[],U) )
		if (U.length > 1 && CanPutAll!U)
	{
		size_t totalLength;
		foreach (item; items)
			static if (is(typeof(_arr[0   ] = item      )))
				totalLength += 1;
			else
			static if (is(typeof(_arr[0..1] = item[0..1])))
				totalLength += item.length;
			else
				static assert(0, "Can't append " ~ typeof(item).stringof);

		ensureAddable(totalLength);

		auto len = _arr.length;
		auto p = _arr.ptr + len;
		_arr = _arr.ptr[0..len + totalLength];

		foreach (item; items)
		{
			static if (is(typeof(_arr[0] = item)))
				*p++ = item;
			else
			{
				p[0..item.length] = item;
				p += item.length;
			}
		}
	}

	template CanPutAll(U...)
	{
		static if (U.length==0)
			enum CanPutAll = true;
		else
			enum CanPutAll = is(typeof(put!(U[0]))) && CanPutAll!(U[1..$]);
	}

	// only allow overwriting data on non-immutable and non-const data
	static if(!is(T == immutable) && !is(T == const))
	{
/**
Clears the managed array.  This allows the elements of the array to be reused
for appending.

Note that clear is disabled for immutable or const element types, due to the
possibility that $(D Appender2) might overwrite immutable data.
*/
		void clear()
		{
			_arr = _arr.ptr[0..0];
		}

/**
Shrinks the managed array to the given length.  Passing in a length that's
greater than the current array length throws an enforce exception.
*/
		void shrinkTo(size_t newlength)
		{
			enforce(newlength <= _arr.length);
			_arr = _arr.ptr[0..newlength];
		}
	}

	void reset()
	{
		_arr = null;
		_capacity = 0;
	}

	// VP 2011.12.02
	void opOpAssign(string op, U)(U item)
		if (op=="~" && is(typeof(put!U)))
	{
		put(item);
	}

	/+ blocked by http://d.puremagic.com/issues/show_bug.cgi?id=6036
	void opCall(U...)(U items)
		if (is(typeof(put(items))))
	{
		put(items);
	}
    +/

	@property size_t length()
	{
		return _arr.length;
	}

	static if(is(T == immutable(char)))
	string toString()
	{
		return data;
	}

	static if (is(T == char))
	string getString()
	{
		auto result = data;
		reset();
		return assumeUnique(result);
	}
}

alias Appender2!(char[]) StringBuilder;

private:

string test()
{
	FastAppender!string a;
	a.put("He", "llo");
	a ~= [',', ' '];
	a ~= "world";
	a ~= '!';
	return a.data;
}

string test2()
{
	StringBuilder a;
	a = " ";
	a.clear();
	a.put("He", "llo");
	char[2] x = [',', ' '];
	a.put(x);
	a.put("world");
	//a ~= x;
	auto result = a.data;
	return assumeUnique(result);
}
