/**
 * ae.utils.container.hashtable
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

module ae.utils.container.hashtable;

struct HashTableItem(K, V)
{
	K k;
	HashTableItem* next;
	V v;
}

/// A hash table with a static size.
struct HashTable(K, V, uint SIZE, alias ALLOCATOR, alias HASHFUNC="k")
{
	alias K KEY;
	alias V VALUE;

	import std.functional;
	import std.exception;

	alias unaryFun!(HASHFUNC, "k") hashFunc;

	// hashFunc returns a hash, get its type
	alias typeof(hashFunc(K.init)) H;
	static assert(is(H : ulong), "Numeric hash type expected");

	alias HashTableItem!(K, V) Item;

	struct Data
	{
		Item*[SIZE] items;
	}

	static template Impl(alias data)
	{
		V* get(in K k)
		{
			auto h = hashFunc(k) % SIZE;
			auto item = data.items[h];
			while (item)
			{
				if (item.k == k)
					return &item.v;
				item = item.next;
			}
			return null;
		}

		V* opBinaryRight(string op)(in K k)
		if (op == "in")
		{
			return get(k); // Issue 11842
		}

		V get(in K k, V def)
		{
			auto pv = get(k);
			return pv ? *pv : def;
		}

		/// Returns a pointer to the value storage space for a new value.
		/// Assumes the key does not yet exist in the table.
		V* add(in K k)
		{
			auto h = hashFunc(k) % SIZE;
			auto newItem = ALLOCATOR.allocate!Item();
			newItem.k = k;
			newItem.next = data.items[h];
			data.items[h] = newItem;
			return &newItem.v;
		}

		/// Returns a pointer to the value storage space for a new
		/// or existing value.
		V* getOrAdd(in K k)
		{
			auto h = hashFunc(k) % SIZE;
			auto item = data.items[h];
			while (item)
			{
				if (item.k == k)
					return &item.v;
				item = item.next;
			}

			auto newItem = ALLOCATOR.allocate!Item();
			newItem.k = k;
			newItem.next = data.items[h];
			data.items[h] = newItem;
			return &newItem.v;
		}

		void set(in K k, ref V v) { *getOrAdd(k) = v; }

		int opApply(int delegate(ref K, ref V) dg)
		{
			int result = 0;

			outerLoop:
			for (uint h=0; h<SIZE; h++)
			{
				auto item = data.items[h];
				while (item)
				{
					result = dg(item.k, item.v);
					if (result)
						break outerLoop;
					item = item.next;
				}
			}
			return result;
		}

		ref V opIndex(in K k)
		{
			auto pv = get(k);
			enforce(pv, "Key not in HashTable");
			return *pv;
		}

		void opIndexAssign(ref V v, in K k) { set(k, v); }

		size_t getLength()
		{
			size_t count = 0;
			for (uint h=0; h<SIZE; h++)
			{
				auto item = data.items[h];
				while (item)
				{
					count++;
					item = item.next;
				}
			}
			return count;
		}

		void clear()
		{
			data.items[] = null;
		}

		void freeAll()
		{
			static if (is(typeof(ALLOCATOR.freeAll())))
				ALLOCATOR.freeAll();
		}
	}
}

unittest
{
	import ae.utils.alloc;

	static struct Test
	{
		WrapParts!(RegionAllocator!()) allocator;
		alias HashTable!(int, string, 16, allocator) HT;
		HT.Data htData;
		alias ht = HT.Impl!htData;

		mixin(mixAliasForward!(ht, q{ht}));
	}
	Test ht;

	assert(5 !in ht);
	auto s = "five";
	ht[5] = s;
	assert(5 in ht);
	assert(ht[5] == "five");
}
