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
					sink.handleArray!(disconnect!readArray)();
					break;
				case '"':
					skip();
					sink.handleStringFragments!(disconnect!readString)();
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
					sink.handleObject!(disconnect!readObject)();
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
				sink.handleField!(disconnect!read, disconnect!readObjectValue)();

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

// ***************************************************************************

/// Serialization target which writes a JSON stream.
struct JsonWriter(alias output)
{
	static template Impl(alias anchor)
	{
		alias Parent = RefType!(thisOf!anchor);

		static struct Sink
		{
			Parent parent;

			void handleNumeric(C)(C[] str)
			{
				__traits(child, parent, output).put(str);
			}

			void handleObject(alias reader)()
			{
				__traits(child, parent, output).put('{');
				auto sink = ObjectSink(parent);
				__traits(child, parent, reader)(&sink);
				__traits(child, parent, output).put('}');
			}
		}

		static struct ObjectSink
		{
			Parent parent;

			void handleField(alias nameReader, alias valueReader)()
			{
				__traits(child, parent, nameReader)(Sink(this.reference));
				__traits(child, parent, output).put(':');
				__traits(child, parent, valueReader)(Sink(this.reference));
			}
		}

		auto createSink()
		{
			return Sink(this.reference);
		}
	}
}

/// Serialization source which serializes a given object.
struct Serializer(alias writer)
{
	static template Impl(alias anchor)
	{
		void serialize(T)(auto ref T v)
		{
			auto sink = writer.createSink();
			read(sink, v);
		}

		void read(Sink, T)(Sink sink, auto ref T v)
		{
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
				sink.handleObject();
			}
			else
				static assert(false, "Don't know how to serialize " ~ T.stringof);
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

unittest
{
	assert(toJson(4) == "4", toJson(4));
	assert(toJson(4.5) == "4.5");
}

unittest
{
//	struct X { int a; string b; }
//	X x = {17, "aoeu"};
//	assert(toJson(x) == `{"a":17,"b":"aoeu"}`);
//	int[] arr = [1,5,7];
//	assert(toJson(arr) == `[1,5,7]`);

//	assert(toJson(tuple()) == ``);
//	assert(toJson(tuple(42)) == `42`);
//	assert(toJson(tuple(42, "banana")) == `[42,"banana"]`);
}
