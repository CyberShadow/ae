/**
 * Intermediary, abstract format for sd.
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

module ae.utils.sd.store;

import std.conv;
import std.exception;
import std.string;
import std.traits;

import ae.utils.meta;

/// A discriminated union type which can be used as both a sd sink and source.
/// Similar to std.variant.Variant and std.json.JSONValue.
struct SerializedObject(C)
{
	alias S = C[];

	enum Type
	{
		sNone,
		sNumeric,
		sString,
		sStringFragments,
		sNull,
		sBoolean,
		sArray,
		sObject,
	}

	Type type;

	union
	{
		S sNumeric;
		S sString;
		S[] sStringFragments;
		bool sBoolean;
		SerializedObject[] sArray;
		SerializedObject[S] sObject;
	}

	// ***********************************************************************

	this(T)(T v)
		if (is(typeof(this = v)))
	{
		this = v;
	}

	void opAssign(T)(T v)
		if (is(isNumeric!T))
	{
		type = Type.sNumeric;
		sNumeric = v.numberToString.to!S;
	}

	void opAssign(T)(T v)
		if (isSomeString!T)
	{
		type = Type.sString;
		sString = v.to!S;
	}

	void opAssign(T)(T v)
		if (is(T == typeof(null)))
	{
		assert(v is null);
		type = Type.sNull;
	}

	void opAssign(T)(T v)
		if (is(T == bool))
	{
		type = Type.sBoolean;
		sBoolean = v;
	}

	void opAssign(T)(T v)
		if (is(T U : U[]) && !isSomeString!T)
	{
		type = Type.sArray;
		import std.range, std.array;
		sArray = v.map!(e => SerializedObject!C(e)).array;
	}

	void opAssign(T)(T aa)
		if (is(T K : V[K], V) && isSomeString!K)
	{
		type = Type.sObject;
		sObject = null;
		foreach (k, ref v; aa)
			sObject[k.to!S] = SerializedObject!C(v);
	}

	ref SerializedObject opIndex(size_t i)
	{
		enforce(type == Type.sArray, "SerializedObject is %s, not sArray".format(type));
		enforce(i < sArray.length, "SerializedObject sArray index %d out of bounds (0..%d)".format(i, sArray.length));
		return sArray[i];
	}

	ref SerializedObject opIndex(S s)
	{
		enforce(type == Type.sObject, "SerializedObject is %s, not sObject".format(type));
		return sObject[s];
	}

	// ***********************************************************************

	enum isSerializationSink = true;

	void handleNumeric(CC)(CC[] s)
	{
		assert(type == Type.sNone);
		type = Type.sNumeric;
		sNumeric = s.to!S;
	}

	void handleString(CC)(CC[] s)
	{
		assert(type == Type.sNone);
		type = Type.sString;
		sString = s.to!S;
	}

	void handleStringFragments(Reader)(Reader reader)
	{
		static struct StringFragmentSink
		{
			S[]* arr;

			void handleStringFragment(CC)(CC[] s)
			{
				*arr ~= s.to!S;
			}
		}

		assert(type == Type.sNone);
		type = Type.sStringFragments;
		reader(StringFragmentSink(&sStringFragments));
	}

	void handleNull()
	{
		assert(type == Type.sNone);
		type = Type.sNull;
	}

	void handleBoolean(bool value)
	{
		assert(type == Type.sNone);
		type = Type.sBoolean;
		sBoolean = value;
	}

	void handleArray(Reader)(Reader reader)
	{
		static struct ArraySink
		{
			SerializedObject[]* arr;

			alias handleStringFragments = opDispatch!"handleStringFragments";
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

		assert(type == Type.sNone);
		type = Type.sArray;
		reader(ArraySink(&sArray));
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

					void handleStringFragments(Reader)(Reader reader)
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
					void handleArray(Reader)(Reader reader) { bad(); }
					void handleObject(Reader)(Reader reader) { bad(); }
				}

				StringSink nameSink;
				nameReader(nameSink);
				SerializedObject value;
				valueReader(&value);
				(*aa)[nameSink.s] = value;
			}
		}

		assert(type == Type.sNone);
		type = Type.sObject;
		reader(ObjectSink(&sObject));
	}

	auto traverse(CC, Reader)(in CC[] name, Reader reader)
	{
		if (type == Type.sNone)
		{
			type = Type.sObject;
			sObject = null;
		}
		enforce(type == Type.sObject, "Can't traverse %s".format(type));

		auto pv = name in sObject;
		if (!pv)
		{
			*p[name] = SerializedObject.init;
			pv = name in *p;
		}
		return reader(pv);
	}

	// ***********************************************************************

	void read(Sink)(Sink sink)
	{
		final switch (type)
		{
			case Type.sNone:
				assert(false, "Uninitialized SerializedObject");
			case Type.sNumeric:
				sink.handleNumeric(sNumeric);
				break;
			case Type.sString:
				sink.handleString(sString);
				break;
			case Type.sStringFragments:
				sink.handleStringFragments(boundFunctorOf!readStringFragments(&this));
				break;
			case Type.sNull:
				sink.handleNull();
				break;
			case Type.sBoolean:
				sink.handleBoolean(sBoolean);
				break;
			case Type.sArray:
				sink.handleArray(boundFunctorOf!readArray(&this));
				break;
			case Type.sObject:
				sink.handleObject(boundFunctorOf!readObject(&this));
				break;
		}
	}

	void readStringFragments(Sink)(Sink sink)
	{
		assert(type == Type.sStringFragments);
		foreach (fragment; sStringFragments)
			sink.handleStringFragment(fragment);
	}

	void readArray(Sink)(Sink sink)
	{
		assert(type == Type.sArray);
		foreach (el; sArray)
			el.read(sink);
	}

	struct StringReader
	{
		S s;
		this(S s) { this.s = s; }
		void opCall(Sink)(Sink sink)
		{
			sink.handleString(s);
		}
	}

	void readObject(Sink)(Sink sink)
	{
		assert(type == Type.sObject);
		foreach (name, ref value; sObject)
			sink.handleField(StringReader(name), boundFunctorOf!read(&value));
	}
}

unittest
{
	SerializedObject!(immutable(char)) s1, s2;
	s1 = "aoeu";
	s1.read(&s2);
}

unittest
{
	import ae.utils.sd.json;
	auto s = jsonParse!(SerializedObject!(immutable(char)))(`null`);
	assert(s.type == s.Type.sNull);
}
