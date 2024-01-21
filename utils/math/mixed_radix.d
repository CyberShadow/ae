/**
 * ae.utils.math.mixed_radix
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
		size_t maxItems,
	)
	{
	private:
		struct Item { I n, card; }
		MaybeDynamicArray!(Item, maxItems) items;

	public:
		/// Encode one item.
		/// `card` is the item's cardinality, i.e. one past its maximum.
		void put(I n, I card)
		in(0 <= n && n < card)
		{
			items ~= Item(n, card);
		}

		/// Finish encoding and return the encoded result.
		E finish()
		{
			E result = withEOF ? 1 : 0;
			foreach_reverse (ref item; items)
			{
				result *= item.card;
				result += item.n;
			}
			return result;
		}
	}

	/// As above. This will allocate the items dynamically.
	alias VariableLengthEncoder = Encoder!(-1);

	/// Like `Encoder`, but does not use a temporary buffer.
	/// Instead, the user is expected to put the items in reverse order.
	struct RetroEncoder
	{
	private:
		E encoded = withEOF ? 1 : 0;

	public:
		void put(I n, I card)
		{
			assert(0 <= n && n < card);
			encoded *= card;
			encoded += n;
		} ///

		E finish()
		{
			return encoded;
		} ///
	}

	/// The decoder.
	struct Decoder
	{
	private:
		E encoded;

	public:
		this(E encoded)
		{
			this.encoded = encoded;
			static if (withEOF)
				assert(encoded > 0);
		} ///

		I get(I card)
		in(card > 0)
		{
			I value = encoded % card;
			encoded /= card;
			static if (withEOF)
				assert(encoded > 0, "Decoding error");
			return value;
		} ///

		static if (withEOF)
		@property bool empty() const { return encoded == 1; } ///
	}
}

///
unittest
{
	alias Coder = MixedRadixCoder!(uint, uint, true);
	Coder.Encoder!2 encoder;
	encoder.put(5, 8);
	encoder.put(1, 2);
	auto result = encoder.finish();

	auto decoder = Coder.Decoder(result);
	assert(decoder.get(8) == 5);
	assert(decoder.get(2) == 1);
	assert(decoder.empty);
}

unittest
{
	import std.meta : AliasSeq;
	import std.traits : EnumMembers;
	import std.exception : assertThrown;
	import core.exception : AssertError;

	alias I = uint;
	alias E = uint;

	enum Mode { dynamicSize, staticSize, retro }
	foreach (mode; EnumMembers!Mode)
		foreach (withEOF; AliasSeq!(false, true))
		{
			void testImpl()
			{
				alias Coder = MixedRadixCoder!(I, E, withEOF);

				static if (mode == Mode.retro)
				{
					Coder.RetroEncoder encoder;
					encoder.put(1, 2);
					encoder.put(5, 8);
				}
				else
				{
					static if (mode == Mode.dynamicSize)
						Coder.VariableLengthEncoder encoder;
					else
						Coder.Encoder!2 encoder;

					encoder.put(5, 8);
					encoder.put(1, 2);
				}
				auto result = encoder.finish();

				auto decoder = Coder.Decoder(result);
				static if (withEOF) assert(!decoder.empty);
				assert(decoder.get(8) == 5);
				static if (withEOF) assert(!decoder.empty);
				assert(decoder.get(2) == 1);
				static if (withEOF) assert(decoder.empty);

				static if (withEOF)
				{
					debug assertThrown!AssertError(decoder.get(42));
				}
				else
					assert(decoder.get(42) == 0);
			}
			static if (mode == Mode.dynamicSize)
				testImpl();
			else
			{
				@nogc void test() { testImpl(); }
				test();
			}
		}
}

/// Serializes structs and static arrays using a `MixedRadixCoder`.
/// Consults types' `.max` property to obtain cardinality.
template SerializationCoder(alias Coder, S)
{
	private alias I = typeof(Coder.Decoder.init.get(0));
	private alias E = typeof(Coder.RetroEncoder.init.finish());

	private mixin template Visitor(bool retro)
	{
		void visit(T)(ref T value)
		{
			static if (is(T : I) && is(typeof(T.max) : I))
			{
				I max = T.max;
				I card = max; card++;
				assert(card > max, "Overflow");
				handleLeaf(value, card);
			}
			else
			static if (is(T == struct))
				static if (retro)
					foreach_reverse (ref field; value.tupleof)
						visit(field);
				else
					foreach (ref field; value.tupleof)
						visit(field);
			else
			static if (is(T == Q[N], Q, size_t N))
				static if (retro)
					foreach_reverse (ref item; value)
						visit(item);
				else
					foreach (ref item; value)
						visit(item);
			else
				static assert(false, "Don't know what to do with " ~ T.stringof);
		}
	}

	private struct Serializer
	{
		Coder.RetroEncoder encoder;
		void handleLeaf(I value, I card) { encoder.put(value, card); }
		mixin Visitor!true;
	}

	E serialize()(auto ref const S s)
	{
		Serializer serializer;
		serializer.visit(s);
		return serializer.encoder.finish();
	} ///

	private struct Deserializer
	{
		Coder.Decoder decoder;
		void handleLeaf(T)(ref T value, I card) { value = cast(T)decoder.get(card); }
		mixin Visitor!false;
	}

	S deserialize(E encoded) @nogc
	{
		Deserializer deserializer;
		deserializer.decoder = Coder.Decoder(encoded);
		S result;
		deserializer.visit(result);
		static if (__traits(hasMember, deserializer.decoder, "empty"))
			assert(deserializer.decoder.empty);
		return result;
	} ///
}

///
unittest
{
	static struct WithMax(T, T max_)
	{
		T value;
		alias value this;
		enum T max = max_;
	}

	enum E { a, b, c }
	alias D6 = WithMax!(uint, 6);

	static struct S
	{
		ubyte a;
		bool b;
		E[3] e;
		D6 d;
	}

	alias Coder = SerializationCoder!(MixedRadixCoder!(uint, ulong, true), S);
	auto s = S(1, true, [E.a, E.b, E.c], D6(4));
	assert(Coder.deserialize(Coder.serialize(s)) == s);
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
