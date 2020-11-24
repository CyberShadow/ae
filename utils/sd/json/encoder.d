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
/// `Output` should be a cheaply copyable reference to an output sink.
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

unittest
{
	// static string jsonToJson(string s)
	// {
	// 	static struct Test
	// 	{
	// 		alias C = char; // TODO
	// 		import ae.utils.textout;

	// 		JsonParser!C.Data jsonData;
	// 		alias JsonParser!C.Impl!jsonData jsonImpl;
	// 		void[0] anchor;

	// 		StringBuilder sb;
	// 		alias JsonWriter.Impl!(jsonImpl, sb) writer;

	// 		string run(string s)
	// 		{
	// 			jsonData.s = s.dup;
	// 			auto sink = writer.makeSink();
	// 			jsonImpl.read(sink);
	// 			return sb.get();
	// 		}
	// 	}

	// 	Test test;
	// 	return test.run(s);
	// }

	// static T objToObj(T)(T v)
	// {
	// 	static struct Test
	// 	{
	// 		void[0] anchor;
	// 		alias Serializer.Impl!anchor serializer;
	// 		alias Deserializer!anchor deserializer;

	// 		T run(T v)
	// 		{
	// 			T r;
	// 			auto sink = deserializer.makeSink(&r);
	// 			serializer.read(sink, v);
	// 			return r;
	// 		}
	// 	}

	// 	Test test;
	// 	return test.run(v);
	// }

	static void check(I, O)(I input, O output, O correct, string inputDescription, string outputDescription)
	{
		import std.format : format;
		assert(output == correct,
			("%s => %s:\n" ~
			"Value:    %s\n" ~
			"Result:   %s\n" ~
			"Expected: %s")
			.format(
				inputDescription,
				outputDescription,
				input,
				output,
				correct,
			)
		);
	}

	import ae.utils.sd.json.decoder : decodeJSON;
	import ae.utils.sd.serialization.serializer : serialize;
	import ae.utils.sd.serialization.deserializer : deserializeNew;

	static void testJson     (T, S)(T v, S s) { check(s, s.decodeJSON.toJSON!S()        , s, "JSON"    , "JSON"    ); }
	static void testParse    (T, S)(T v, S s) { check(s, s.decodeJSON.deserializeNew!T(), v, "JSON"    , T.stringof); }
	static void testSerialize(T, S)(T v, S s) { check(v, v.serialize .toJSON!S()        , s, T.stringof, "JSON"    ); }
	static void testObj      (T, S)(T v, S s) { check(v, v.serialize .deserializeNew!T(), v, T.stringof, T.stringof); }

	static void testAll(T, S)(T v, S s)
	{
		testJson     (v, s);
		testParse    (v, s);
		testSerialize(v, s);
		testObj      (v, s);
	}

// 	testAll  (`Hello "world"`   , `"Hello \"world\""` );
	testAll  (["Hello", "world"], `["Hello","world"]` );
// 	testAll  ([true, false]     , `[true,false]`      );
// 	testAll  ([4, 2]            , `[4,2]`             );
// 	testAll  (["a":1, "b":2]    , `{"b":2,"a":1}`     );
// 	struct S { int i; string s; }
// 	testAll  (S(42, "foo")      , `{"i":42,"s":"foo"}`);
// //	testAll  (`"test"`w         , "test"w             );
// 	testParse(S(0, null)        , `{"s":null}`        );

// 	testAll  (4                 , `4`                 );
// 	testAll  (4.5               , `4.5`               );
// 	testAll  (4.1               , `4.1`               );

// 	testAll  ((int[]).init      ,  `null`             );

// 	struct RA { RA[] arr; }
// 	testAll  ((RA[]).init      ,  `null`             );

// 	struct RM { RM[string] aa; }
// 	testAll  ((RM).init        ,  `{"aa":null}`      ); // https://issues.dlang.org/show_bug.cgi?id=21419
// 	testAll  ((RM[]).init      ,  `null`             );
}
