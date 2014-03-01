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

import std.exception;
import std.utf;

import ae.utils.meta;
import ae.utils.text;

import ae.utils.serialization.deserializer;

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

		// ***********************************************************************

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
			enforce(n==c, "Expected " ~ c ~ ", got " ~ n);
		}

		// ***********************************************************************

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
					throw new Exception("Unknown JSON symbol: " ~ peek());
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
				char c = peek();
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
								one(w);
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
	assert(jsonParse!S(`{"s" : null}`) == S(0, null));
}
