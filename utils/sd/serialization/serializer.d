/**
 * Serialization from a D variable.
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

module ae.utils.sd.serialization.serializer;

import std.traits;

import ae.utils.text : fpAsString;
import ae.utils.text.ascii : decimalSize, toDec;

/// Serialization source which serializes a given object.
struct Serializer(T)
{
	T* object;

	auto read(Handler)(Handler handler)
	{
		static if (__traits(hasMember, Handler, q{canHandleValue})
			&& Handler.canHandleValue!(typeof(null))
			&& is(typeof(*object is null)))
		{
			if (*object is null)
				return handler.handleValue(null);
		}

		static if (__traits(hasMember, Handler, q{canHandleValue}) && Handler.canHandleValue!T)
			return handler.handleValue(*object);
		else
		static if (__traits(hasMember, Handler, q{canHandleTypeHint}) && Handler.canHandleTypeHint!T)
			return handler.handleTypeHint!T(this);
		else
		static if (isNumeric!T && __traits(hasMember, Handler, q{handleNumeric}))
			return handler.handleNumeric(NumericReader(object));
		else
		static if (is(T == struct))
			return handler.handleMap(StructReader(object));
		else
		static if (is(T V : V[K], K))
			return handler.handleMap(AAReader(object));
		else
		static if (is(T U : U[]))
			return handler.handleArray(ArrayReader(object));
		else
			static assert(false, "Sink handler " ~ Handler.stringof ~ " can't accept values of type " ~ T.stringof);
	}

	static if (isIntegral!T)
	struct NumericReader
	{
		T* object;

		auto read(Handler)(Handler handler)
		{
			char[decimalSize!T] buf = void;
			return handler.handleSlice!char(toDec(*object, buf));
		}
	}

	static if (isFloatingPoint!T)
	struct NumericReader
	{
		T* object;

		auto read(Handler)(Handler handler)
		{
			auto s = fpAsString(*object);
			return handler.handleSlice!char(s.buf.data);
		}
	}

	struct ArrayReader
	{
		T* object;

		auto read(Handler)(Handler handler)
		{
			alias E = typeof((*object)[0]);

			static if (__traits(hasMember, Handler, q{canHandleSlice}) && Handler.canHandleSlice!T)
				handler.handleSlice(*object);
			else
				foreach (ref c; *object)
					handler.handleElement(Serializer!E(&c));
			return handler.handleEnd();
		}
	}

	struct AAReader
	{
		T* object;

		auto read(Handler)(Handler handler)
		{
			alias K = typeof((*object).keys[0]);
			alias V = typeof((*object).values[0]);
			alias Pair = typeof((*object).byKeyValue.front);

			struct PairReader
			{
				Pair* pair;

				void read(Handler)(Handler handler)
				{
					handler.handlePairKey(Serializer!K(&pair.key()));
					handler.handlePairValue(Serializer!V(&pair.value()));
				}
			}

			foreach (ref pair; object.byKeyValue())
				handler.handlePair(PairReader(&pair));
			return handler.handleEnd();
		}
	}

	struct StructReader
	{
		T* object;

		auto read(Handler)(Handler handler)
		{
			struct FieldReader(size_t fieldIndex)
			{
				T* object;

				void read(Handler)(Handler handler)
				{
					static immutable name = __traits(identifier, T.tupleof[fieldIndex]);
					handler.handlePairKey(Serializer!(immutable(string))(&name));

					alias F = typeof(object.tupleof[fieldIndex]);
					handler.handlePairValue(Serializer!F(&object.tupleof[fieldIndex]));
				}
			}

			static foreach (fieldIndex; 0 .. T.tupleof.length)
				handler.handlePair(FieldReader!fieldIndex(object));
			return handler.handleEnd();
		}
	}

	static template Impl(alias anchor)
	{
		static void read(Sink, T)(Sink sink, auto ref T v)
		{
			static if (is(typeof(v is null)))
				if (v is null)
				{
					sink.handleNull();
					return;
				}

			static if (is(T == bool))
				sink.handleBoolean(v);
			else
			static if (is(T : ulong))
			{
				char[decimalSize!T] buf = void;
				sink.handleNumeric(toDec(v, buf));
			}
			else
			static if (isNumeric!T) // floating point
			{
				import ae.utils.textout;

				static char[64] arr;
				auto buf = StringBuffer(arr);
				formattedWrite(&buf, "%s", v);
				sink.handleNumeric(buf.get());
			}
			else
			static if (is(T == struct))
			{
				auto reader = StructReader!T(v.reference);
				sink.handleObject(boundFunctorOf!(StructReader!T.read)(&reader));
			}
			else
			static if (is(T V : V[K], K))
			{
				alias Reader = AAReader!(T, K, V);
				auto reader = Reader(v);
				sink.handleObject(boundFunctorOf!(Reader.read)(&reader));
			}
			else
			static if (is(T : string))
				sink.handleString(v);
			else
			static if (is(T U : U[]))
			{
				alias Reader = ArrayReader!T;
				auto reader = Reader(v);
				sink.handleArray(boundFunctorOf!(Reader.readArray)(&reader));
			}
			else
				static assert(false, "Don't know how to serialize " ~ T.stringof);
		}

		static struct StructReader(T)
		{
			RefType!T p;
			void read(Sink)(Sink sink)
			{
				foreach (i, ref field; p.dereference.tupleof)
				{
					import std.array : split;
					enum name = p.dereference.tupleof[i].stringof.split(".")[$-1];

					alias ValueReader = Reader!(typeof(field));
					auto reader = ValueReader(&field);
					sink.handleField(unboundFunctorOf!(stringReader!name), boundFunctorOf!(ValueReader.readValue)(&reader));
				}
			}
		}

		static struct AAReader(T, K, V)
		{
			T aa;
			void read(Sink)(Sink sink)
			{
				foreach (K k, ref V v; aa)
				{
					alias KeyReader   = Reader!K;
					auto keyReader   = KeyReader  (&k);
					alias ValueReader = Reader!V;
					auto valueReader = ValueReader(&v);
					sink.handleField(
						boundFunctorOf!(KeyReader  .readValue)(&keyReader  ),
						boundFunctorOf!(ValueReader.readValue)(&valueReader),
					);
				}
			}
		}

		static struct ArrayReader(T)
		{
			T arr;
			void readArray(Sink)(Sink sink)
			{
				foreach (ref v; arr)
					read(sink, v);
			}
		}

		static template stringReader(string name)
		{
			static void stringReader(Sink)(Sink sink)
			{
				sink.handleString(name);
			}
		}

		static struct Reader(T)
		{
			T* p;

			void readValue(Sink)(Sink sink)
			{
				read(sink, *p);
			}
		}
	}
}

Serializer!T serialize(T)(ref T object)
{
	return Serializer!T(&object);
}
