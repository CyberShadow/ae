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

/// Mark a struct field to receive positional (unnamed) values.
/// During deserialization from a Map, the empty-string key ("") is
/// routed to this field. Formats like SDL and XML use positional values
/// for tag values / text content.
enum Positional;

/// Additional name accepted during deserialization (not used for serialization).
/// Allows a single struct field to match multiple source names — e.g.,
/// "dependencies" from JSON and "dependency" from SDL.
struct SerializedAlias { string name; }

/// Mark a `SerializedObject[string]` field to collect unknown fields during
/// deserialization. During serialization, entries are emitted as top-level
/// fields alongside regular struct fields.
enum Extras;

/// Check whether symbol `D` has a UDA of type `Attr`.
template hasUDA(Attr, alias D)
{
	enum bool hasUDA = {
		bool result = false;
		foreach (a; __traits(getAttributes, D))
		{
			static if (is(typeof(a) == Attr))
				result = true;
			else static if (is(a == Attr))
				result = true;
		}
		return result;
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
		int result = -1;
		static foreach (i; 0 .. T.tupleof.length)
			static if (hasUDA!(Extras, T.tupleof[i]) || isExtrasType!(typeof(T.tupleof[i])))
				result = cast(int) i;
		return result;
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
// Protocol value types
// ---------------------------------------------------------------------------

/// Protocol value types for the unified `handle(V)` sink method.
/// Every sink implements a single `void handle(V)(V v)` and dispatches
/// on V using `static if`. Sources emit these types via `sink.handle(...)`.

struct Null {}
struct Boolean { bool value; }
struct Numeric(S) { S text; }
struct String(S) { S text; }
struct Array(Reader) { Reader reader; }
struct Map(Reader) { Reader reader; }
struct Field(NR, VR) { NR nameReader; VR valueReader; }

// ---------------------------------------------------------------------------
// Protocol concept templates (Design by Introspection)
// ---------------------------------------------------------------------------

/// True if V is a null protocol value.
enum bool isProtocolNull(V) = is(V == Null);

/// True if V is a boolean protocol value.
/// Required: `.value` of type `bool`.
enum bool isProtocolBoolean(V) = is(V == Boolean) || isCustomProtocolBoolean!V;

private template isCustomProtocolBoolean(V)
{
	static if (is(typeof(V.init.value) : bool) && __traits(hasMember, V, "isProtocolBoolean"))
		enum bool isCustomProtocolBoolean = V.isProtocolBoolean;
	else
		enum bool isCustomProtocolBoolean = false;
}

/// True if V is a numeric protocol value.
/// Required: `.text` convertible to `const(char)[]`.
enum bool isProtocolNumeric(V) = is(V : Numeric!S, S) || isCustomProtocolNumeric!V;

private template isCustomProtocolNumeric(V)
{
	static if (is(typeof(V.init.text) : const(char)[]) && __traits(hasMember, V, "isProtocolNumeric"))
		enum bool isCustomProtocolNumeric = V.isProtocolNumeric;
	else
		enum bool isCustomProtocolNumeric = false;
}

/// True if V is a string protocol value.
/// Required: `.text` that is some char array.
enum bool isProtocolString(V) = is(V : String!S, S) || isCustomProtocolString!V;

private template isCustomProtocolString(V)
{
	static if (is(typeof(V.init.text) : const(char)[]) && __traits(hasMember, V, "isProtocolString"))
		enum bool isCustomProtocolString = V.isProtocolString;
	else
		enum bool isCustomProtocolString = false;
}

/// True if V is an array protocol value.
/// Required: `.reader` callable as `v.reader(&sink)`.
enum bool isProtocolArray(V) = is(V : Array!R, R) || isCustomProtocolArray!V;

private template isCustomProtocolArray(V)
{
	static if (__traits(hasMember, V, "reader") && __traits(hasMember, V, "isProtocolArray"))
		enum bool isCustomProtocolArray = V.isProtocolArray;
	else
		enum bool isCustomProtocolArray = false;
}

/// True if V is a map protocol value.
/// Required: `.reader` callable as `v.reader(&sink)`.
/// Optional properties (checked via mapAllowRepeatedKeys, mapAllowBlankKeys):
///   - `allowRepeatedKeys` (default: false)
///   - `allowBlankKeys` (default: false)
enum bool isProtocolMap(V) = is(V : Map!R, R) || isCustomProtocolMap!V;

private template isCustomProtocolMap(V)
{
	static if (__traits(hasMember, V, "reader") && __traits(hasMember, V, "isProtocolMap"))
		enum bool isCustomProtocolMap = V.isProtocolMap;
	else
		enum bool isCustomProtocolMap = false;
}

/// True if V is a field protocol value.
/// Required: `.nameReader`, `.valueReader` callables.
enum bool isProtocolField(V) = is(V : Field!(NR, VR), NR, VR) || isCustomProtocolField!V;

private template isCustomProtocolField(V)
{
	static if (__traits(hasMember, V, "nameReader") && __traits(hasMember, V, "valueReader")
		&& __traits(hasMember, V, "isProtocolField"))
		enum bool isCustomProtocolField = V.isProtocolField;
	else
		enum bool isCustomProtocolField = false;
}

// ---------------------------------------------------------------------------
// Property accessor templates
// ---------------------------------------------------------------------------

/// Whether a map protocol value allows repeated keys (e.g., SDL repeated tags).
template mapAllowRepeatedKeys(V)
{
	static if (__traits(hasMember, V, "allowRepeatedKeys"))
		enum bool mapAllowRepeatedKeys = V.allowRepeatedKeys;
	else
		enum bool mapAllowRepeatedKeys = false;
}

/// Whether a map protocol value allows blank (empty-string) keys for positional values.
template mapAllowBlankKeys(V)
{
	static if (__traits(hasMember, V, "allowBlankKeys"))
		enum bool mapAllowBlankKeys = V.allowBlankKeys;
	else
		enum bool mapAllowBlankKeys = false;
}

/// Extract the text type from a Numeric or String protocol value.
template ProtocolTextType(V)
{
	static if (is(V : Numeric!S, S) || is(V : String!S, S))
		alias ProtocolTextType = S;
	else
		alias ProtocolTextType = typeof(V.init.text);
}

// ---------------------------------------------------------------------------
// Rewrap helpers for filters
// ---------------------------------------------------------------------------

/// Construct an array protocol value with the same properties as the original,
/// but with a different reader.
auto rewrapArray(OrigArray, NewReader)(OrigArray orig, NewReader newReader)
{
	static if (is(OrigArray : Array!R, R))
		return Array!NewReader(newReader);
	else
	{
		static struct RewrappedArray
		{
			enum isProtocolArray = true;
			NewReader reader;
		}
		return RewrappedArray(newReader);
	}
}

/// Construct a map protocol value with the same properties as the original,
/// but with a different reader.
auto rewrapMap(OrigMap, NewReader)(OrigMap orig, NewReader newReader)
{
	static if (is(OrigMap : Map!R, R))
		return Map!NewReader(newReader);
	else
	{
		static struct RewrappedMap
		{
			enum isProtocolMap = true;
			static if (__traits(hasMember, OrigMap, "allowRepeatedKeys"))
				enum allowRepeatedKeys = OrigMap.allowRepeatedKeys;
			static if (__traits(hasMember, OrigMap, "allowBlankKeys"))
				enum allowBlankKeys = OrigMap.allowBlankKeys;
			NewReader reader;
		}
		return RewrappedMap(newReader);
	}
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

/// Options controlling serialization behavior.
struct SerializerOptions
{
	/// How to serialize null D values (null strings, null AAs).
	/// Dynamic arrays (non-string) always serialize as empty arrays
	/// regardless of this setting, since null and empty arrays are
	/// semantically equivalent in D.
	enum NullHandling
	{
		/// Serialize null strings/AAs as null. This is the default
		/// and matches the old `ae.utils.json` behavior.
		asNull,
		/// Serialize null strings as `""` and null AAs as `{}`.
		/// Useful when targeting consumers where null and empty are
		/// incompatible types (e.g., JavaScript).
		asEmpty,
	}
	NullHandling nullHandling = NullHandling.asNull; /// ditto
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
struct CustomSerializer(alias Transform = NoSerializeTransform, SerializerOptions options = SerializerOptions.init)
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
				sink.handle(Null());
			}
			else
			static if (is(T X == Nullable!X))
			{
				if (v.isNull)
					sink.handle(Null());
				else
					read(sink, v.get);
			}
			else
			static if (is(T == enum))
				sink.handle(String!string(to!string(v)));
			else
			static if (is(T : bool))
				sink.handle(Boolean(v));
			else
			static if (isSomeChar!T)
			{
				char[4] buf = void;
				import std.utf : encode;
				auto n = encode(buf, v);
				auto s = buf[0 .. n];
				sink.handle(String!(typeof(s))(s));
			}
			else
			static if (is(T : ulong))
			{
				char[decimalSize!T] buf = void;
				auto s = toDec(v, buf);
				sink.handle(Numeric!(typeof(s))(s));
			}
			else
			static if (isNumeric!T) // floating point
			{
				import std.math : isFinite;
				if (v.isFinite)
				{
					import ae.utils.text : putFP;
					import ae.utils.textout : StaticBuf;
					StaticBuf!(char, 66) buf;
					putFP(buf, v);
					auto s = buf.data();
					// Ensure float values are distinguishable from integers
					// by always including a '.' or 'e' in the representation.
					bool hasMarker = false;
					foreach (c; s)
						if (c == '.' || c == 'e' || c == 'E')
						{
							hasMarker = true;
							break;
						}
					if (hasMarker)
						sink.handle(Numeric!(typeof(s))(s));
					else
					{
						buf.put('.');
						buf.put('0');
						sink.handle(Numeric!(typeof(buf.data()))(buf.data()));
					}
				}
				else
					sink.handle(String!string(to!string(v)));
			}
			else
			static if (is(T U : U*))
			{
				if (v is null)
					sink.handle(Null());
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
					auto b = bound!(Reader.readArray)(&reader);
					sink.handle(Array!(typeof(b))(b));
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
				auto b = bound!(Reader.read)(&reader);
				sink.handle(Map!(typeof(b))(b));
			}
			else
			static if (is(T == struct))
			{
				auto reader = StructReader!T(&v);
				auto b = bound!(StructReader!T.read)(&reader);
				sink.handle(Map!(typeof(b))(b));
			}
			else
			static if (is(T V : V[K], K))
			{
				static if (is(typeof(v is null)))
					if (v is null)
					{
						static if (options.nullHandling == SerializerOptions.NullHandling.asEmpty)
						{
							alias Reader2 = AAReader!(T, K, V);
							auto reader2 = Reader2(v);
							auto b2 = bound!(Reader2.read)(&reader2);
							sink.handle(Map!(typeof(b2))(b2));
						}
						else
							sink.handle(Null());
						return;
					}
				alias Reader = AAReader!(T, K, V);
				auto reader = Reader(v);
				auto b = bound!(Reader.read)(&reader);
				sink.handle(Map!(typeof(b))(b));
			}
			else
			static if (isSomeString!T)
			{
				if (v is null)
				{
					static if (options.nullHandling == SerializerOptions.NullHandling.asEmpty)
						sink.handle(String!(immutable(char)[])(""));
					else
						sink.handle(Null());
				}
				else
					sink.handle(String!T(v));
			}
			else
			static if (is(T U : U[]))
			{
				// Non-string dynamic arrays: null serializes as empty array
				alias Reader = ArrayReader!T;
				auto reader = Reader(v);
				auto b = bound!(Reader.readArray)(&reader);
				sink.handle(Array!(typeof(b))(b));
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
						auto nr = Unbound!(stringReader!sName).init;
						auto vr = bound!(ValueReader.readValue)(&reader);
						sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
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
									ksink.handle(String!string(key));
								}
							}
							KeyReader!i kr = { key: key };
							auto vrb = bound!(VR.readValue)(&vr);
							sink.handle(Field!(KeyReader!i, typeof(vrb))(kr, vrb));
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
					auto knr = bound!(KeyReader  .readValue)(&keyReader  );
					auto vnr = bound!(ValueReader.readValue)(&valueReader);
					sink.handle(Field!(typeof(knr), typeof(vnr))(knr, vnr));
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
					auto knr = bound!(KeyReader  .readValue)(&keyReader  );
					auto vnr = bound!(ValueReader.readValue)(&valueReader);
					sink.handle(Field!(typeof(knr), typeof(vnr))(knr, vnr));
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
				sink.handle(String!string(name));
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
	void handle(V)(V v)
	{
		static if (isProtocolArray!V) v.reader(&this);
		else static if (isProtocolMap!V) v.reader(&this);
		else static if (isProtocolField!V) { v.nameReader(&this); v.valueReader(&this); }
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
			void handle(V)(V v)
			{
				T tv;
				tv.handle(v);
				handleValue(tv);
			}
		}
		else
		static if (Transform!T.hasTransform)
		{
			// Transform handles this type — forward all events through
			// the transform's makeSink, which deserializes into T.
			void handle(V)(V v)
			{
				T tv;
				auto s = Transform!T.makeSink(&tv);
				s.handle(v);
				handleValue(tv);
			}
		}
		else
		{

		void handle(V)(V v)
		{
			static if (isProtocolNull!V)
			{
				static if (is(T X == Nullable!X))
				{
					T tv;  // Nullable.init is null
					handleValue(tv);
				}
				else
				static if (is(T U : U*))
				{
					T tv = null;
					handleValue(tv);
				}
				else
				static if (is(typeof({T tv = null;})))
				{
					T tv = null;
					handleValue(tv);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "null"));
			}
			else
			static if (isProtocolBoolean!V)
			{
				static if (is(T : bool))
				{
					auto bv = v.value;
					handleValue(bv);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "boolean"));
			}
			else
			static if (isProtocolNumeric!V)
			{
				static if (is(typeof(to!T(v.text))))
				{
					T t = to!T(v.text);
					handleValue(t);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "numeric"));
			}
			else
			static if (isProtocolString!V)
			{
				alias S = ProtocolTextType!V;
				static if (is(typeof(v.text.to!T)))
				{
					T t = to!T(v.text);
					handleValue(t);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, S.stringof));
			}
			else
			static if (isProtocolArray!V)
			{
				static if (is(T U : U[]) && !isStaticArray!T)
				{
					ArraySink!U sink;
					v.reader(&sink);
					handleValue(sink.arr);
				}
				else
				static if (isStaticArray!T)
				{
					StaticArraySink!T sink;
					v.reader(&sink);
					handleValue(sink.arr);
				}
				else
				static if (isTuple!T)
				{
					TupleSink!T sink;
					v.reader(&sink);
					handleValue(sink.tup);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "array"));
			}
			else
			static if (isProtocolMap!V)
			{
				static if (is(T VV : VV[K], K) || isMapLike!T)
				{
					static if (isMapLike!T)
					{
						alias K = typeof(T.init.keys[0]);
						alias VV = typeof(T.init.values[0]);
					}
					static struct AAFieldSink
					{
						T aa;

						void handle(FV)(FV fv)
						{
							static if (isProtocolField!FV)
							{
								K k;
								VV fvv;
								fv.nameReader (makeSink!K(&k));
								fv.valueReader(makeSink!VV(&fvv));
								aa[k] = fvv;
							}
						}
					}

					AAFieldSink sink;
					v.reader(&sink);
					handleValue(sink.aa);
				}
				else
				static if (is(T == struct) && !isTuple!T && !is(T X == Nullable!X))
				{
					static struct StructFieldSink
					{
						T s;

						void handle(FV)(FV fv)
						{
							static if (isProtocolField!FV)
							{
								alias N = const(C)[];
								N name;
								fv.nameReader(makeSink!N(&name));

								// Blank key → @Positional field (SDL/XML positional values)
								if (name.length == 0)
								{
									foreach (i, field; s.tupleof)
									{
										static if (hasUDA!(Positional, T.tupleof[i]))
										{
											alias FVT = typeof(field);
											fv.valueReader(makeSink!FVT(&s.tupleof[i]));
											return;
										}
									}
									// No @Positional — fall through to @Extras / @IgnoreUnknown
								}
								else
								{
									// Named field lookup
									foreach (i, field; s.tupleof)
									{
										// Skip @Exclude, @Extras, NonSerialized, @Positional, and JSONExtras-type fields during matching
										static if (!hasUDA!(Exclude, T.tupleof[i]) && !hasUDA!(Extras, T.tupleof[i])
											&& !hasUDA!(Positional, T.tupleof[i])
											&& !isNonSerialized!(T, __traits(identifier, T.tupleof[i]))
											&& !isExtrasType!(typeof(T.tupleof[i])))
										{
											enum fieldName = to!N(getSerializedName!(T, __traits(identifier, T.tupleof[i])));
											if (name == fieldName)
											{
												alias FVT = typeof(field);
												// allowRepeatedKeys: append to array fields instead of overwriting
												static if (mapAllowRepeatedKeys!V
													&& is(FVT : E[], E) && !isSomeString!FVT)
												{
													E elem;
													fv.valueReader(makeSink!E(&elem));
													s.tupleof[i] ~= elem;
												}
												else
													fv.valueReader(makeSink!FVT(&s.tupleof[i]));
												return;
											}
											// Check @SerializedAlias
											static if (hasUDA!(SerializedAlias, T.tupleof[i]))
											{
												enum aliasName = to!N(getUDA!(SerializedAlias, T.tupleof[i]).name);
												if (name == aliasName)
												{
													alias FVT2 = typeof(field);
													static if (mapAllowRepeatedKeys!V
														&& is(FVT2 : E2[], E2) && !isSomeString!FVT2)
													{
														E2 elem;
														fv.valueReader(makeSink!E2(&elem));
														s.tupleof[i] ~= elem;
													}
													else
														fv.valueReader(makeSink!FVT2(&s.tupleof[i]));
													return;
												}
											}
										}
									}
								}
								// @Extras: store unknown fields
								enum extrasFieldIndex = extrasIndex!T;
								static if (extrasFieldIndex != -1)
								{
									alias EV = typeof(s.tupleof[extrasFieldIndex].init[""]);
									EV val;
									fv.valueReader(makeSink!EV(&val));
									s.tupleof[extrasFieldIndex][name] = val;
								}
								else
								// @IgnoreUnknown: silently drain unknown fields (any value type)
								static if (hasUDA!(IgnoreUnknown, T))
								{
									DrainSink ds;
									fv.valueReader(&ds);
								}
								else
									throw new Exception("Unknown field %s".format(name));
							}
						}
					}

					StructFieldSink sink;
					static if (is(typeof(p) == T*))
						sink.s = *p;
					v.reader(&sink);
					handleValue(sink.s);
				}
				else
					throw new Exception("Can't parse %s from %s".format(T.stringof, "object"));
			}
			else
				static assert(false, "Unhandled protocol type " ~ V.stringof);
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

		void handle(V)(V v)
		{
			foreach (n; rangeTuple!N)
			{
				if (idx == n)
				{
					alias E = typeof(T.expand[n]);
					auto s = makeSink!E(&tup.expand[n]);
					s.handle(v);
					idx++;
					return;
				}
			}
			throw new Exception("Too many elements for tuple of length %d".format(N));
		}
	}

	static auto makeSink(T)(T* p)
	{
		static if (is(typeof(p.isSerializationSink)))
			return p;
		else
		static if (is(T X == Nullable!X))
		{
			// Special sink for Nullable: intercepts Null, delegates rest to inner type
			static struct NullableSink
			{
				T* p;

				void handle(V)(V v)
				{
					static if (isProtocolNull!V)
						*p = T.init;
					else
					{
						// Forward to inner sink for X
						X xv;
						auto inner = makeSink!X(&xv);
						inner.handle(v);
						*p = T(xv);
					}
				}
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
					void handle(V)(V v) {}
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
				// N >= 2: serialized as array, use TupleSink via handle in SinkHandlers
				static struct MultiTupleSink
				{
					T* p;

					void handleValue(ref T v) { *p = v; }

					void handle(V)(V v)
					{
						static if (isProtocolArray!V)
						{
							TupleSink!T sink;
							v.reader(&sink);
							*p = sink.tup;
						}
						else
							throw new Exception("Can't parse %s from %s".format(T.stringof, V.stringof));
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
				void handleValue(ref T v) { *p = v; }
				void handle(V)(V v)
				{
					static if (isProtocolNull!V)
						*p = null;
				}
			}
			return NullTypeSink(p);
		}
		else
		static if (is(T U : U*))
		{
			// Pointer sink: Null -> leave null, others -> allocate and deserialize
			static struct PointerSink
			{
				T* p;

				void handleValue(ref U v)
				{
					*p = new U;
					**p = v;
				}

				void handle(V)(V v)
				{
					static if (isProtocolNull!V)
						*p = null;
					else
					{
						U uv;
						auto inner = makeSink!U(&uv);
						inner.handle(v);
						*p = new U;
						**p = uv;
					}
				}
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
