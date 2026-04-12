/**
 * JSON encoding.
 *
 * A self-contained JSON serializer/deserializer. For a more general framework
 * supporting multiple formats (JSON, XML, CSV, bencode, etc.), composable
 * filters, and streaming, see `ae.utils.serialization.json` and the
 * `ae.utils.serialization` package.
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

module ae.utils.json;

import std.conv : text, to;
import std.math : isFinite;
import std.traits;
import std.typecons;
import std.utf : encode;

import ae.utils.textout;

// ************************************************************************

/// JSON serialization / deserialization options
struct JsonOptions
{
	/// What to do with associative arrays with non-string keys
	enum NonStringKeys
	{
		/// Fail compilation.
		error,

		/// Serialize keys as-is - results in non-compliant JSON.
		asIs,

		/// Serialize keys as strings.
		/// Note that this may result in multiple levels of quoting.
		stringify,
	}
	NonStringKeys nonStringKeys = NonStringKeys.error; /// ditto
}

// ************************************************************************

/// Basic JSON writer.
struct JsonWriter(Output)
{
	/// You can set this to something to e.g. write to another buffer.
	Output output;

	private void putChars(S...)(S strings)
	{
		static if (is(typeof(output.putEx(strings))))
			output.putEx(strings);
		else
			foreach (str; strings)
				static if (is(typeof(output.put(str))))
					output.put(str);
				else
					foreach (dchar c; str)
					{
						alias C = char; // TODO: get char type of output
						C[4 / C.sizeof] buf = void;
						auto size = encode(buf, c);
						output.put(buf[0..size]);
					}
	}

	/// Write a string literal.
	private void putString(C)(in C[] s)
	{
		// TODO: escape Unicode characters?
		// TODO: Handle U+2028 and U+2029 ( http://timelessrepo.com/json-isnt-a-javascript-subset )

		output.putEx('"');
		auto start = s.ptr, p = start, end = start+s.length;

		while (p < end)
		{
			auto c = *p++;
			if (c < Escapes.escaped.length && Escapes.escaped[c])
			{
				putChars(start[0..p-start-1], Escapes.chars[c]);
				start = p;
			}
		}

		putChars(start[0..p-start], '"');
	}

	/// Write a value of a simple type.
	void putValue(T)(T v)
	{
		static if (is(typeof(v is null)))
			if (v is null)
				return output.put("null");
		static if (is(T == typeof(null)))
			return output.put("null");
		else
		static if (isSomeString!T)
			putString(v);
		else
		static if (isSomeChar!(Unqual!T))
			return putString((&v)[0..1]);
		else
		static if (is(Unqual!T == bool))
			return output.put(v ? "true" : "false");
		else
		static if (is(Unqual!T : long))
			return .put(output, v);
		else
		static if (is(Unqual!T : real))
			if (v.isFinite)
				return output.putFP(v);
			else
				return putString(v.to!string);
		else
			static assert(0, "Don't know how to write " ~ T.stringof);
	}

	void beginArray()
	{
		output.putEx('[');
	} ///

	void endArray()
	{
		output.putEx(']');
	} ///

	void beginObject()
	{
		output.putEx('{');
	} ///

	void endObject()
	{
		output.putEx('}');
	} ///

	void endKey()
	{
		output.putEx(':');
	} ///

	void putComma()
	{
		output.putEx(',');
	} ///
}

/// JSON writer with indentation.
struct PrettyJsonWriter(Output, alias indent = '\t', alias newLine = '\n', alias preColon = ' ', alias postColon = preColon)
{
	JsonWriter!Output jsonWriter; /// Underlying writer.
	alias jsonWriter this;

	private bool indentPending;
	private uint indentLevel;

	private void putIndent()
	{
		if (indentPending)
		{
			foreach (n; 0..indentLevel)
				output.putEx(indent);
			indentPending = false;
		}
	}

	private void putNewline()
	{
		if (!indentPending)
		{
			output.putEx(newLine);
			indentPending = true;
		}
	}

	void putValue(T)(T v)
	{
		putIndent();
		jsonWriter.putValue(v);
	} ///

	void beginArray()
	{
		putIndent();
		jsonWriter.beginArray();
		indentLevel++;
		putNewline();
	} ///

	void endArray()
	{
		indentLevel--;
		putNewline();
		putIndent();
		jsonWriter.endArray();
	} ///

	void beginObject()
	{
		putIndent();
		jsonWriter.beginObject();
		indentLevel++;
		putNewline();
	} ///

	void endObject()
	{
		indentLevel--;
		putNewline();
		putIndent();
		jsonWriter.endObject();
	} ///

	void endKey()
	{
		output.putEx(preColon, ':', postColon);
	} ///

	void putComma()
	{
		jsonWriter.putComma();
		putNewline();
	} ///
}

/// Abstract JSON serializer based on `Writer`.
struct CustomJsonSerializer(Writer, JsonOptions options = JsonOptions.init)
{
	Writer writer; /// Output.

	/// Put a serializable value.
	void put(T)(auto ref T v)
	{
		auto sink = WriterSinkAdapter!(Writer, options)(&writer);
		import ae.utils.serialization.json : NewJsonCustomSerializer = JsonCustomSerializer;
		NewJsonCustomSerializer.Impl!Object.read(&sink, v);
	}
}

/// Adapter that presents the new sink protocol on top of an old-style imperative Writer.
private struct WriterSinkAdapter(Writer, JsonOptions options = JsonOptions.init)
{
	Writer* writer;

	void handleNull()
	{
		writer.putValue(null);
	}

	void handleBoolean(bool v)
	{
		writer.putValue(v);
	}

	void handleNumeric(CC)(CC[] s)
	{
		writer.output.put(s);
	}

	void handleString(S)(S s)
	{
		writer.putValue(s);
	}

	void handleArray(Reader)(Reader reader)
	{
		writer.beginArray();
		ArrayElementSink as = {adapter: &this};
		reader(&as);
		writer.endArray();
	}

	void handleObject(Reader)(Reader reader)
	{
		writer.beginObject();
		ObjectFieldSink os = {adapter: &this};
		reader(&os);
		writer.endObject();
	}

	struct ArrayElementSink
	{
		WriterSinkAdapter* adapter;
		bool first = true;

		private void comma()
		{
			if (!first)
				adapter.writer.putComma();
			first = false;
		}

		void handleNull()             { comma(); adapter.handleNull(); }
		void handleBoolean(bool v)    { comma(); adapter.handleBoolean(v); }
		void handleNumeric(CC)(CC[] s){ comma(); adapter.handleNumeric(s); }
		void handleString(S)(S s)     { comma(); adapter.handleString(s); }
		void handleArray(R)(R reader) { comma(); adapter.handleArray(reader); }
		void handleObject(R)(R reader){ comma(); adapter.handleObject(reader); }
	}

	struct ObjectFieldSink
	{
		WriterSinkAdapter* adapter;
		bool first = true;

		void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
		{
			// Write key
			KeySink ks = {adapter: adapter};
			nameReader(&ks);

			if (!first)
				adapter.writer.putComma();
			first = false;

			// Write the key value that was captured
			static if (options.nonStringKeys == JsonOptions.NonStringKeys.error)
			{
				adapter.writer.putValue(ks.key);
			}
			else static if (options.nonStringKeys == JsonOptions.NonStringKeys.stringify)
			{
				if (ks.key !is null)
					adapter.writer.putValue(ks.key);
				else
					adapter.writer.output.put(ks.numericKey);
			}
			else static if (options.nonStringKeys == JsonOptions.NonStringKeys.asIs)
			{
				if (ks.key !is null)
					adapter.writer.putValue(ks.key);
				else
					adapter.writer.output.put(ks.numericKey);
			}

			adapter.writer.endKey();

			// Write value
			valueReader(adapter);
		}
	}

	struct KeySink
	{
		WriterSinkAdapter* adapter;
		const(char)[] key;
		const(char)[] numericKey;

		void handleString(S)(S s)     { key = s; }
		void handleNumeric(CC)(CC[] s){ numericKey = s; }
		void handleNull()
		{
			static if (options.nonStringKeys == JsonOptions.NonStringKeys.error)
				throw new Exception("Non-string key in JSON object.");
			else
				key = "";
		}
		void handleBoolean(bool v)
		{
			static if (options.nonStringKeys == JsonOptions.NonStringKeys.error)
				throw new Exception("Non-string key in JSON object.");
		}
	}
}

/// JSON serializer with `StringBuilder` output.
alias JsonSerializer = CustomJsonSerializer!(JsonWriter!StringBuilder);

private struct Escapes
{
	static immutable  string[256] chars;
	static immutable bool[256] escaped;

	shared static this()
	{
		import std.string : format;

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

// ************************************************************************

/// Serialize `T` to JSON, and return the result as a string.
string toJson(T)(auto ref T v)
{
	import ae.utils.serialization.json : newToJson = toJson;
	return newToJson(v);
}

/// ditto
string toJson(JsonOptions options, T)(auto ref T v)
{
	static if (is(T V : V[K], K))
		static if (!isSomeString!K)
			static assert(options.nonStringKeys != JsonOptions.NonStringKeys.error,
				"Cannot serialize associative array with non-string key " ~ K.stringof);
	import ae.utils.serialization.json : SerJsonOptions = JsonOptions, newToJson = toJson;
	static immutable int nsk = options.nonStringKeys;
	enum SerJsonOptions serOptions = {
		nonStringKeys: cast(SerJsonOptions.NonStringKeys) nsk,
	};
	return newToJson!serOptions(v);
}

///
debug(ae_unittest) unittest
{
	struct X { int a; string b; }
	X x = {17, "aoeu"};
	assert(toJson(x) == `{"a":17,"b":"aoeu"}`, toJson(x));
	int[] arr = [1,5,7];
	assert(toJson(arr) == `[1,5,7]`);
	assert(toJson(true) == `true`);

	assert(toJson(tuple()) == ``);
	assert(toJson(tuple(42)) == `42`);
	assert(toJson(tuple(42, "banana")) == `[42,"banana"]`);
}

debug(ae_unittest) unittest
{
	struct A
	{
	}

	struct B
	{
		A[] a;
		deprecated alias a this;
		JSONFragment toJSON() const { return JSONFragment(`null`); }
	}

	B b;
	b.toJson();
}

// Test that null string keys in associative arrays are serialized as empty strings.
debug(ae_unittest) unittest
{
	int[string] aa;
	aa[null] = 42;
	auto s = aa.toJson;
	assert(s == `{"":42}`, s);
}

// ************************************************************************

/// Serialize `T` to a pretty (indented) JSON string.
string toPrettyJson(T)(T v)
{
	import ae.utils.serialization.json : newToPrettyJson = toPrettyJson;
	return newToPrettyJson(v);
}

/// ditto
string toPrettyJson(JsonOptions options, T)(T v)
{
	// TODO: options support in pretty printing
	import ae.utils.serialization.json : newToPrettyJson = toPrettyJson;
	return newToPrettyJson(v);
}

///
debug(ae_unittest) unittest
{
	struct X { int a; string b; int[] c, d; }
	X x = {17, "aoeu", [1, 2, 3]};
	assert(toPrettyJson(x) ==
`{
	"a" : 17,
	"b" : "aoeu",
	"c" : [
		1,
		2,
		3
	],
	"d" : [
	]
}`, toPrettyJson(x));
}

// ************************************************************************

/// Parse the JSON in string `s` and deserialize it into an instance of `T`.
template jsonParse(T, JsonOptions options = JsonOptions.init)
{
	T jsonParse(C)(C[] s)
	{
		static if (is(T V : V[K], K))
			static if (!isSomeString!K)
				static assert(options.nonStringKeys != JsonOptions.NonStringKeys.error,
					"Cannot parse associative array with non-string key " ~ K.stringof);
		import ae.utils.serialization.json : SerJsonOptions = JsonOptions, newJsonParse = jsonParse;
		static immutable int nsk = options.nonStringKeys;
		enum SerJsonOptions serOptions = {
			nonStringKeys: cast(SerJsonOptions.NonStringKeys) nsk,
		};
		return newJsonParse!(T, serOptions)(s);
	}
}

debug(ae_unittest) unittest
{
	struct S { int i; S[] arr; S* p0, p1; }
	S s = S(42, [S(1), S(2)], null, new S(15));
	auto s2 = jsonParse!S(toJson(s));
	//assert(s == s2); // Issue 3789
	assert(s.i == s2.i && s.arr == s2.arr && s.p0 is s2.p0 && *s.p1 == *s2.p1);
	jsonParse!S(toJson(s).dup);

	assert(jsonParse!(Tuple!())(``) == tuple());
	assert(jsonParse!(Tuple!int)(`42`) == tuple(42));
	assert(jsonParse!(Tuple!(int, string))(`[42, "banana"]`) == tuple(42, "banana"));

	assert(jsonParse!(string[string])(`null`) is null);
}

debug(ae_unittest) unittest
{
	struct T { string s; wstring w; dstring d; }
	T t;
	auto s = t.toJson;
	assert(s == `{"s":null,"w":null,"d":null}`, s);

	t.s = "foo";
	t.w = "bar"w;
	t.d = "baz"d;
	s = t.toJson;
	assert(s == `{"s":"foo","w":"bar","d":"baz"}`, s);

	jsonParse!T(s);
	jsonParse!T(cast(char[]) s);
	jsonParse!T(cast(const(char)[]) s);
	jsonParse!T(s.to!wstring);
	jsonParse!T(s.to!dstring);
}

debug(ae_unittest) unittest
{
	jsonParse!(int[2])(`[ 1 , 2 ]`);
}

// NaNs and infinities are serialized as strings.
debug(ae_unittest) unittest
{
	void check(double f, string s)
	{
		assert(f.toJson() == s);
		assert(s.jsonParse!double is f);
	}
	check(double.init, `"nan"`);
	check(double.infinity, `"inf"`);
	check(-double.infinity, `"-inf"`);
}

/// Parse the JSON in string `s` and deserialize it into `T`.
void jsonParse(T, C)(C[] s, ref T result)
{
	import ae.utils.serialization.json : JsonParser, jsonCustomDeserializer;
	auto parser = JsonParser!C(s, 0);
	auto sink = jsonCustomDeserializer(&result);
	parser.skipWhitespace();
	if (!parser.eof)
		parser.read(sink);
}

debug(ae_unittest) unittest
{
	struct S { int a, b; }
	S s;
	s.a = 1;
	jsonParse(`{"b":2}`, s);
	assert(s == S(1, 2));
}

// ************************************************************************

// TODO: migrate to UDAs

/**
 * A template that designates fields which should not be serialized to Json.
 *
 * Example:
 * ---
 * struct Point { int x, y, z; mixin NonSerialized!(x, z); }
 * assert(jsonParse!Point(toJson(Point(1, 2, 3))) == Point(0, 2, 0));
 * ---
 */
template NonSerialized(fields...)
{
	import ae.utils.meta : stringofArray;
	mixin(mixNonSerializedFields(stringofArray!fields()));
}

private string mixNonSerializedFields(string[] fields)
{
	string result;
	foreach (field; fields)
		result ~= "enum bool " ~ field ~ "_nonSerialized = 1;";
	return result;
}

debug(ae_unittest) unittest
{
	struct Point { int x, y, z; mixin NonSerialized!(x, z); }
	assert(jsonParse!Point(toJson(Point(1, 2, 3))) == Point(0, 2, 0));
}

debug(ae_unittest) unittest
{
	enum En { one, two }
	assert(En.one.toJson() == `"one"`);
	struct S { int i1, i2; S[] arr1, arr2; string[string] dic; En en; mixin NonSerialized!(i2, arr2); }
	S s = S(42, 5, [S(1), S(2)], [S(3), S(4)], ["apple":"fruit", "pizza":"vegetable"], En.two);
	auto s2 = jsonParse!S(toJson(s));
	assert(s.i1 == s2.i1);
	assert(s2.i2 is int.init);
	assert(s.arr1 == s2.arr1);
	assert(s2.arr2 is null);
	assert(s.dic == s2.dic, s2.dic.text);
	assert(s.en == En.two);
}

debug(ae_unittest) unittest
{
	alias B = Nullable!bool;
	B b;

	b = jsonParse!B("true");
	assert(!b.isNull);
	assert(b.get == true);
	assert(b.toJson == "true");

	b = jsonParse!B("false");
	assert(!b.isNull);
	assert(b.get == false);
	assert(b.toJson == "false");

	b = jsonParse!B("null");
	assert(b.isNull);
	assert(b.toJson == "null");

	struct S {}
	alias NS = Nullable!S;
	assert(NS.init.toJson == "null");
}

debug(ae_unittest) unittest // Issue 49
{
	immutable bool b;
	assert(toJson(b) == "false");
}

debug(ae_unittest) unittest
{
	import ae.utils.aa : OrderedMap;
	alias M = OrderedMap!(string, int);
	M m;
	m["one"] = 1;
	m["two"] = 2;
	auto j = (cast(const)m).toJson();
	assert(j == `{"one":1,"two":2}`, j);
	assert(j.jsonParse!M == m);
}

debug(ae_unittest) unittest
{
	assert(string.init.toJson.jsonParse!string  is null);
	assert(""                                  !is null);
	assert(""         .toJson                  == `""`);
	assert(""         .toJson.jsonParse!string !is null);
}

debug(ae_unittest) unittest
{
	char[] s = "{}".dup;
	assert(s.jsonParse!(string[string]) == null);
}

debug(ae_unittest) unittest
{
	typeof(null) n;
	assert(n.toJson.jsonParse!(typeof(null)) is null);
}

debug(ae_unittest) unittest
{
	double f = 1.5;
	assert(f.toJson() == "1.5");
}

debug(ae_unittest) unittest
{
	dchar c = '😸';
	assert(c.toJson() == `"😸"`);
}

/// `fromJSON` / `toJSON` can be added to a type to control their serialized representation.
debug(ae_unittest) unittest
{
	static struct S
	{
		string value;
		static S fromJSON(string value) { return S(value); }
		string toJSON() { return value; }
	}
	auto s = S("test");
	assert(s.toJson == `"test"`);
	assert(s.toJson.jsonParse!S == s);
}

debug(ae_unittest) unittest
{
	static struct S
	{
		string value;
		static S fromJSON(string value) { return S(value); }
		void toJSON(F)(F f) { f(value); }
	}
	auto s = S("test");
	auto p = &s;
	assert(p.toJson == `"test"`);
	assert(*p.toJson.jsonParse!(S*) == s);
}

/// `fromJSON` / `toJSON` can also accept/return a `JSONFragment`,
/// which allows full control over JSON serialization.
debug(ae_unittest) unittest
{
	static struct BigInt
	{
		string decimalDigits;
		static BigInt fromJSON(JSONFragment value) { return BigInt(value.json); }
		JSONFragment toJSON() { return JSONFragment(decimalDigits); }
	}
	auto n = BigInt("12345678901234567890");
	assert(n.toJson == `12345678901234567890`);
	assert(n.toJson.jsonParse!BigInt == n);
}

// ************************************************************************

/// User-defined attribute - specify name for JSON object field.
/// Useful when a JSON object may contain fields, the name of which are not valid D identifiers.
struct JSONName { string name; /***/ }

// ************************************************************************

/// User-defined attribute - only serialize this field if its value is different from its .init value.
public import ae.utils.serialization.serialization : JSONOptional = Optional;

debug(ae_unittest) unittest
{
	static struct S { @JSONOptional bool a=true, b=false; }
	assert(S().toJson == `{}`, S().toJson);
	assert(S(false, true).toJson == `{"a":false,"b":true}`);
}

debug(ae_unittest) unittest
{
	static struct S { @JSONOptional float f; }
	assert(S().toJson == `{}`, S().toJson);
}

debug(ae_unittest) unittest
{
	static struct S { @JSONOptional int[1] a; }
	assert(S().toJson == `{}`, S().toJson);
}

// ************************************************************************

/// User-defined attribute - skip unknown fields when deserializing.
public import ae.utils.serialization.serialization : JSONPartial = IgnoreUnknown;

debug(ae_unittest) unittest
{
	@JSONPartial static struct S { int b; }
	assert(`{"a":1,"b":2,"c":3.4,"d":[5,"x"],"de":[],"e":{"k":"v"},"ee":{},"f":true,"g":false,"h":null}`.jsonParse!S == S(2));
}

// ************************************************************************

/// Type for a field that collects unknown fields during deserialization.
/// During deserialization, any JSON key not matching another struct field is stored here.
/// During serialization, each entry in the map is emitted as a top-level key-value pair.
struct JSONExtras
{
	JSONFragment[string] _data;

	alias _data this;
}

debug(ae_unittest) unittest
{
	static struct S { int a; JSONExtras extras; }
	// Unknown fields are collected into extras
	auto s = `{"a":1,"b":2,"c":"hello"}`.jsonParse!S;
	assert(s.a == 1);
	assert(s.extras["b"] == JSONFragment("2"));
	assert(s.extras["c"] == JSONFragment(`"hello"`));
}

debug(ae_unittest) unittest
{
	static struct S { int a; JSONExtras extras; }
	// Serialization re-emits extras as top-level fields
	S s;
	s.a = 1;
	s.extras["b"] = JSONFragment("2");
	s.extras["c"] = JSONFragment(`"hello"`);
	auto json = s.toJson;
	// Round-trip
	auto s2 = json.jsonParse!S;
	assert(s2.a == 1);
	assert(s2.extras["b"] == JSONFragment("2"));
	assert(s2.extras["c"] == JSONFragment(`"hello"`));
}

debug(ae_unittest) unittest
{
	// @JSONExtras works alongside @JSONOptional fields
	static struct S { @JSONOptional int a; JSONExtras extras; }
	auto s = `{"b":true}`.jsonParse!S;
	assert(s.a == 0);
	assert(s.extras["b"] == JSONFragment("true"));
	// @JSONOptional field not emitted when default
	assert(s.toJson == `{"b":true}`, s.toJson);
}

debug(ae_unittest) unittest
{
	// Struct without @JSONExtras and without @JSONPartial still throws on unknown fields
	static struct S { int a; }
	bool threw;
	try
		`{"a":1,"b":2}`.jsonParse!S;
	catch (Exception e)
		threw = true;
	assert(threw);
}

// ************************************************************************

/// Fragment of raw JSON.
/// When serialized, the .json field is inserted into the resulting
/// string verbatim, without any validation.
/// When deserialized, will contain the raw JSON of one JSON object of
/// any type.
struct JSONFragment
{
	string json; ///
	bool opCast(T)() const if (is(T==bool)) { return !!json; } ///
}

debug(ae_unittest) unittest
{
	JSONFragment[] arr = [JSONFragment(`1`), JSONFragment(`true`), JSONFragment(`"foo"`), JSONFragment(`[55]`)];
	assert(arr.toJson == `[1,true,"foo",[55]]`);
	assert(arr.toJson.jsonParse!(JSONFragment[]) == arr);
}

// ************************************************************************

debug(ae_unittest) unittest
{
	int[int] aa = [3: 4];
	{
		enum JsonOptions options = { nonStringKeys: JsonOptions.NonStringKeys.error };
		static assert(!__traits(compiles, aa.toJson!options));
		static assert(!__traits(compiles, "".jsonParse!(typeof(aa), options)));
	}
	{
		enum JsonOptions options = { nonStringKeys: JsonOptions.NonStringKeys.asIs };
		auto s = aa.toJson!options;
		assert(s == `{3:4}`);
		assert(s.jsonParse!(typeof(aa), options) == aa);
	}
	{
		enum JsonOptions options = { nonStringKeys: JsonOptions.NonStringKeys.stringify };
		auto s = aa.toJson!options;
		assert(s == `{"3":4}`);
		assert(s.jsonParse!(typeof(aa), options) == aa);
	}
}
