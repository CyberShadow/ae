/**
 * JSON encoding.
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

module ae.utils.sd.json;

import std.conv;
import std.exception;
import std.format;
import std.string : format;
import std.traits;
import std.utf;

import ae.utils.meta;
import ae.utils.text;

import ae.utils.sd.sd;

/// Serialization source which parses a JSON stream.
struct JsonParser(C)
{
	alias Char = C;

	C[] s;
	size_t p;

	C next()
	{
		enforce(p < s.length);
		return s[p++];
	}

	void skip()
	{
		p++;
	}

	C[] readN(size_t n)
	{
		auto end = p + n;
		enforce(end <= s.length);
		C[] result = s[p .. end];
		p = end;
		return result;
	}

	C peek()
	{
		enforce(p < s.length);
		return s[p];
	}

	size_t mark()
	{
		return p;
	}

	C[] slice(size_t a, size_t b)
	{
		return s[a..b];
	}

	@property bool eof() { return p == s.length; }

	// *******************************************************************

	static bool isWhite(C c)
	{
		return c == ' ' || c == '\t';
	}

	void skipWhitespace()
	{
		while (isWhite(peek()))
			skip();
	}

	void expect(C c)
	{
		auto n = next();
		enforce(n==c, "Expected %s, got %s".format(c, n));
	}

	// *******************************************************************

	void read(Sink)(Sink sink)
	{
		skipWhitespace();
		switch (peek())
		{
			case '[':
				skip();
				sink.handleArray(boundFunctorOf!readArray);
				break;
			case '"':
				skip();
				sink.handleStringFragments(boundFunctorOf!readString);
				break;
			case 't':
				skip();
				expect('r');
				expect('u');
				expect('e');
				sink.handleBoolean(true);
				break;
			case 'f':
				skip();
				expect('a');
				expect('l');
				expect('s');
				expect('e');
				sink.handleBoolean(false);
				break;
			case 'n':
				skip();
				expect('u');
				expect('l');
				expect('l');
				sink.handleNull();
				break;
			case '-':
			case '0':
				..
			case '9':
				sink.handleNumeric(readNumeric());
				break;
			case '{':
				skip();
				sink.handleObject(boundFunctorOf!readObject);
				break;
			default:
				throw new Exception("Unknown JSON symbol: %s".format(peek()));
		}
	}

	void readArray(Sink)(Sink sink)
	{
		if (peek()==']')
		{
			skip();
			return;
		}
		while (true)
		{
			read(sink);
			skipWhitespace();
			if (peek()==']')
			{
				skip();
				return;
			}
			else
				expect(',');
		}
	}

	void readObject(Sink)(Sink sink)
	{
		skipWhitespace();
		if (peek()=='}')
		{
			skip();
			return;
		}

		while (true)
		{
			sink.handleField(boundFunctorOf!read, boundFunctorOf!readObjectValue);

			skipWhitespace();
			if (peek()=='}')
			{
				skip();
				return;
			}
			else
				expect(',');
		}
	}

	void readObjectValue(Sink)(Sink sink)
	{
		skipWhitespace();
		expect(':');
		read(sink);
	}

	/// This will call sink.handleStringFragment multiple times.
	void readString(Sink)(Sink sink)
	{
		auto start = mark();

		void flush()
		{
			auto end = mark();
			if (start != end)
				sink.handleStringFragment(slice(start, end));
		}

		void oneConst(C c)()
		{
			static C[1] arr = [c];
			sink.handleStringFragment(arr[]);
		}

		while (true)
		{
			C c = peek();
			if (c=='"')
			{
				flush();
				skip();
				return;
			}
			else
			if (c=='\\')
			{
				flush();
				skip();
				switch (next())
				{
					case '"':  oneConst!('"'); break;
					case '/':  oneConst!('/'); break;
					case '\\': oneConst!('\\'); break;
					case 'b':  oneConst!('\b'); break;
					case 'f':  oneConst!('\f'); break;
					case 'n':  oneConst!('\n'); break;
					case 'r':  oneConst!('\r'); break;
					case 't':  oneConst!('\t'); break;
					case 'u':
					{
						auto w = cast(wchar)fromHex!ushort(readN(4));
						static if (C.sizeof == 1)
						{
							char[4] buf;
							sink.handleStringFragment(buf[0..encode(buf, w)]);
						}
						else
						{
							Unqual!C[1] buf;
							buf[0] = w;
							sink.handleStringFragment(buf[]);
						}
						break;
					}
					default: enforce(false, "Unknown escape");
				}
				start = mark();
			}
			else
				skip();
		}
	}

	C[] readNumeric()
	{
		auto p = mark();

		static immutable bool[256] numeric =
		[
			'0':true,
			'1':true,
			'2':true,
			'3':true,
			'4':true,
			'5':true,
			'6':true,
			'7':true,
			'8':true,
			'9':true,
			'.':true,
			'-':true,
			'+':true,
			'e':true,
			'E':true,
		];

		while (!eof() && numeric[peek()])
			skip();
		return slice(p, mark());
	}
}

// /// Encapsulates a reference to some field of a type.
// struct FieldRef(
// 	/// The type holding the field
// 	T,
// 	/// Field resolver - should return a pointer to the field given a T*
// 	alias resolve,
// )
// {
// 	T* _FieldRef_ptr;
// 	ref T _FieldRef_ref() { return *resolve(_FieldRef_ptr); }
// 	alias _FieldRef_ref this;
// }

struct JsonDeserializer(C)
{
	JsonParser!C.Data jsonData;
	alias DataRef = FieldRef!(typeof(jsonData), p => p);
	void[0] anchor;
	alias Deserializer!anchor deserializer;

	this(C[] s)
	{
		jsonData.s = s;
	}

	T deserialize(T)()
	{
		T t;
		auto sink = deserializer.makeSink(&t);
		alias JsonImpl = JsonParser!C.Impl!DataRef;
		auto jsonImpl = JsonImpl(DataRef(&jsonData));
		jsonImpl.read(sink);
		return t;
	}
}

/// Parse JSON from a string and deserialize it into the given type.
T jsonParse(T, C)(C[] s)
{
	auto parser = JsonDeserializer!C(s);
//	mixin(exceptionContext(q{format("Error at position %d", parser.p)}));
	return parser.deserialize!T();
}

// ***************************************************************************

struct Escapes
{
	string[256] chars;
	bool[256] escaped;

	void populate()
	{
		import std.string;

		escaped[] = true;
		foreach (c; 0..256)
			if (c=='\\')
				chars[c] = `\\`;
			else
			if (c=='\"')
				chars[c] = `\"`;
			else
			if (c=='\b')
				chars[c] = `\b`;
			else
			if (c=='\f')
				chars[c] = `\f`;
			else
			if (c=='\n')
				chars[c] = `\n`;
			else
			if (c=='\r')
				chars[c] = `\r`;
			else
			if (c=='\t')
				chars[c] = `\t`;
			else
			if (c<'\x20' || c == '\x7F' || c=='<' || c=='>' || c=='&')
				chars[c] = format(`\u%04x`, c);
			else
				chars[c] = [cast(char)c],
				escaped[c] = false;
	}
}
immutable Escapes escapes = { Escapes escapes; escapes.populate(); return escapes; }();

/// Serialization target which writes a JSON stream.
struct JsonWriter
{
	static template Impl(alias source, alias output)
	{
		alias Parent = RefType!(thisOf!source);

		static template Sink(alias output)
		{
			void handleNumeric(C)(C[] str)
			{
				output.put(str);
			}

			void handleString(C)(C[] str)
			{
				output.put('"');
				handleStringFragment(str);
				output.put('"');
			}

			void handleNull()
			{
				output.put("null");
			}

			void handleBoolean(bool v)
			{
				output.put(v ? "true" : "false");
			}

			void handleStringFragment(C)(C[] s)
			{
				auto start = s.ptr, p = start, end = start+s.length;

				while (p < end)
				{
					auto c = *p++;
					if (escapes.escaped[c])
						output.put(start[0..p-start-1], escapes.chars[c]),
						start = p;
				}

				output.put(start[0..p-start]);
			}

			void handleArray(Reader)(Reader reader)
			{
				needComma = false;
				output.put('[');
				reader(scopeProxy!arraySink);
				output.put(']');
			}

			void handleStringFragments(Reader)(Reader reader)
			{
				output.put('"');
				reader(scopeProxy!sink);
				output.put('"');
			}

			void handleObject(Reader)(Reader reader)
			{
				needComma = false;
				output.put('{');
				reader(scopeProxy!objectSink);
				output.put('}');
			}
		}
		alias sink = Sink!output;

		static bool needComma; // Yes, a global

		static template ArraySink(alias output)
		{
			alias handleObject = opDispatch!"handleObject";
			alias handleStringFragments = opDispatch!"handleStringFragments";
			alias handleStringFragment = opDispatch!"handleStringFragment";
			alias handleBoolean = opDispatch!"handleBoolean";
			alias handleNull = opDispatch!"handleNull";
			alias handleNumeric = opDispatch!"handleNumeric";
			alias handleString = opDispatch!"handleString";
			alias handleArray = opDispatch!"handleArray";

			template opDispatch(string name)
			{
				void opDispatch(Args...)(auto ref Args args)
				{
					if (needComma)
					{
						output.put(',');
						needComma = false;
					}

					mixin("Sink!output." ~ name ~ "(args);");
					needComma = true;
				}
			}
		}
		alias arraySink = ArraySink!output;

		static template ObjectSink(alias output)
		{
			void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
			{
				if (needComma)
				{
					output.put(',');
					needComma = false;
				}

				nameReader (scopeProxy!sink);
				output.put(':');
				valueReader(scopeProxy!sink);

				needComma = true;
			}
		}
		alias objectSink = ObjectSink!output;

		auto makeSink()
		{
			auto s = scopeProxy!sink;
			return s;
		}
	}
}

struct JsonSerializer(C)
{
	static assert(is(C == char), "TODO");
	import ae.utils.textout;

	void[0] anchor;
	alias Serializer.Impl!anchor serializer;

	StringBuilder sb;
	alias JsonWriter.Impl!(serializer, sb) writer;

	void serialize(T)(auto ref T v)
	{
		auto sink = writer.makeSink();
		serializer.read(sink, v);
	}
}

S toJson(S = string, T)(auto ref T v)
{
	JsonSerializer!(Unqual!(typeof(S.init[0]))) s;
	s.serialize(v);
	return s.sb.get();
}

// ***************************************************************************

