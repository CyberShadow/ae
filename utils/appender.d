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
 * Portions created by the Initial Developer are Copyright (C) 2011
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

/// Optimized copying appender, no chaining
module ae.utils.appender;

import core.memory;
import std.traits;

struct FastAppender(I)
{
	static assert(T.sizeof == 1, "TODO");

private:
	enum MIN_SIZE  = 4096;
	enum PAGE_SIZE = 4096;

	alias Unqual!I T;

	T* cursor, start, end;
	static struct Arr { size_t length; T* ptr; }

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

		auto newCapacity = nextCapacity(newSize);
		//auto newStart = (new T[newCapacity]).ptr;

		auto bi = GC.qalloc(newCapacity * T.sizeof, (typeid(T[]).next.flags & 1) ? 0 : GC.BlkAttr.NO_SCAN);
		auto newStart = cast(T*)bi.base;
		newCapacity = bi.size;

		newStart[0..size] = start[0..size];
		start = newStart;
		cursor = start + size;
		end = start + newCapacity;
	}

	// Round up to the next power of two, but after PAGE_SIZE only add PAGE_SIZE.
	private static size_t nextCapacity(size_t size)
	{
		if (size < MIN_SIZE)
			return MIN_SIZE;

		size--;
		auto sub = size;
		sub |= sub >>  1;
		sub |= sub >>  2;
		sub |= sub >>  4;
		sub |= sub >>  8;
		sub |= sub >> 16;
		static if (size_t.sizeof > 4)
			sub |= sub >> 32;

		return (size | (sub & (PAGE_SIZE-1))) + 1;
	}

	unittest
	{
		assert(nextCapacity(  PAGE_SIZE-1) ==   PAGE_SIZE);
		assert(nextCapacity(  PAGE_SIZE  ) ==   PAGE_SIZE);
		assert(nextCapacity(  PAGE_SIZE+1) == 2*PAGE_SIZE);
		assert(nextCapacity(2*PAGE_SIZE  ) == 2*PAGE_SIZE);
		assert(nextCapacity(2*PAGE_SIZE+1) == 3*PAGE_SIZE);
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
				cursor[0..item.length] = item;
		}
		else
		{
			foreach (item; items)
				static if (is(typeof(cursor[0] = item)))
					*cursor++ = item;
				else
				static if (is(typeof(cursor[0..1] = item[0..1])))
				{
					cursor[0..item.length] = item;
					cursor += item.length;
				}
		}
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
		/// Effectively empties the data, but preserves the storage for reuse
		void clear()
		{
			cursor = start;
		}
	}
}
