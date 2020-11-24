/**
 * JSON decoding.
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

module ae.utils.sd.json.decoder;

import ae.utils.text : fromHex;

import std.exception : enforce;
import std.format;
import std.utf : encode;

struct JSONDecoder(C)
{
private:
	C[] s;
	size_t p;

	C next()
	{
		enforce(p < s.length, "Unexpected end of JSON data");
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

	// The default reader
	public @property ValueReader reader() { return ValueReader(&this); }
	alias reader this;

	struct ValueReader
	{
		JSONDecoder* json;

		auto read(Handler)(Handler handler)
		{
			json.skipWhitespace();
			switch (json.peek())
			{
				case '[':
					static if (__traits(hasMember, Handler, q{handleArray}))
						return handler.handleArray(ArrayReader(json));
					else
						goto default;
				case '"':
					static if (__traits(hasMember, Handler, q{canHandleTypeHint}) && Handler.canHandleTypeHint!(C[]))
						return handler.handleTypeHint!(C[])(this);
					else
					static if (__traits(hasMember, Handler, q{handleArray}))
						return handler.handleArray(StringReader(json));
					else
						goto default;
				case 't':
					static if (__traits(hasMember, Handler, q{canHandleValue}) && Handler.canHandleValue!bool)
					{
						json.skip();
						json.expect('r');
						json.expect('u');
						json.expect('e');
						return handler.handleValue!bool(true);
					}
					else
						goto default;
				case 'f':
					static if (__traits(hasMember, Handler, q{canHandleValue}) && Handler.canHandleValue!bool)
					{
						json.skip();
						json.expect('a');
						json.expect('l');
						json.expect('s');
						json.expect('e');
						return handler.handleValue!bool(false);
					}
					else
						goto default;
				case 'n':
					static if (__traits(hasMember, Handler, q{canHandleValue}) && Handler.canHandleValue!(typeof(null)))
					{
						json.skip();
						json.expect('u');
						json.expect('l');
						json.expect('l');
						return handler.handleValue!(typeof(null))(null);
					}
					else
						goto default;
				case '-':
				case '0':
					..
				case '9':
					static if (__traits(hasMember, Handler, q{handleNumeric}))
						return handler.handleNumeric(NumericReader(json));
					else
						goto default;
				case '{':
					static if (__traits(hasMember, Handler, q{handleMap}))
						return handler.handleMap(ObjectReader(json));
					else
						goto default;
				default:
					throw new Exception("Unexpected JSON character: %s".format(json.peek()));
			}
		}
	}

	struct ArrayReader
	{
		JSONDecoder* json;

		auto read(Handler)(Handler handler)
		{
			json.skip(); // '['
			if (json.peek() == ']')
			{
				json.skip();
				return handler.handleEnd();
			}
			while (true)
			{
				handler.handleElement(ValueReader(json));
				json.skipWhitespace();
				if (json.peek()==']')
				{
					json.skip();
					return handler.handleEnd();
				}
				else
					json.expect(',');
			}
		}

	}

	struct ObjectReader
	{
		JSONDecoder* json;

		void read(Handler)(Handler handler)
		{
			json.skip(); // '{'
			json.skipWhitespace();
			if (json.peek()=='}')
			{
				json.skip();
				return handler.handleEnd();
			}

			while (true)
			{
				handler.handlePair(ObjectPairReader(json));

				json.skipWhitespace();
				if (json.peek()=='}')
				{
					json.skip();
					return handler.handleEnd();
				}
				else
					json.expect(',');
			}
		}
	}

	struct ObjectPairReader
	{
		JSONDecoder* json;

		auto read(Handler)(Handler handler)
		{
			handler.handlePairKey(ValueReader(json));
			json.skipWhitespace();
			json.expect(':');
			handler.handlePairValue(ValueReader(json));
			return handler.handleEnd();
		}
	}

	struct VarReader(V)
	{
		V v;

		auto read(Handler)(Handler handler)
		{
			static assert(__traits(hasMember, Handler, q{canHandleValue}),
				Handler.stringof ~ " can't accept values");
			static assert(Handler.canHandleValue!V,
				Handler.stringof ~ " can't accept values of type " ~ V.stringof);
			return handler.handleValue!V(v);
		}
	}

	struct StringReader
	{
		JSONDecoder* json;

		void read(Handler)(Handler handler)
		{
			json.skip(); // '"'

			auto start = json.mark();

			void sendSlice(K)(K[] slice)
			{
				static if (__traits(hasMember, Handler, q{canHandleSlice}) && Handler.canHandleSlice!(K[]))
					handler.handleSlice(slice);
				else
					foreach (c; slice)
						handler.handleElement(VarReader!K(c));
			}

			void flush()
			{
				auto end = json.mark();
				if (start != end)
					sendSlice(json.slice(start, end));
			}

			void oneConst(C c)()
			{
				static C[1] arr = [c];
				sendSlice(arr[]);
			}

			while (true)
			{
				C c = json.peek();
				if (c=='"')
				{
					flush();
					json.skip();
					return;
				}
				else
				if (c=='\\')
				{
					flush();
					json.skip();
					switch (json.next())
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
							auto w = cast(wchar)fromHex!ushort(json.readN(4));
							static if (C.sizeof == 1)
							{
								char[4] buf;
								sendSlice(buf[0 .. encode(buf, w)]);
							}
							else
							{
								Unqual!C[1] buf;
								buf[0] = w;
								sendSlice(buf[]);
							}
							break;
						}
						default: enforce(false, "Unknown escape");
					}
					start = json.mark();
				}
				else
					json.skip();
			}
		}
	}

	struct NumericReader
	{
		JSONDecoder* json;

		auto read(Handler)(Handler handler)
		{
			auto p = json.mark();

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

			while (!json.eof() && numeric[json.peek()]) // TODO wchar/dchar OOB
				json.skip();
			handler.handleSlice!C(json.slice(p, json.mark()));
			return handler.handleEnd();
		}
	}
}

auto decodeJSON(C)(C[] s)
{
	return JSONDecoder!C(s);
}

unittest
{
	import ae.utils.sd.serialization.deserializer : deserializeInto;

	{
		struct S { string str; int i; }
		S s;
		`{"str":"Hello","i":42}`
			.decodeJSON()
			.deserializeInto(s);
		assert(s.str == "Hello");
		assert(s.i == 42);
	}

	{
		string s;
		`"Hello\nworld"`
			.decodeJSON()
			.deserializeInto(s);
		assert(s == "Hello\nworld");
	}
}
