/**
 * Optimized copying appender, no chaining
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

module ae.utils.appender;

import std.experimental.allocator : makeArray, stateSize;
import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.gc_allocator : GCAllocator;
import std.traits;

struct FastAppender(I, Allocator = GCAllocator)
{
	static assert(T.sizeof == 1, "TODO");

private:
	enum PAGE_SIZE = 4096;
	enum MIN_SIZE  = PAGE_SIZE / 2 + 1; // smallest size that can expand

	alias Unqual!I T;

	T* cursor, start, end;
	bool unique; // Holding a unique reference to the buffer?

	void reserve(size_t len)
	{
		immutable size = cursor-start;
		immutable newSize = size + len;
		immutable capacity = end-start;

		if (start)
		{
			size_t extended = 0;
			static if (is(Allocator == GCAllocator))
			{
				// std.allocator does not have opportunistic extend
				import core.memory;
				extended = GC.extend(start, newSize, newSize * 2);
			}
			else
			{
				static if (is(hasMember!(Allocator, "expand")))
				{
					auto buf = start[0..capacity];
					if (allocator.expand(buf, newSize))
					{
						assert(buf.ptr == start);
						extended = buf.length;
					}
				}
			}
			if (extended)
			{
				end = start + extended;
				return;
			}
		}

		auto newCapacity = newSize < MIN_SIZE ? MIN_SIZE : newSize * 2;

		version(none)
		{
			auto bi = GC.qalloc(newCapacity * T.sizeof, (typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
			auto newStart = cast(T*)bi.base;
			newCapacity = bi.size;
		}
		else
		{
			auto buf = allocator.makeArray!T(newCapacity);
			assert(buf.length == newCapacity);
			auto newStart = buf.ptr;
		}

		newStart[0..size] = start[0..size];
		if (unique)
			allocator.deallocate(start[0..capacity]);
		start = newStart;
		cursor = start + size;
		end = start + newCapacity;
		unique = true;
	}

public:
	static if (stateSize!Allocator)
		Allocator allocator;
	else
		alias allocator = Allocator.instance;

	static if (stateSize!Allocator == 0)
	{
		/// Preallocate
		this(size_t capacity)
		{
			reserve(capacity);
		}
	}

	/// Start with a given buffer
	this(I[] arr)
	{
		start = cursor = cast(T*)arr.ptr;
		end = start + arr.length;
	}

	@disable this(this);

	~this()
	{
		if (cursor && unique)
			allocator.deallocate(start[0..end-start]);
	}

	/// Put elements.
	/// Accepts any number of items (and will allocate at most once per call).
	/// Items can be of the element type (I), or arrays.
	void putEx(U...)(U items)
		if (CanPutAll!U)
	{
		// TODO: check for static if length is 1
		auto cursorEnd = cursor;
		foreach (item; items)
			static if (is(typeof(cursor[0] = item)))
				cursorEnd++;
			else
			// TODO: is this too lax? it allows passing static arrays by value
			static if (is(typeof(cursor[0..1] = item[0..1])))
				cursorEnd += item.length;
			else
				static assert(0, "Can't put " ~ typeof(item).stringof);

		if (cursorEnd > end)
		{
			auto len = cursorEnd - cursor;
			reserve(len);
			cursorEnd = cursor + len;
		}
		auto cursor = this.cursor;
		this.cursor = cursorEnd;

		static if (items.length == 1)
		{
			alias items[0] item;
			static if (is(typeof(cursor[0] = item)))
				cursor[0] = item;
			else
				cursor[0..item.length] = item[];
		}
		else
		{
			foreach (item; items)
				static if (is(typeof(cursor[0] = item)))
					*cursor++ = item;
				else
				static if (is(typeof(cursor[0..1] = item[0..1])))
				{
					cursor[0..item.length] = item[];
					cursor += item.length;
				}
		}
	}

	alias put = putEx;

	/// Unsafe. Use together with preallocate().
	void uncheckedPut(U...)(U items) @system
		if (CanPutAll!U)
	{
		auto cursor = this.cursor;

		foreach (item; items)
			static if (is(typeof(cursor[0] = item)))
				*cursor++ = item;
			else
			static if (is(typeof(cursor[0..1] = item[0..1])))
			{
				cursor[0..item.length] = item;
				cursor += item.length;
			}

		this.cursor = cursor;
	}

	/// Ensure we can append at least `len` more bytes before allocating.
	void preallocate(size_t len)
	{
		if (end - cursor < len)
			reserve(len);
	}

	/// Allocate a number of bytes, without initializing them,
	/// and return the slice to be filled in.
	/// The slice reference is temporary, and valid until the next allocation.
	T[] allocate(size_t len) @system
	{
		auto cursorEnd = cursor + len;
		if (cursorEnd > end)
		{
			reserve(len);
			cursorEnd = cursor + len;
		}
		auto result = cursor[0..len];
		cursor = cursorEnd;
		return result;
	}

	template CanPutAll(U...)
	{
		static if (U.length==0)
			enum bool CanPutAll = true;
		else
		{
			enum bool CanPutAll =
				(
					is(typeof(cursor[0   ] = U[0].init      )) ||
				 	is(typeof(cursor[0..1] = U[0].init[0..1]))
				) && CanPutAll!(U[1..$]);
		}
	}

	void opOpAssign(string op, U)(U item)
		if (op=="~" && is(typeof(put!U)))
	{
		put(item);
	}

	/// Get a reference to the buffer.
	/// Ownership of the buffer is passed to the caller
	/// (Appender will not deallocate it after this call).
	I[] get()
	{
		unique = false;
		return peek();
	}

	/// As with `get`, but ownership is preserved.
	/// The return value is valid until the next allocation,
	/// or until Appender is destroyed.
	I[] peek()
	{
		return cast(I[])start[0..cursor-start];
	}

	@property size_t capacity()
	{
		return end-start;
	}

	@property void capacity(size_t value)
	{
		immutable current = end - start;
		assert(value >= current, "Cannot shrink capacity");
		reserve(value - length);
	}

	@property size_t length()
	{
		return cursor-start;
	}

	static if (is(I == T)) // mutable types only
	{
		/// Set the length (up to the current capacity).
		@property void length(size_t value)
		{
			if (start + value > end)
				preallocate(start + value - end);
			cursor = start + value;
			assert(cursor <= end);
		}

		/// Effectively empties the data, but preserves the storage for reuse.
		/// Same as setting length to 0.
		void clear()
		{
			cursor = start;
		}
	}
}

unittest
{
	import std.meta : AliasSeq;
	import std.experimental.allocator.mallocator;

	foreach (Allocator; AliasSeq!(GCAllocator, Mallocator))
	{
		FastAppender!(char, Allocator) a;
		assert(a.get == "");
		a.put('a', "bcd", 'e');
		assert(a.get == "abcde");
		a.clear();
		assert(a.get == "");
		a.allocate(3)[] = 'x';
		assert(a.get == "xxx");
	}
}

/// UFCS shim for classic output ranges, which only take a single-argument put.
void putEx(R, U...)(auto ref R r, U items)
{
	foreach (item; items)
	{
		static if (is(typeof(r.put(item))))
			r.put(item);
		else
		static if (is(typeof(r.put(item[]))))
			r.put(item[]);
		else
		static if (is(typeof({ foreach (c; item) r.put(c); })))
			foreach (c; item)
				r.put(c);
		else
		static if (is(typeof(r.put((&item)[0..1]))))
			r.put((&item)[0..1]);
		else
			static assert(false, "Can't figure out how to put " ~ typeof(item).stringof ~ " into a " ~ R.stringof);
	}
}
