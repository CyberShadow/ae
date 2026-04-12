/**
 * Type serializer and deserializer.
 *
 * Defines a source/sink protocol for format-agnostic serialization.
 * A source pushes structured data events (null, boolean, numeric,
 * string, array, object) into a sink. Any source can connect to any
 * sink, enabling composable serialization paths:
 *
 * $(UL
 *   $(LI `Serializer`  — source that walks a D type and emits events)
 *   $(LI `Deserializer` — sink factory that receives events and builds a D type)
 *   $(LI `JsonParser`   — source that parses JSON text (in `ae.utils.serialization.json`))
 *   $(LI `JsonWriter`   — sink that writes JSON text (in `ae.utils.serialization.json`))
 *   $(LI `SerializedObject` — both source and sink; in-memory tree (in `ae.utils.serialization.store`))
 * )
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

module ae.utils.serialization.serialization;

import std.conv;
import std.format;
import std.traits;
import std.typecons;

import ae.utils.meta : rangeTuple;
import ae.utils.text;

// ---------------------------------------------------------------------------
// Generic serialization UDAs
// ---------------------------------------------------------------------------

/// Rename a field in serialized form.
struct SerializedName { string name; }

/// Skip serializing this field if it equals its .init value.
enum Optional;

/// On a struct type: silently skip unknown fields during deserialization.
enum IgnoreUnknown;

/// Exclude this field from serialization entirely.
enum Exclude;

/// Mark a `SerializedObject[string]` field to collect unknown fields during
/// deserialization. During serialization, entries are emitted as top-level
/// fields alongside regular struct fields.
enum Extras;

/// Check whether symbol `D` has a UDA of type `Attr`.
template hasUDA(Attr, alias D)
{
	enum bool hasUDA = {
		foreach (a; __traits(getAttributes, D))
		{
			static if (is(typeof(a) == Attr))
				return true;
			else static if (is(a == Attr))
				return true;
		}
		return false;
	}();
}

/// Retrieve the value of a UDA of type `Attr` attached to symbol `D`.
template getUDA(Attr, alias D)
{
	enum Attr getUDA = {
		foreach (a; __traits(getAttributes, D))
		{
			static if (is(typeof(a) == Attr))
				return a;
		}
		assert(false);
	}();
}

/// Detect if a type is an extras-collecting type (has a JSONFragment[string]-like _data member).
private template isExtrasType(T)
{
	static if (is(T == struct) && is(typeof(T._data) : V[string], V))
		enum isExtrasType = true;
	else
		enum isExtrasType = false;
}

/// Find the index of the @Extras field in a struct, or -1 if none.
/// Detects both the @Extras UDA and the JSONExtras type pattern.
template extrasIndex(T)
{
	enum int extrasIndex = compute();
	static int compute()
	{
		static foreach (i; 0 .. T.tupleof.length)
			static if (hasUDA!(Extras, T.tupleof[i]) || isExtrasType!(typeof(T.tupleof[i])))
				return cast(int) i;
		return -1;
	}
}

/// Check if a field is marked as non-serialized via the NonSerialized mixin pattern.
/// The NonSerialized mixin generates a `fieldName_nonSerialized` enum member.
template isNonSerialized(T, string member)
{
	enum bool isNonSerialized = __traits(hasMember, T, member ~ "_nonSerialized");
}

/// Detect struct types that behave like associative arrays (have .keys, .values, and
/// support foreach with key-value pairs). Used for types like OrderedMap.
template isMapLike(T)
{
	enum isMapLike = is(T == struct) && !is(T V : V[K], K) && is(typeof(T.init.keys)) && is(typeof(T.init.values));
}

/// Get the serialized name for a field: use @SerializedName if present, else the D identifier.
template getSerializedName(T, string dFieldName)
{
	static if (hasUDA!(SerializedName, __traits(getMember, T, dFieldName)))
		enum getSerializedName = getUDA!(SerializedName, __traits(getMember, T, dFieldName)).name;
	else
		enum getSerializedName = dFieldName;
}

// ---------------------------------------------------------------------------
// Functor helpers
// ---------------------------------------------------------------------------

/// Wraps a struct pointer + method alias into a callable (templated opCall).
private struct Bound(alias method, Ctx)
{
	Ctx ctx;
	auto opCall(Args...)(auto ref Args args)
	{
		return __traits(child, ctx, method)(args);
	}
}

private auto bound(alias method, C)(C ctx)
{
	Bound!(method, C) r = {ctx: ctx};
	return r;
}

/// Wraps a free function (template) as a zero-size callable struct.
private struct Unbound(alias f)
{
	alias opCall = f;
}

// ---------------------------------------------------------------------------
// Serializer (source)
// ---------------------------------------------------------------------------

/// Default serializer transform: no custom type handling.
template NoSerializeTransform(alias read, T)
{
	enum hasTransform = false;
}

/// Default deserializer transform: no custom type handling.
template NoDeserializeTransform(T)
{
	enum hasTransform = false;
}

/// Serialization source which walks a D value and pushes events into a sink.
///
/// Parameterized on a `Transform` template for format-specific type hooks
/// (e.g., `toJSON`). The default `NoTransform` is format-agnostic.
/// `Transform!(read, T)` must provide:
///   - `enum hasTransform` — true if this type is handled
///   - `static void serialize(Sink)(Sink sink, auto ref T v)` — serialize the value
/// The `read` alias lets the transform call back into the same serializer
/// for replacement values.
struct CustomSerializer(alias Transform = NoSerializeTransform)
{
	static template Impl(alias anchor)
	{
		static void read(Sink, T)(Sink sink, auto ref T v)
		{
			// Custom transform hook (format-specific, e.g. toJSON)
			static if (Transform!(read, T).hasTransform)
			{
				Transform!(read, T).serialize(sink, v);
			}
			else
			static if (is(T == typeof(null)))
			{
				sink.handleNull();
			}
			else
			static if (is(T X == Nullable!X))
			{
				if (v.isNull)
					sink.handleNull();
				else
					read(sink, v.get);
			}
			else
			static if (is(T == enum))
				sink.handleString(to!string(v));
			else
			static if (is(T : bool))
				sink.handleBoolean(v);
			else
			static if (isSomeChar!T)
			{
				char[4] buf = void;
				import std.utf : encode;
				auto n = encode(buf, v);
				sink.handleString(buf[0 .. n]);
			}
			else
			static if (is(T : ulong))
			{
				char[decimalSize!T] buf = void;
				sink.handleNumeric(toDec(v, buf));
			}
			else
			static if (isNumeric!T) // floating point
			{
				import std.math : isFinite;
				if (v.isFinite)
				{
					import ae.utils.textout;

					static char[64] arr;
					auto buf = StringBuffer(arr);
					formattedWrite(&buf, "%s", v);
					sink.handleNumeric(buf.get());
				}
				else
					sink.handleString(to!string(v));
			}
			else
			static if (is(T U : U*))
			{
				if (v is null)
					sink.handleNull();
				else
					read(sink, *v);
			}
			else
			static if (isTuple!T)
			{
				enum N = T.expand.length;
				static if (N == 0)
					return;
				else
				static if (N == 1)
					read(sink, v.expand[0]);
				else
				{
					alias Reader = TupleReader!T;
					auto reader = Reader(&v);
					sink.handleArray(bound!(Reader.readArray)(&reader));
				}
			}
			else
			static if (is(T == struct) && is(typeof(T.isSerializationSource)))
			{
				v.read(sink);
			}
			else
			static if (isMapLike!T)
			{
				alias K = typeof(T.init.keys[0]);
				alias V = typeof(T.init.values[0]);
				alias Reader = MapLikeReader!(T, K, V);
				auto reader = Reader(&v);
				sink.handleObject(bound!(Reader.read)(&reader));
			}
			else
			static if (is(T == struct))
			{
				auto reader = StructReader!T(&v);
				sink.handleObject(bound!(StructReader!T.read)(&reader));
			}
			else
			static if (is(T V : V[K], K))
			{
				static if (is(typeof(v is null)))
					if (v is null)
					{
						sink.handleNull();
						return;
					}
				alias Reader = AAReader!(T, K, V);
				auto reader = Reader(v);
				sink.handleObject(bound!(Reader.read)(&reader));
			}
			else
			static if (isSomeString!T)
			{
				if (v is null)
					sink.handleNull();
				else
					sink.handleString(v);
			}
			else
			static if (is(T U : U[]))
			{
				// Non-string dynamic arrays: null serializes as empty array
				alias Reader = ArrayReader!T;
				auto reader = Reader(v);
				sink.handleArray(bound!(Reader.readArray)(&reader));
			}
			else
				static assert(false, "Don't know how to serialize " ~ T.stringof);
		}

		static struct StructReader(T)
		{
			T* p;
			void read(Sink)(Sink sink)
			{
				foreach (i, ref field; p.tupleof)
				{
					enum dName = __traits(identifier, T.tupleof[i]);

					// @Exclude or NonSerialized mixin: skip entirely
					static if (hasUDA!(Exclude, T.tupleof[i]) || isNonSerialized!(T, dName))
						continue;
					else
					// @Extras: handled after regular fields
					static if (hasUDA!(Extras, T.tupleof[i]) || isExtrasType!(typeof(T.tupleof[i])))
						continue;
					else
					{
						// @Optional: skip if identical to .init
						static if (hasUDA!(Optional, T.tupleof[i]))
						{
							import ae.utils.array : isIdentical;
							if (isIdentical(field, __traits(getMember, T.init, dName)))
								continue;
						}

						enum sName = getSerializedName!(T, dName);

						alias ValueReader = Reader!(typeof(field));
						auto reader = ValueReader(&field);
						sink.handleField(Unbound!(stringReader!sName).init, bound!(ValueReader.readValue)(&reader));
					}
				}

				// Emit @Extras entries as additional top-level fields
				extrasLoop: foreach (i, ref field; p.tupleof)
				{
					static if (hasUDA!(Extras, T.tupleof[i]) || isExtrasType!(typeof(T.tupleof[i])))
					{
						foreach (string key, ref value; field)
						{
							alias V = typeof(value);
							alias VR = Reader!V;
							auto vr = VR(&value);
							static struct KeyReader(size_t j)
							{
								string key;
								void opCall(KSink)(KSink ksink)
								{
									ksink.handleString(key);
								}
							}
							KeyReader!i kr = { key: key };
							sink.handleField(kr, bound!(VR.readValue)(&vr));
						}
					}
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
					static if (isSomeString!K)
					{
						// Null string keys become empty strings (matching old behavior)
						import ae.utils.array : nonNull;
						auto nonNullKey = k.nonNull;
						alias KeyReader   = Reader!(typeof(nonNullKey));
						auto keyReader   = KeyReader  (&nonNullKey);
					}
					else
					{
						alias KeyReader   = Reader!K;
						auto keyReader   = KeyReader  (&k);
					}
					alias ValueReader = Reader!V;
					auto valueReader = ValueReader(&v);
					sink.handleField(
						bound!(KeyReader  .readValue)(&keyReader  ),
						bound!(ValueReader.readValue)(&valueReader),
					);
				}
			}
		}

		static struct MapLikeReader(T, K, V)
		{
			T* p;
			void read(Sink)(Sink sink)
			{
				foreach (key, value; *p)
				{
					auto k = key;
					static if (isSomeString!(typeof(k)))
					{
						import ae.utils.array : nonNull;
						auto nonNullKey = k.nonNull;
						alias KeyReader   = Reader!(typeof(nonNullKey));
						auto keyReader   = KeyReader  (&nonNullKey);
					}
					else
					{
						alias KeyReader   = Reader!(typeof(k));
						auto keyReader   = KeyReader  (&k);
					}
					auto v = value;
					alias ValueReader = Reader!(typeof(v));
					auto valueReader = ValueReader(&v);
					sink.handleField(
						bound!(KeyReader  .readValue)(&keyReader  ),
						bound!(ValueReader.readValue)(&valueReader),
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

		static struct TupleReader(T)
		{
			T* p;
			void readArray(Sink)(Sink sink)
			{
				foreach (n; rangeTuple!(T.expand.length))
					read(sink, p.expand[n]);
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

/// Default Serializer with no format-specific transforms.
alias Serializer = CustomSerializer!NoSerializeTransform;

// ---------------------------------------------------------------------------
// Drain sink: discards any value, used for @IgnoreUnknown
// ---------------------------------------------------------------------------

private struct DrainSink
{
	void handleNull() {}
	void handleBoolean(bool v) {}
	void handleNumeric(CC)(CC[] v) {}
	void handleString(S)(S s) {}
	void handleStringFragments(Reader)(Reader reader)
	{
		static struct FragSink { void handleStringFragment(CC)(CC[] s) {} }
		FragSink fs;
		reader(&fs);
	}
	void handleArray(Reader)(Reader reader)
	{
		DrainSink ds;
		reader(&ds);
	}
	void handleObject(Reader)(Reader reader)
	{
		static struct FieldDrainSink
		{
			void handleField(NR, VR)(NR nameReader, VR valueReader)
			{
				DrainSink ds;
				nameReader(&ds);
				valueReader(&ds);
			}
		}
		FieldDrainSink fs;
		reader(&fs);
	}
}

// ---------------------------------------------------------------------------
// Deserializer (sink)
// ---------------------------------------------------------------------------

/// Sink factory which creates sinks that deserialize events into D types.
///
/// Parameterized on a `Transform` template for format-specific type hooks
/// (e.g., `fromJSON`). The default `NoDeserializeTransform` is format-agnostic.
/// `Transform!(T)` must provide:
///   - `enum hasTransform` — true if this type is handled
///   - `static auto makeSink(T* p)` — return a sink that deserializes into `*p`
template CustomDeserializer(alias Transform, alias anchor)
{
	alias C = immutable(char); // TODO

	mixin template SinkHandlers(T)
	{
		// When T implements the sink protocol, forward all events to a
		// temporary T instance, then pass it to handleValue.
		static if (is(typeof(T.isSerializationSink)))
		{
			private void sinkForward(string method, Args...)(auto ref Args args)
			{
				T v;
				mixin("v." ~ method ~ "(args);");
				handleValue(v);
			}

			void handleString(S)(S s) { sinkForward!"handleString"(s); }
			void handleStringFragments(Reader)(Reader r) { sinkForward!"handleStringFragments"(r); }
			void handleArray(Reader)(Reader r) { sinkForward!"handleArray"(r); }
			void handleObject(Reader)(Reader r) { sinkForward!"handleObject"(r); }
			void handleNull() { T v; v.handleNull(); handleValue(v); }
			void handleBoolean(bool b) { sinkForward!"handleBoolean"(b); }
			void handleNumeric(CC)(CC[] s) { sinkForward!"handleNumeric"(s); }
		}
		else
		static if (Transform!T.hasTransform)
		{
			// Transform handles this type — forward all events through
			// the transform's makeSink, which deserializes into T.
			private void transformForward(string method, Args...)(auto ref Args args)
			{
				T v;
				auto s = Transform!T.makeSink(&v);
				mixin("s." ~ method ~ "(args);");
				handleValue(v);
			}

			void handleString(S)(S s) { transformForward!"handleString"(s); }
			void handleStringFragments(Reader)(Reader r) { transformForward!"handleStringFragments"(r); }
			void handleArray(Reader)(Reader r) { transformForward!"handleArray"(r); }
			void handleObject(Reader)(Reader r) { transformForward!"handleObject"(r); }
			void handleNull() { transformForward!"handleNull"(); }
			void handleBoolean(bool b) { transformForward!"handleBoolean"(b); }
			void handleNumeric(CC)(CC[] s) { transformForward!"handleNumeric"(s); }
		}
		else
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

		static if (is(T U : U[]) && !isStaticArray!T)
			void handleArray(Reader)(Reader reader)
			{
				ArraySink!U sink;
				reader(&sink);
				handleValue(sink.arr);
			}
		else
		static if (isStaticArray!T)
			void handleArray(Reader)(Reader reader)
			{
				StaticArraySink!T sink;
				reader(&sink);
				handleValue(sink.arr);
			}
		else
		static if (isTuple!T)
			void handleArray(Reader)(Reader reader)
			{
				TupleSink!T sink;
				reader(&sink);
				handleValue(sink.tup);
			}
		else
			alias handleArray = unparseable!"array";

		static if (is(T V : V[K], K) || isMapLike!T)
			void handleObject(Reader)(Reader reader)
			{
				static if (isMapLike!T)
				{
					alias K = typeof(T.init.keys[0]);
					alias V = typeof(T.init.values[0]);
				}
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
		static if (is(T == struct) && !isTuple!T && !is(T X == Nullable!X))
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
							// Skip @Exclude, @Extras, NonSerialized, and JSONExtras-type fields during matching
							static if (!hasUDA!(Exclude, T.tupleof[i]) && !hasUDA!(Extras, T.tupleof[i])
								&& !isNonSerialized!(T, __traits(identifier, T.tupleof[i]))
								&& !isExtrasType!(typeof(T.tupleof[i])))
							{
								enum fieldName = to!N(getSerializedName!(T, __traits(identifier, T.tupleof[i])));
								if (name == fieldName)
								{
									alias V = typeof(field);
									valueReader(makeSink!V(&s.tupleof[i]));
									return;
								}
							}
						}
						// @Extras: store unknown fields
						enum extrasFieldIndex = extrasIndex!T;
						static if (extrasFieldIndex != -1)
						{
							alias EV = typeof(s.tupleof[extrasFieldIndex].init[""]);
							EV val;
							valueReader(makeSink!EV(&val));
							s.tupleof[extrasFieldIndex][name] = val;
						}
						else
						// @IgnoreUnknown: silently drain unknown fields (any value type)
						static if (hasUDA!(IgnoreUnknown, T))
						{
							DrainSink ds;
							valueReader(&ds);
						}
						else
							throw new Exception("Unknown field %s".format(name));
					}
				}

				FieldSink sink;
				static if (is(typeof(p) == T*))
					sink.s = *p;
				reader(&sink);
				handleValue(sink.s);
			}
		}
		else
			alias handleObject = unparseable!"object";

		void handleNull()
		{
			static if (is(T X == Nullable!X))
			{
				T v;  // Nullable.init is null
				handleValue(v);
			}
			else
			static if (is(T U : U*))
			{
				T v = null;
				handleValue(v);
			}
			else
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

		} // end else (non-sink T)
	}

	static struct ArraySink(T)
	{
		T[] arr;

		void handleValue(ref T v) { arr ~= v; }

		mixin SinkHandlers!T;
	}

	static struct StaticArraySink(T)
	if (isStaticArray!T)
	{
		alias U = typeof(T.init[0]);
		enum N = T.length;
		T arr;
		size_t idx;

		void handleValue(ref U v)
		{
			if (idx >= N)
				throw new Exception("Too many elements for static array of length %d".format(N));
			arr[idx++] = v;
		}

		mixin SinkHandlers!U;
	}

	static struct TupleSink(T)
	if (isTuple!T)
	{
		enum N = T.expand.length;
		T tup;
		size_t idx;

		// Dispatch a handler call to the correct tuple element by runtime index.
		// Creates a makeSink for the element at each possible index and forwards.
		private void dispatch(string handler, Args...)(Args args)
		{
			foreach (n; rangeTuple!N)
			{
				if (idx == n)
				{
					alias E = typeof(T.expand[n]);
					auto s = makeSink!E(&tup.expand[n]);
					__traits(getMember, s, handler)(args);
					idx++;
					return;
				}
			}
			throw new Exception("Too many elements for tuple of length %d".format(N));
		}

		void handleNull() { dispatch!"handleNull"(); }
		void handleBoolean(bool v) { dispatch!"handleBoolean"(v); }
		void handleNumeric(CC)(CC[] v) { dispatch!"handleNumeric"(v); }
		void handleString(S)(S s) { dispatch!"handleString"(s); }
		void handleArray(Reader)(Reader r) { dispatch!"handleArray"(r); }
		void handleObject(Reader)(Reader r) { dispatch!"handleObject"(r); }
	}

	static auto makeSink(T)(T* p)
	{
		static if (is(typeof(p.isSerializationSink)))
			return p;
		else
		static if (is(T X == Nullable!X))
		{
			// Special sink for Nullable: intercepts handleNull, delegates rest to inner type
			static struct NullableSink
			{
				T* p;

				void handleValue(ref X v) { *p = T(v); }
				void handleNull() { *p = T.init; }

				// Delegate all other handlers to an inner sink for X
				mixin SinkHandlers!X;
			}

			return NullableSink(p);
		}
		else
		static if (isTuple!T)
		{
			enum N = T.expand.length;

			static if (N == 0)
			{
				static struct EmptyTupleSink
				{
					T* p;
					void handleValue(ref T v) { *p = v; }
					void handleNull() {}
					void handleBoolean(bool) {}
					void handleNumeric(scope const(char)[]) {}
					void handleString(S)(S) {}
					void handleArray(Reader)(Reader) {}
					void handleObject(Reader)(Reader) {}
				}
				return EmptyTupleSink(p);
			}
			else
			static if (N == 1)
			{
				// 1-element tuple: serialized bare, delegate to inner type
				alias E = typeof(T.expand[0]);
				static struct SingleTupleSink
				{
					T* p;

					void handleValue(ref E v) { p.expand[0] = v; }

					mixin SinkHandlers!E;
				}

				return SingleTupleSink(p);
			}
			else
			{
				// N >= 2: serialized as array, use TupleSink via handleArray in SinkHandlers
				static struct MultiTupleSink
				{
					T* p;

					void handleValue(ref T v) { *p = v; }

					void handleArray(Reader)(Reader reader)
					{
						TupleSink!T sink;
						reader(&sink);
						*p = sink.tup;
					}

					template unparseable(string inputType)
					{
						void unparseable(Reader)(Reader reader)
						{
							throw new Exception("Can't parse %s from %s".format(T.stringof, inputType));
						}
					}

					alias handleObject = unparseable!"object";
					alias handleStringFragments = unparseable!"string fragments";

					void handleNull()
					{
						throw new Exception("Can't parse %s from null".format(T.stringof));
					}

					void handleBoolean(bool v)
					{
						throw new Exception("Can't parse %s from boolean".format(T.stringof));
					}

					void handleNumeric(CC)(CC[] v)
					{
						throw new Exception("Can't parse %s from numeric".format(T.stringof));
					}

					void handleString(S)(S s)
					{
						throw new Exception("Can't parse %s from string".format(T.stringof));
					}
				}

				return MultiTupleSink(p);
			}
		}
		else
		static if (is(T == typeof(null)))
		{
			static struct NullTypeSink
			{
				T* p;
				void handleNull() { *p = null; }
				void handleValue(ref T v) { *p = v; }
				void handleBoolean(bool) {}
				void handleNumeric(CC)(CC[]) {}
				void handleString(S)(S) {}
				void handleArray(Reader)(Reader) {}
				void handleObject(Reader)(Reader) {}
			}
			return NullTypeSink(p);
		}
		else
		static if (is(T U : U*))
		{
			// Pointer sink: handleNull -> leave null, others -> allocate and deserialize
			static struct PointerSink
			{
				T* p;

				void handleValue(ref U v)
				{
					*p = new U;
					**p = v;
				}

				void handleNull() { *p = null; }

				mixin SinkHandlers!U;
			}

			return PointerSink(p);
		}
		else
		static if (Transform!T.hasTransform)
		{
			return Transform!T.makeSink(p);
		}
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

/// Default Deserializer with no format-specific transforms.
template Deserializer(alias anchor)
{
	alias Deserializer = CustomDeserializer!(NoDeserializeTransform, anchor);
}

alias deserializer = Deserializer!Object.makeSink;

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

debug(ae_unittest) unittest
{
	// Test struct with nested struct, array, and AA fields
	static struct Inner
	{
		int x;
		string s;
	}

	static struct Outer
	{
		int a;
		string name;
		Inner inner;
		int[] arr;
		string[string] map;
	}

	// Build test value
	Outer original;
	original.a = 42;
	original.name = "hello";
	original.inner.x = 7;
	original.inner.s = "world";
	original.arr = [1, 2, 3];
	original.map = ["key1": "val1", "key2": "val2"];

	// Round-trip: Serializer -> Deserializer
	Outer result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);

	assert(result.a == 42);
	assert(result.name == "hello");
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
	assert(result.map == ["key1": "val1", "key2": "val2"]);
}

debug(ae_unittest) unittest
{
	// Test with simple types
	{
		int result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, 123);
		assert(result == 123);
	}
	{
		string result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, "test");
		assert(result == "test");
	}
	{
		bool result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, true);
		assert(result == true);
	}
}

// Test enums
debug(ae_unittest) unittest
{
	enum Color { red, green, blue }

	Color original = Color.green;
	Color result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result == Color.green);
}

// Test Nullable
debug(ae_unittest) unittest
{
	{
		Nullable!int original = Nullable!int(42);
		Nullable!int result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(!result.isNull);
		assert(result.get == 42);
	}
	{
		Nullable!int original;
		assert(original.isNull);
		Nullable!int result = Nullable!int(99);
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(result.isNull);
	}
}

// Test pointers
debug(ae_unittest) unittest
{
	{
		int val = 42;
		int* original = &val;
		int* result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(result !is null);
		assert(*result == 42);
	}
	{
		int* original = null;
		int* result = new int;
		*result = 99;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(result is null);
	}
}

// Test static arrays
debug(ae_unittest) unittest
{
	int[3] original = [10, 20, 30];
	int[3] result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result == [10, 20, 30]);
}

// Test Tuples
debug(ae_unittest) unittest
{
	import std.typecons : Tuple, tuple;

	{
		alias T = Tuple!(int, string);
		T original = T(42, "hello");
		T result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(result[0] == 42);
		assert(result[1] == "hello");
	}
	{
		alias T = Tuple!(int);
		T original = T(42);
		T result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(result[0] == 42);
	}
}

// Test toJSON / fromJSON hooks — DISABLED: toJSON moved out of generic Serializer
// (see spike_tojson_layering.d for the new approach)
version(none) debug(ae_unittest) unittest
{
	static struct Wrapper
	{
		int value;

		string toJSON() const { return to!string(value); }
		static Wrapper fromJSON(string s) { return Wrapper(to!int(s)); }
	}

	Wrapper original = Wrapper(42);
	Wrapper result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.value == 42);
}

// Test enum inside struct
debug(ae_unittest) unittest
{
	enum Dir { north, south, east, west }

	static struct S
	{
		Dir dir;
		int speed;
	}

	S original = S(Dir.east, 5);
	S result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.dir == Dir.east);
	assert(result.speed == 5);
}

// Test Nullable inside struct
debug(ae_unittest) unittest
{
	static struct S
	{
		Nullable!int x;
		string name;
	}

	{
		S original;
		original.x = 42;
		original.name = "test";
		S result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(!result.x.isNull);
		assert(result.x.get == 42);
		assert(result.name == "test");
	}
	{
		S original;
		original.name = "test";
		S result;
		auto sink = deserializer(&result);
		Serializer.Impl!Object.read(sink, original);
		assert(result.x.isNull);
		assert(result.name == "test");
	}
}

// Test pointer to struct
debug(ae_unittest) unittest
{
	static struct Inner
	{
		int x;
	}

	Inner val = Inner(7);
	Inner* original = &val;
	Inner* result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result !is null);
	assert(result.x == 7);
}

// Test @SerializedName
debug(ae_unittest) unittest
{
	static struct S
	{
		int a;
		@SerializedName("renamed_b") int b;
	}

	S original = S(1, 2);

	string[string] asAA;
	auto aaSink = deserializer(&asAA);
	Serializer.Impl!Object.read(aaSink, original);
	assert("a" in asAA);
	assert("renamed_b" in asAA);
	assert("b" !in asAA);

	S result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result == original);
}

// Test @Optional
debug(ae_unittest) unittest
{
	static struct S
	{
		int a;
		@Optional int b;
		@Optional int c;
	}

	S original = S(42, 0, 7);

	string[string] asAA;
	auto aaSink = deserializer(&asAA);
	Serializer.Impl!Object.read(aaSink, original);
	assert("a" in asAA);
	assert("b" !in asAA);
	assert("c" in asAA);

	S result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.a == 42);
	assert(result.b == 0);
	assert(result.c == 7);
}

// Test @IgnoreUnknown
debug(ae_unittest) unittest
{
	static struct Full
	{
		int a;
		int b;
		int c;
	}

	@IgnoreUnknown static struct Partial
	{
		int a;
		int c;
	}

	Full original = Full(1, 2, 3);

	Partial result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.a == 1);
	assert(result.c == 3);
}

// Test @IgnoreUnknown with non-scalar unknown fields
debug(ae_unittest) unittest
{
	static struct Inner { int x; int y; }

	static struct Full
	{
		int a;
		Inner nested;
		int[] arr;
		int c;
	}

	@IgnoreUnknown static struct Partial
	{
		int a;
		int c;
	}

	Full original = Full(1, Inner(10, 20), [100, 200], 3);

	Partial result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.a == 1);
	assert(result.c == 3);
}

// Test @Exclude
debug(ae_unittest) unittest
{
	static struct S
	{
		int a;
		@Exclude int secret;
		int c;
	}

	S original = S(1, 42, 3);

	string[string] asAA;
	auto aaSink = deserializer(&asAA);
	Serializer.Impl!Object.read(aaSink, original);
	assert("a" in asAA);
	assert("secret" !in asAA);
	assert("c" in asAA);

	S result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.a == 1);
	assert(result.secret == 0);
	assert(result.c == 3);
}

// Test @Extras -- collects unknown fields during deserialization
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	static struct Full
	{
		int a;
		int b;
		string c;
	}

	static struct Partial
	{
		int a;
		@Extras SO[string] extras;
	}

	Full original = Full(1, 2, "hello");

	Partial result;
	auto sink = deserializer(&result);
	Serializer.Impl!Object.read(sink, original);
	assert(result.a == 1);
	assert("b" in result.extras);
	assert("c" in result.extras);
}

// Test @Extras -- emits entries during serialization
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	static struct S
	{
		int a;
		@Extras SO[string] extras;
	}

	S original;
	original.a = 1;
	original.extras["b"] = SO(42);
	original.extras["c"] = SO("hello");

	// Round-trip through another struct
	string[string] asAA;
	auto sink = deserializer(&asAA);
	Serializer.Impl!Object.read(sink, original);
	assert("a" in asAA);
	assert("b" in asAA);
	assert("c" in asAA);
}

// Test @Extras round-trip
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	static struct Full { int a; int b; string c; }
	static struct Partial { int a; @Extras SO[string] extras; }

	Full original = Full(1, 2, "hello");

	// Full -> Partial (collects extras)
	Partial partial;
	auto sink1 = deserializer(&partial);
	Serializer.Impl!Object.read(sink1, original);
	assert(partial.a == 1);
	assert("b" in partial.extras);
	assert("c" in partial.extras);

	// Partial -> Full (re-emits extras)
	Full result;
	auto sink2 = deserializer(&result);
	Serializer.Impl!Object.read(sink2, partial);
	assert(result.a == 1);
	assert(result.b == 2);
	assert(result.c == "hello");
}
