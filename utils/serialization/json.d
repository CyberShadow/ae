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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.serialization.json;

import std.conv;
import std.exception;
import std.format;
import std.string : format;
import std.traits;
import std.utf;

import ae.utils.meta;
import ae.utils.text;

import ae.utils.serialization.serialization;

/// Serialization source which parses a JSON stream.
struct JsonParser(C)
{
	// TODO: some abstract input stream?
	struct Data
	{
		C[] s;
		size_t p;
	}

	static template Impl(alias data)
	{
		alias Char = C;

		C next()
		{
			enforce(data.p < data.s.length);
			return data.s[data.p++];
		}

		void skip()
		{
			data.p++;
		}

		C[] readN(size_t n)
		{
			auto end = data.p + n;
			enforce(end <= data.s.length);
			C[] result = data.s[data.p .. end];
			data.p = end;
			return result;
		}

		C peek()
		{
			enforce(data.p < data.s.length);
			return data.s[data.p];
		}

		size_t mark()
		{
			return data.p;
		}

		C[] slice(size_t a, size_t b)
		{
			return data.s[a..b];
		}

		@property bool eof() { return data.p == data.s.length; }

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
					sink.handleStringFragments(unboundFunctorOf!readString);
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
					sink.handleObject(unboundFunctorOf!readObject);
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
				sink.handleField(unboundFunctorOf!read, unboundFunctorOf!readObjectValue);

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
}

struct JsonDeserializer(C)
{
	JsonParser!C.Data jsonData;
	alias JsonParser!C.Impl!jsonData jsonImpl;
	void[0] anchor;
	alias Deserializer!jsonImpl.Impl!anchor deserializer;

	this(C[] s)
	{
		jsonData.s = s;
	}

	T deserialize(T)()
	{
		T t;
		auto sink = deserializer.makeSink(&t);
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

unittest
{
	static string jsonToJson(string s)
	{
		static struct Test
		{
			alias C = char; // TODO
			import ae.utils.textout;

			JsonParser!C.Data jsonData;
			alias JsonParser!C.Impl!jsonData jsonImpl;
			void[0] anchor;

			StringBuilder sb;
			alias JsonWriter.Impl!(jsonImpl, sb) writer;

			string run(string s)
			{
				jsonData.s = s.dup;
				auto sink = writer.makeSink();
				jsonImpl.read(sink);
				return sb.get();
			}
		}

		Test test;
		return test.run(s);
	}

	static T objToObj(T)(T v)
	{
		static struct Test
		{
			void[0] anchor;
			alias Serializer.Impl!anchor serializer;
			alias Deserializer!serializer.Impl!anchor deserializer;

			T run(T v)
			{
				T r;
				auto sink = deserializer.makeSink(&r);
				serializer.read(sink, v);
				return r;
			}
		}

		Test test;
		return test.run(v);
	}

	static void check(I, O)(I input, O output, O correct, string inputDescription, string outputDescription)
	{
		assert(output == correct, "%s => %s:\nValue:    %s\nResult:   %s\nExpected: %s".format(inputDescription, outputDescription, input, output, correct));
	}

	static void testSerialize(T, S)(T v, S s) { check(v, toJson   !S(v), s, T.stringof, "JSON"); }
	static void testParse    (T, S)(T v, S s) { check(s, jsonParse!T(s), v, "JSON", T.stringof); }
	static void testJson     (T, S)(T v, S s) { check(s, jsonToJson (s), s, "JSON", "JSON"); }
	static void testObj      (T, S)(T v, S s) { check(v, objToObj   (v), v, T.stringof, T.stringof); }

	static void testAll(T, S)(T v, S s)
	{
		testSerialize(v, s);
		testParse    (v, s);
		testJson     (v, s);
		testObj      (v, s);
	}

	testAll  (`Hello "world"`   , `"Hello \"world\""` );
	testAll  (["Hello", "world"], `["Hello","world"]` );
	testAll  ([true, false]     , `[true,false]`      );
	testAll  ([4, 2]            , `[4,2]`             );
	testAll  (["a":1, "b":2]    , `{"a":1,"b":2}`     );
	struct S { int i; string s; }
	testAll  (S(42, "foo")      , `{"i":42,"s":"foo"}`);
//	testAll  (`"test"`w         , "test"w             );
	testParse(S(0, null)        , `{"s":null}`        );

	testAll  (4                 , `4`                 );
	testAll  (4.5               , `4.5`               );

	testAll  ((int[]).init      ,  `null`             );

//	assert(toJson(tuple()) == ``);
//	assert(toJson(tuple(42)) == `42`);
//	assert(toJson(tuple(42, "banana")) == `[42,"banana"]`);
}
