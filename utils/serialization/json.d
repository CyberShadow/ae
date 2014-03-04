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
					Sink.handleArray(sink, unboundDgAlias!readArray);
					break;
				case '"':
					skip();
					Sink.handleStringFragments(sink, unboundDgAlias!readString);
					break;
				case 't':
					skip();
					expect('r');
					expect('u');
					expect('e');
					Sink.handleBoolean(sink, true);
					break;
				case 'f':
					skip();
					expect('a');
					expect('l');
					expect('s');
					expect('e');
					Sink.handleBoolean(sink, false);
					break;
				case 'n':
					skip();
					expect('u');
					expect('l');
					expect('l');
					Sink.handleNull(sink);
					break;
				case '-':
				case '0':
					..
				case '9':
					Sink.handleNumeric(sink, readNumeric());
					break;
				case '{':
					skip();
					Sink.handleObject(sink, unboundDgAlias!readObject);
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
				Sink.handleField(sink, unboundDgAlias!read, unboundDgAlias!readObjectValue);

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
		return deserializer.deserialize!T();
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
struct JsonWriter(alias output)
{
	static template Impl(alias anchor)
	{
		alias Parent = RefType!(thisOf!anchor);
		alias Output = ScopeProxy!output;

		static struct Sink
		{
			Output output;

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
				output.put('[');
				auto sink = ArraySink(output);
				Reader.call(reader, &sink);
				output.put(']');
			}

			void handleObject(Reader)(Reader reader)
			{
				output.put('{');
				auto sink = ObjectSink(output);
				Reader.call(reader, &sink);
				output.put('}');
			}
		}

		static struct ArraySink
		{
			Output output;
			bool needComma;

			template opDispatch(string name)
			{
				void opDispatch(Args...)(auto ref Args args)
				{
					if (needComma)
						output.put(',');
					else
						needComma = true;

					mixin("Sink(output)." ~ name ~ "(args);");
				}
			}
		}

		static struct ObjectSink
		{
			Output output;
			bool needComma;

			void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
			{
				if (needComma)
					output.put(',');
				else
					needComma = true;

				NameReader .call(nameReader , Sink(output));
				output.put(':');
				ValueReader.call(valueReader, Sink(output));
			}
		}

		auto createSink()
		{
			return Sink(Output(this.reference));
		}
	}
}

struct JsonSerializer
{
	import ae.utils.textout;

	StringBuilder sb;
	void[0] anchor;
	alias JsonWriter!sb.Impl!anchor writer;
	alias Serializer!writer.Impl!anchor serializer;
}

string toJson(T)(auto ref T v)
{
	JsonSerializer s;
	s.serializer.serialize(v);
	return s.sb.get();
}

// ***************************************************************************

unittest
{
	assert(jsonParse!string(`"Hello \"world\""`) == `Hello "world"`);
	assert(jsonParse!(string[])(`["Hello", "world"]`) == ["Hello", "world"]);
	assert(jsonParse!(bool[])(`[true, false]`) == [true, false]);
	assert(jsonParse!(int[])(`[4, 2]`) == [4, 2]);
	assert(jsonParse!(int[string])(`{"a":1, "b":2}`) == ["a":1, "b":2]);
	struct S { int i; string s; }
	assert(jsonParse!S(`{"s" : "foo", "i":42}`) == S(42, "foo"));
	assert(jsonParse!wstring(`"test"`w) == "test"w);
	assert(jsonParse!S(`{"s" : null}`) == S(0, null));
}

unittest
{
	assert(toJson(4) == "4", toJson(4));
	assert(toJson(4.5) == "4.5");
}

unittest
{
	struct X { int a; string b; }
	X x = {17, "aoeu"};
	assert(toJson(x) == `{"a":17,"b":"aoeu"}`, toJson(x));
	int[] arr = [1,5,7];
	assert(toJson(arr) == `[1,5,7]`);
	int[] arrNull = null;
	assert(toJson(arrNull) == `null`);

//	assert(toJson(tuple()) == ``);
//	assert(toJson(tuple(42)) == `42`);
//	assert(toJson(tuple(42, "banana")) == `[42,"banana"]`);
}
