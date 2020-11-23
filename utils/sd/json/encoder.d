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

module ae.utils.sd.json.encode;

import std.traits;

import ae.utils.appender : putEx;

private struct Escapes
{
	string[256] chars;
	bool[256] escaped;

	void populate()
	{
		import std.format : format;

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
struct JSONEncoder(Output)
{
	Output output;

	enum canPut(C) = is(typeof({ C c = void; output.put(c); }));

	/// Accepts characters and emits them verbatim (array context)
	private static struct VerbatimHandler
	{
		Output output;

		enum canHandleSlice(C) = canPut!(C[]);
		void handleSlice(C)(C[] slice)
		if (canHandleSlice!C)
		{
			output.put(slice);
		}

		struct ElementHandler
		{
			Output output;

			enum bool canHandleValue(C) = canPut!C;
			void handleValue(C)(C value)
			if (canHandleValue!C)
			{
				output.put(value);
			}
		}

		void handleElement(Reader)(Reader reader)
		{
			reader.read(ElementHandler(output));
		}

		void handleEnd() {}
	}

	enum canHandleValue(T) = is(T == bool) || is(T == typeof(null));
	void handleValue(T)(T value)
	if (canHandleValue!T)
	{
		static if (is(T == bool))
			output.put(value ? "true" : "false");
		else
		static if (is(T == typeof(null)))
			output.put("null");
		else
			static assert(false);
	}

	// Type hinting is used to signal strings (arrays of char)

	enum canHandleTypeHint(T) = isSomeString!T;
	void handleTypeHint(T, Reader)(Reader reader)
	if (isSomeString!T)
	{
		static void escapedPut(C)(Output output, C[] s)
		{
			auto start = s.ptr, p = start, end = start+s.length;

			while (p < end)
			{
				auto c = *p++;
				if (c < escapes.escaped.length && escapes.escaped[c])
					output.putEx(start[0..p-start-1], escapes.chars[c]),
					start = p;
			}

			output.put(start[0..p-start]);
		}

		static struct StringContentHandler
		{
			Output output;

			enum canHandleSlice(C) = canPut!(C[]);
			void handleSlice(C)(C[] slice)
			if (canHandleSlice!C)
			{
				escapedPut(output, slice);
			}

			struct ElementHandler
			{
				Output output;

				enum bool canHandleValue(C) = canPut!C;
				void handleValue(C)(C value)
				if (canHandleValue!C)
				{
					escapedPut(output, (&value)[0 .. 1]);
				}
			}

			void handleElement(Reader)(Reader reader)
			{
				reader.read(ElementHandler(output));
			}

			void handleEnd() {}
		}

		static struct StringHandler
		{
			Output output;

			void handleArray(Reader)(Reader reader)
			{
				output.put('"');
				reader.read(StringContentHandler(output));
				output.put('"');
			}
		}

		reader.read(StringHandler(output));
	}

	void handleNumeric(Reader)(Reader reader)
	{
		reader.read(VerbatimHandler(output));
	}

	void handleArray(Reader)(Reader reader)
	{
		static struct PairHandler
		{
			Output output;

			void handlePairKey(Reader)(Reader reader)
			{
				reader.read(JSONEncoder(output));
				output.put(':');
			}

			void handlePairValue(Reader)(Reader reader)
			{
				reader.read(JSONEncoder(output));
			}
		}

		static struct ArrayHandler
		{
			Output output;
			bool first = true;

			void handleElement(Reader)(Reader reader)
			{
				if (first)
					first = false;
				else
					output.put(',');
				reader.read(JSONEncoder(output));
			}

			void handleEnd() {}
		}

		output.put('[');
		reader.read(ArrayHandler(output));
		output.put(']');
	}

	void handleMap(Reader)(Reader reader)
	{
		static struct PairHandler
		{
			Output output;

			void handlePairKey(Reader)(Reader reader)
			{
				reader.read(JSONEncoder(output));
				output.put(':');
			}

			void handlePairValue(Reader)(Reader reader)
			{
				reader.read(JSONEncoder(output));
			}
		}

		static struct MapHandler
		{
			Output output;
			bool first = true;

			void handlePair(Reader)(Reader reader)
			{
				if (first)
					first = false;
				else
					output.put(',');
				reader.read(PairHandler(output));
			}

			void handleEnd() {}
		}

		output.put('{');
		reader.read(MapHandler(output));
		output.put('}');
	}
}

S toJSON(S = string, Source)(Source source)
{
	import std.array : Appender;
	alias Sink = Appender!S;
	Sink sink;
	JSONEncoder!(Sink*) encoder;
	encoder.output = &sink;
	source.read(&encoder);
	return sink.data;
}

unittest
{
	import ae.utils.sd.json.decoder : decodeJSON;

	void test(string s)
	{
		assert(s.decodeJSON().toJSON() == s);
	}

	test(`{"str":"Hello","i":42}`);
	test(`"Hello\nworld"`);
	test(`[true,false,null]`);
}
