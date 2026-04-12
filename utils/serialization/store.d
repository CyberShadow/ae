/**
 * Intermediary, abstract format for serialization.
 *
 * `SerializedObject` is a discriminated union that acts as both a
 * serialization sink and source. It can capture any structured data
 * tree (from a JSON parser, a D struct serializer, etc.) and replay
 * it into any other sink.
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

module ae.utils.serialization.store;

import std.conv;
import std.exception;
import std.format;
import std.traits;

// -----------------------------------------------------------------------
// Reader helpers for the source interface (module-level to avoid
// nested-struct context pointer issues with DMD templates)
// -----------------------------------------------------------------------

private struct SOArrayReader(SO)
{
	SO* self;

	void opCall(Sink)(Sink sink)
	{
		foreach (ref el; self._array)
			el.read(sink);
	}
}

private struct SOObjectReader(SO)
{
	SO* self;

	void opCall(Sink)(Sink sink)
	{
		foreach (name, ref value; self._object)
		{
			SOStringReader!(SO.S) nr = {s: name};
			SOValueReader!SO vr = {p: &value};
			sink.handleField(nr, vr);
		}
	}
}

private struct SOStringReader(S)
{
	S s;
	void opCall(Sink)(Sink sink)
	{
		sink.handleString(s);
	}
}

private struct SOValueReader(SO)
{
	SO* p;
	void opCall(Sink)(Sink sink)
	{
		p.read(sink);
	}
}

/// A discriminated union type which can be used as both a serialization
/// sink and source. Similar to `std.json.JSONValue`.
///
/// Uses separate fields rather than a D `union` because the GC cannot
/// reliably scan union members that hold pointers (string, arrays, AAs).
struct SerializedObject(C = immutable(char))
{
	alias S = C[];

	enum Type
	{
		none,
		null_,
		boolean,
		numeric,
		string_,
		array,
		object,
	}

	Type type;

	// Separate fields (not a union) -- the GC must be able to see
	// all pointer-bearing fields so it can trace them properly.
	private bool _boolean;
	private S _numeric;
	private S _string;
	package SerializedObject[] _array;
	package SerializedObject[S] _object;

	// ===== Convenience constructors / assignment =====

	this(T)(T v)
		if (is(typeof(this = v)))
	{
		this = v;
	}

	void opAssign(T)(T v)
		if (isNumeric!T)
	{
		import ae.utils.text : numberToString;
		type = Type.numeric;
		_numeric = numberToString(v).to!S;
	}

	void opAssign(T)(T v)
		if (isSomeString!T)
	{
		type = Type.string_;
		_string = v.to!S;
	}

	void opAssign(typeof(null) _)
	{
		type = Type.null_;
	}

	void opAssign(T)(T v)
		if (is(T == bool))
	{
		type = Type.boolean;
		_boolean = v;
	}

	void opAssign(T)(T v)
		if (is(T U : U[]) && !isSomeString!T)
	{
		type = Type.array;
		import std.range, std.array;
		_array = v.map!(e => SerializedObject!C(e)).array;
	}

	void opAssign(T)(T aa)
		if (is(T K : V[K], V) && isSomeString!K)
	{
		type = Type.object;
		_object = null;
		foreach (k, ref v; aa)
			_object[k.to!S] = SerializedObject!C(v);
	}

	ref SerializedObject opIndex(size_t i)
	{
		enforce(type == Type.array, format("SerializedObject is %s, not array", type));
		enforce(i < _array.length, format("SerializedObject array index %d out of bounds (0..%d)", i, _array.length));
		return _array[i];
	}

	ref SerializedObject opIndex(S s)
	{
		enforce(type == Type.object, format("SerializedObject is %s, not object", type));
		return _object[s];
	}

	/// Remove a key from an object. Returns true if the key was present.
	bool remove(S key)
	{
		enforce(type == Type.object, format("SerializedObject is %s, not object", type));
		return _object.remove(key);
	}

	/// Check if an object contains a key.
	bool opBinaryRight(string op : "in")(S key) const
	{
		enforce(type == Type.object, format("SerializedObject is %s, not object", type));
		return (key in _object) !is null;
	}

	/// True when this object contains a value (type is not `none`).
	bool opCast(T : bool)() const { return type != Type.none; }

	/// Number of elements in an array, or entries in an object.
	@property size_t length() const
	{
		if (type == Type.array) return _array.length;
		if (type == Type.object) return _object.length;
		assert(false, format("SerializedObject is %s, not array or object", type));
	}

	void opAssign(SerializedObject[] v)
	{
		type = Type.array;
		_array = v;
	}

	/// Serialize a D value into a SerializedObject.
	static SerializedObject from(T)(auto ref T value)
	{
		import ae.utils.serialization.serialization : Serializer;
		SerializedObject result;
		Serializer.Impl!Object.read(&result, value);
		return result;
	}

	/// Deserialize this object into a D value.
	T deserializeTo(T)()
	{
		import ae.utils.serialization.serialization : deserializer;
		T result;
		this.read(deserializer(&result));
		return result;
	}

	// ===== Sink interface =====

	enum isSerializationSink = true;
	enum isSerializationSource = true;

	void handleNumeric(CC)(CC[] s)
	{
		assert(type == Type.none);
		type = Type.numeric;
		_numeric = s.to!S;
	}

	void handleString(CC)(CC[] s)
	{
		assert(type == Type.none);
		type = Type.string_;
		_string = s.to!S;
	}

	void handleNull()
	{
		assert(type == Type.none);
		type = Type.null_;
	}

	void handleBoolean(bool value)
	{
		assert(type == Type.none);
		type = Type.boolean;
		_boolean = value;
	}

	void handleArray(Reader)(Reader reader)
	{
		static struct ArraySink
		{
			SerializedObject[]* arr;

			alias handleObject = opDispatch!"handleObject";

			template opDispatch(string name)
			{
				void opDispatch(Args...)(auto ref Args args)
				{
					SerializedObject obj;
					mixin("obj." ~ name ~ "(args);");
					*arr ~= obj;
				}
			}
		}

		assert(type == Type.none);
		type = Type.array;
		reader(ArraySink(&_array));
	}

	void handleObject(Reader)(Reader reader)
	{
		static struct ObjectSink
		{
			SerializedObject[S]* aa;

			void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
			{
				static struct StringSink
				{
					S s;

					void handleString(CC)(CC[] s)
					{
						this.s = s.to!S;
					}

					void handleStringFragments(Reader2)(Reader2 reader)
					{
						reader(&this);
					}

					void handleStringFragment(CC)(CC[] fragment)
					{
						s ~= fragment.to!S;
					}

					void bad() { throw new Exception("String expected"); }

					void handleNumeric(CC)(CC[] s) { bad(); }
					void handleNull() { bad(); }
					void handleBoolean(bool value) { bad(); }
					void handleArray(Reader2)(Reader2 reader) { bad(); }
					void handleObject(Reader2)(Reader2 reader) { bad(); }
				}

				StringSink nameSink;
				nameReader(&nameSink);
				SerializedObject value;
				valueReader(&value);
				(*aa)[nameSink.s] = value;
			}
		}

		assert(type == Type.none);
		type = Type.object;
		reader(ObjectSink(&_object));
	}

	// ===== Source interface =====

	void read(Sink)(Sink sink)
	{
		readImpl(&this, sink);
	}

	static void readImpl(Sink)(SerializedObject* self, Sink sink)
	{
		final switch (self.type)
		{
			case Type.none:
				assert(false, "Uninitialized SerializedObject");
			case Type.numeric:
				sink.handleNumeric(self._numeric);
				break;
			case Type.string_:
				sink.handleString(self._string);
				break;
			case Type.null_:
				sink.handleNull();
				break;
			case Type.boolean:
				sink.handleBoolean(self._boolean);
				break;
			case Type.array:
				SOArrayReader!(SerializedObject) ar = {self: self};
				sink.handleArray(ar);
				break;
			case Type.object:
				SOObjectReader!(SerializedObject) or_ = {self: self};
				sink.handleObject(or_);
				break;
		}
	}
}

// ==========================================================================
// Unit tests
// ==========================================================================

debug(ae_unittest):

unittest
{
	SerializedObject!(immutable(char)) s1, s2;
	s1 = "aoeu";
	s1.read(&s2);
	assert(s2.type == s2.Type.string_);
	assert(s2._string == "aoeu");
}

unittest
{
	alias SO = SerializedObject!(immutable(char));

	{
		SO s;
		s = null;
		assert(s.type == SO.Type.null_);
		SO s2;
		s.read(&s2);
		assert(s2.type == SO.Type.null_);
	}
	{
		SO s;
		s = true;
		assert(s.type == SO.Type.boolean);
		SO s2;
		s.read(&s2);
		assert(s2.type == SO.Type.boolean);
		assert(s2._boolean == true);
	}
	{
		SO s;
		s = 42;
		assert(s.type == SO.Type.numeric);
		SO s2;
		s.read(&s2);
		assert(s2.type == SO.Type.numeric);
		assert(s2._numeric == "42");
	}
}

// Full round-trip: D struct -> Serializer -> SerializedObject -> Deserializer -> D struct
unittest
{
	import ae.utils.serialization.serialization;

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
	}

	Outer original;
	original.a = 42;
	original.name = "hello";
	original.inner.x = 7;
	original.inner.s = "world";

	alias SO = SerializedObject!(immutable(char));
	SO store;
	Serializer.Impl!Object.read(&store, original);
	assert(store.type == SO.Type.object);

	Outer result;
	auto sink = deserializer(&result);
	store.read(sink);

	assert(result.a == 42);
	assert(result.name == "hello");
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
}

unittest
{
	import ae.utils.serialization.serialization;

	static struct S { int[] arr; }

	S original;
	original.arr = [1, 2, 3];

	alias SO = SerializedObject!(immutable(char));
	SO store;
	Serializer.Impl!Object.read(&store, original);

	S result;
	auto sink = deserializer(&result);
	store.read(sink);

	assert(result.arr == [1, 2, 3]);
}

unittest
{
	import ae.utils.serialization.serialization;

	static struct S { string[string] map; }

	S original;
	original.map = ["key1": "val1", "key2": "val2"];

	alias SO = SerializedObject!(immutable(char));
	SO store;
	Serializer.Impl!Object.read(&store, original);

	S result;
	auto sink = deserializer(&result);
	store.read(sink);

	assert(result.map == ["key1": "val1", "key2": "val2"]);
}

unittest
{
	import ae.utils.serialization.serialization;

	static struct A { int x; }
	static struct B { A a; string name; }
	static struct C_ { B b; int[] nums; }

	C_ original;
	original.b.a.x = 99;
	original.b.name = "deep";
	original.nums = [10, 20];

	alias SO = SerializedObject!(immutable(char));
	SO store;
	Serializer.Impl!Object.read(&store, original);

	C_ result;
	auto sink = deserializer(&result);
	store.read(sink);

	assert(result.b.a.x == 99);
	assert(result.b.name == "deep");
	assert(result.nums == [10, 20]);
}
