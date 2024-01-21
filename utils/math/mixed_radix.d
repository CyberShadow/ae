/**
 * ae.utils.math.mixed_radix_coding
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

module ae.utils.math.mixed_radix;

// TODO: Find what this thing is actually called.
/// A mixed-radix number coding system.
template MixedRadixCoder(
	/// Numeric type for decoded items.
	I,
	/// Numeric type for encoded result.
	E,
	/// Use an encoding with an explicit end of items.
	bool withEOF = false,
)
{
	/// This encoding system is LIFO, so the encoder buffers all items
	/// until `.finish` is called.
	struct Encoder(
		/// Maximum number of encoded items.
		/// If -1, a dynamic array will be used.
		size_t maxSize = -1,
	)
	{
		struct Item { I n, max; }
		MaybeDynamicArray!(Item, maxSize) items;

		void put(I n, I max)
		{
			assert(0 <= n && n < max);
			items ~= Item(n, max);
		}

		E finish()
		{
			E result = withEOF ? 1 : 0;
			foreach_reverse (ref item; items)
			{
				result *= item.max;
				result += item.n;
			}
			return result;
		}
	}

	struct Decoder
	{
		E encoded;
		this(E encoded)
		{
			this.encoded = encoded;
			static if (withEOF)
				assert(encoded > 0);
		}

		I get(I max)
		{
			assert(max > 0);
			I value = encoded % max;
			encoded /= max;
			static if (withEOF)
				assert(encoded > 0, "Decoding error");
			return value;
		}

		static if (withEOF)
		@property bool empty() const { return encoded == 1; }
	}
}

unittest
{
	import std.meta : AliasSeq;

	alias I = uint;
	alias E = uint;

	foreach (dynamicSize; AliasSeq!(false, true))
		foreach (withEOF; AliasSeq!(false, true))
		{
			void testImpl()
			{
				alias Coder = MixedRadixCoder!(I, E, withEOF);
				Coder.Encoder!(dynamicSize ? -1 : 2) encoder;

				encoder.put(5, 8);
				encoder.put(1, 2);
				auto result = encoder.finish();

				auto decoder = Coder.Decoder(result);
				static if (withEOF) assert(!decoder.empty);
				assert(decoder.get(8) == 5);
				static if (withEOF) assert(!decoder.empty);
				assert(decoder.get(2) == 1);
				static if (withEOF) assert(decoder.empty);
			}
			static if (!dynamicSize)
			{
				@nogc void test() { testImpl(); }
				test();
			}
			else
				testImpl();
		}
}
private struct MaybeDynamicArray(T, size_t size = -1)
{
	static if (size == -1)
	{
		T[] items;
		alias items this;
	}
	else
	{
		T[size] items;
		size_t length;
		void opOpAssign(string op : "~")(T item) { items[length++] = item; }
		T[] opSlice() { return items[0 .. length]; }
	}
}
