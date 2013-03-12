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

import core.memory;
import std.traits;

struct FastAppender(I)
{
	static assert(T.sizeof == 1, "TODO");

private:
	enum PAGE_SIZE = 4096;
	enum MIN_SIZE  = PAGE_SIZE / 2 + 1; // smallest size that can expand

	alias Unqual!I T;

	T* cursor, start, end;

	void reserve(size_t len)
	{
		auto size = cursor-start;
		auto newSize = size + len;
		auto capacity = end-start;

		if (start)
		{
			auto extended = GC.extend(start, newSize, newSize * 2);
			if (extended)
			{
				end = start + extended;
				return;
			}
		}

		auto newCapacity = newSize < MIN_SIZE ? MIN_SIZE : newSize * 2;

		auto bi = GC.qalloc(newCapacity * T.sizeof, (typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
		auto newStart = cast(T*)bi.base;
		newCapacity = bi.size;

		newStart[0..size] = start[0..size];
		start = newStart;
		cursor = start + size;
		end = start + newCapacity;
	}

public:
	/// Preallocate
	this(size_t capacity)
	{
		reserve(capacity);
	}

	void put(U...)(U items)
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

	/// Unsafe. Use together with preallocate().
	void uncheckedPut(U...)(U items)
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

	void preallocate(size_t len)
	{
		if (end - cursor < len)
			reserve(len);
	}

	T[] allocate(size_t len)
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

	I[] get()
	{
		return cast(I[])start[0..cursor-start];
	}

	@property size_t length()
	{
		return cursor-start;
	}

	static if (is(I == T)) // mutable types only
	{
		/// Does not resize. Use preallocate for that.
		@property void length(size_t value)
		{
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
