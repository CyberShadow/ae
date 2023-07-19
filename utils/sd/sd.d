/**
 * Type serializer and deserializer.
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

module ae.utils.sd.sd;

import std.conv;
import std.format;
import std.string;
import std.traits;

import ae.utils.meta;
import ae.utils.text;

/// Serialization source which serializes a given object.
struct Serializer
{
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
				char[DecimalSize!T] buf = void;
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

/// Serialization sink which deserializes into a given type.
template Deserializer(alias anchor)
{
	alias C = immutable(char); // TODO

	mixin template SinkHandlers(T)
	{
		template unparseable(string inputType)
		{
			void unparseable(Reader)(Reader reader)
			{
				throw new Exception("Can't parse %s from %s".format(T.stringof, inputType));
			}
		}

		void handleString(S)(S s)
		{
			static if (is(typeof(s.to!T)))
			{
				T v = to!T(s);
				handleValue(v);
			}
			else
				throw new Exception("Can't parse %s from %s".format(T.stringof, S.stringof));
		}

		static if (is(T : C[]))
			void handleStringFragments(Reader)(Reader reader)
			{
				static struct FragmentSink
				{
					C[] buf;

					void handleStringFragment(CC)(CC[] s)
					{
						buf ~= s;
					}
				}
				FragmentSink sink;
				reader(&sink);
				handleValue(sink.buf);
			}
		else
			alias handleStringFragments = unparseable!"string fragments";

		static if (is(T U : U[]))
			void handleArray(Reader)(Reader reader)
			{
				ArraySink!U sink;
				reader(&sink);
				handleValue(sink.arr);
			}
		else
			alias handleArray = unparseable!"array";

		static if (is(T V : V[K], K))
			void handleObject(Reader)(Reader reader)
			{
				static struct FieldSink
				{
					T aa;

					void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
					{
						K k;
						V v;
						nameReader (makeSink!K(&k));
						valueReader(makeSink!V(&v));
						aa[k] = v;
					}
				}

				FieldSink sink;
				reader(&sink);
				handleValue(sink.aa);
			}
		else
		static if (is(T == struct))
		{
			void handleObject(Reader)(Reader reader)
			{
				static struct FieldSink
				{
					T s;

					void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
					{
						alias N = const(C)[];
						N name;
						nameReader(makeSink!N(&name));

						// TODO: generate switch
						foreach (i, field; s.tupleof)
						{
							// TODO: Name customization UDAs
							enum fieldName = to!N(__traits(identifier, s.tupleof[i]));
							if (name == fieldName)
							{
								alias V = typeof(field);
								valueReader(makeSink!V(&s.tupleof[i]));
								return;
							}
						}
						throw new Exception("Unknown field %s".format(name));
					}
				}

				FieldSink sink;
				reader(&sink);
				handleValue(sink.s);
			}
		}
		else
			alias handleObject = unparseable!"object";

		void handleNull()
		{
			static if (is(typeof({T v = null;})))
			{
				T v = null;
				handleValue(v);
			}
			else
				throw new Exception("Can't parse %s from %s".format(T.stringof, "null"));
		}

		void handleBoolean(bool v)
		{
			static if (is(T : bool))
				handleValue(v);
			else
				throw new Exception("Can't parse %s from %s".format(T.stringof, "boolean"));
		}

		void handleNumeric(CC)(CC[] v)
		{
			static if (is(typeof(to!T(v))))
			{
				T t = to!T(v);
				handleValue(t);
			}
			else
				throw new Exception("Can't parse %s from %s".format(T.stringof, "numeric"));
		}
	}

	static struct ArraySink(T)
	{
		T[] arr;

		void handleValue(ref T v) { arr ~= v; }

		mixin SinkHandlers!T;
	}

	static auto makeSink(T)(T* p)
	{
		static if (is(typeof(p.isSerializationSink)))
			return p;
		else
		{
			static struct Sink
			{
				T* p;

				// TODO: avoid redundant copying for large types
				void handleValue(ref T v) { *p = v; }

				auto traverse(CC, Reader)(CC[] name, Reader reader)
				{
					static if (is(T K : V[K], V))
					{
						auto key = name.to!K();
						auto pv = key in *p;
						if (!pv)
						{
							(*p)[key] = V.init;
							pv = key in *p;
						}
						return reader(makeSink(pv));
					}
					else
					static if (is(T == struct))
					{
						static immutable T dummy; // https://issues.dlang.org/show_bug.cgi?id=12319
						foreach (i, ref field; p.tupleof)
						{
							// TODO: Name customization UDAs
							enum fieldName = to!(CC[])(__traits(identifier, dummy.tupleof[i]));
							if (name == fieldName)
								return reader(makeSink(&field));
						}
						throw new Exception("No such field in %s: %s".format(T.stringof, name));
					}
					else
					{
						if (false) // coerce return value
							return reader(this);
						else
							throw new Exception("Can't traverse %s".format(T.stringof));
					}
				}

				mixin SinkHandlers!T;
			}

			return Sink(p);
		}
	}
}

alias Deserializer!Object.makeSink deserializer;
