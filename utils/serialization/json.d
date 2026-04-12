/**
 * JSON serialization source and sink.
 *
 * `JsonParser` is a source that parses JSON text and pushes events
 * into any sink. `JsonWriter` is a sink that receives events and
 * writes JSON text. Combined with the `Serializer` / `Deserializer`
 * from `ae.utils.serialization.serialization`, this provides full
 * JSON-to-D and D-to-JSON conversion.
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

module ae.utils.serialization.json;

import std.conv;
import std.exception;
import std.format;
import std.traits;
import std.utf;

import ae.utils.text;
import ae.utils.textout;

import ae.utils.serialization.serialization;
import ae.utils.serialization.store;

// ---------------------------------------------------------------------------
// Backwards compatibility aliases for ae.utils.json migration
// ---------------------------------------------------------------------------

/// Alias for `SerializedName` (backwards compat with ae.utils.json.JSONName).
alias JSONName = SerializedName;

/// Alias for `Optional` (backwards compat with ae.utils.json.JSONOptional).
alias JSONOptional = Optional;

/// Alias for `IgnoreUnknown` (backwards compat with ae.utils.json.JSONPartial).
alias JSONPartial = IgnoreUnknown;

/// Raw JSON passthrough type for backwards compatibility.
/// New code should use `SerializedObject` instead.
struct JSONFragment
{
	string json; ///
	bool opCast(T)() const if (is(T == bool)) { return !!json; } ///
}

// ---------------------------------------------------------------------------
// Escapes table
// ---------------------------------------------------------------------------

private struct Escapes
{
	string[256] chars;
	bool[256] escaped;

	void populate()
	{
		escaped[] = true;
		foreach (c; 0 .. 256)
			if (c == '\\')
				chars[c] = `\\`;
			else if (c == '\"')
				chars[c] = `\"`;
			else if (c == '\b')
				chars[c] = `\b`;
			else if (c == '\f')
				chars[c] = `\f`;
			else if (c == '\n')
				chars[c] = `\n`;
			else if (c == '\r')
				chars[c] = `\r`;
			else if (c == '\t')
				chars[c] = `\t`;
			else if (c < '\x20' || c == '\x7F' || c == '<' || c == '>' || c == '&')
				chars[c] = std.format.format(`\u%04x`, c);
			else
				chars[c] = [cast(char) c],
				escaped[c] = false;
	}
}

private immutable Escapes escapes = {
	Escapes e;
	e.populate();
	return e;
}();

// ---------------------------------------------------------------------------
// JsonParser -- source that parses JSON text
// ---------------------------------------------------------------------------

/// Serialization source which parses a JSON string.
struct JsonParser(C = immutable(char), JsonOptions options = JsonOptions.init)
{
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
		return s[a .. b];
	}

	@property bool eof()
	{
		return p == s.length;
	}

	// ------------------------------------------------------------------

	static bool isWhite(C c)
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r';
	}

	void skipWhitespace()
	{
		while (!eof && isWhite(peek()))
			skip();
	}

	void expect(C c)
	{
		auto n = next();
		enforce(n == c, "Expected %s, got %s".format(c, n));
	}

	// ------------------------------------------------------------------
	// Reader structs
	// ------------------------------------------------------------------

	/// Reads a JSON value and pushes events to a sink.
	void read(Sink)(Sink sink)
	{
		skipWhitespace();
		switch (peek())
		{
		case '[':
			skip();
			ArrayReader ar = {parser: &this};
			sink.handleArray(ar);
			break;
		case '"':
			skip();
			sink.handleString(readWholeString());
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
		case '0': .. case '9':
			sink.handleNumeric(readNumeric());
			break;
		case '{':
			skip();
			ObjectReader or_ = {parser: &this};
			sink.handleObject(or_);
			break;
		default:
			throw new Exception("Unknown JSON symbol: %s".format(peek()));
		}
	}

	static struct ArrayReader
	{
		JsonParser* parser;

		void opCall(Sink)(Sink sink)
		{
			if (parser.peek() == ']')
			{
				parser.skip();
				return;
			}
			while (true)
			{
				parser.read(sink);
				parser.skipWhitespace();
				if (parser.peek() == ']')
				{
					parser.skip();
					return;
				}
				else
					parser.expect(',');
			}
		}
	}

	static struct ObjectReader
	{
		JsonParser* parser;

		void opCall(Sink)(Sink sink)
		{
			parser.skipWhitespace();
			if (parser.peek() == '}')
			{
				parser.skip();
				return;
			}

			while (true)
			{
				// In standard JSON, object keys are always strings. Use
				// StringReader to avoid instantiating non-string sink methods.
				// NonStringKeys.asIs produces non-standard JSON with unquoted
				// keys, so fall back to ValueReader for that case.
				static if (options.nonStringKeys == JsonOptions.NonStringKeys.asIs)
					ValueReader nr = {parser: parser};
				else
					StringReader nr = {parser: parser};
				ObjectValueReader vr = {parser: parser};
				sink.handleField(nr, vr);

				parser.skipWhitespace();
				if (parser.peek() == '}')
				{
					parser.skip();
					return;
				}
				else
					parser.expect(',');
			}
		}
	}

	/// Reads a single JSON value.
	static struct ValueReader
	{
		JsonParser* parser;

		void opCall(Sink)(Sink sink)
		{
			parser.read(sink);
		}
	}

	/// Reads a JSON string value. Used for object field names, which in
	/// standard JSON are always strings. Using this instead of ValueReader
	/// avoids instantiating non-string sink methods (handleArray, etc.).
	static struct StringReader
	{
		JsonParser* parser;

		void opCall(Sink)(Sink sink)
		{
			parser.skipWhitespace();
			parser.expect('"');
			sink.handleString(parser.readWholeString());
		}
	}

	/// Reads ':' then a JSON value (used as value reader for object fields).
	static struct ObjectValueReader
	{
		JsonParser* parser;

		void opCall(Sink)(Sink sink)
		{
			parser.skipWhitespace();
			parser.expect(':');
			parser.read(sink);
		}
	}

	/// Read a complete JSON string (after opening '"' is consumed).
	/// Returns the unescaped string content.
	C[] readWholeString()
	{
		// Fast path: try to find closing quote with no escapes
		auto start = mark();
		while (true)
		{
			C c = peek();
			if (c == '"')
			{
				// No escapes -- return slice directly (zero allocation)
				auto result = slice(start, mark());
				skip(); // consume closing quote
				return result;
			}
			else if (c == '\\')
			{
				// Has escape -- switch to slow path
				break;
			}
			else
				skip();
		}

		// Slow path: build with escape processing
		C[] buf;
		buf ~= slice(start, mark());

		while (true)
		{
			C c = peek();
			if (c == '"')
			{
				skip();
				return buf;
			}
			else if (c == '\\')
			{
				skip();
				switch (next())
				{
				case '"':  buf ~= '"'; break;
				case '/':  buf ~= '/'; break;
				case '\\': buf ~= '\\'; break;
				case 'b':  buf ~= '\b'; break;
				case 'f':  buf ~= '\f'; break;
				case 'n':  buf ~= '\n'; break;
				case 'r':  buf ~= '\r'; break;
				case 't':  buf ~= '\t'; break;
				case 'u':
				{
					auto w = cast(wchar) fromHex!ushort(readN(4));
					static if (C.sizeof == 1)
					{
						char[4] tmpbuf;
						auto len = encode(tmpbuf, w);
						buf ~= cast(C[]) tmpbuf[0 .. len];
					}
					else
					{
						buf ~= cast(C) w;
					}
					break;
				}
				default:
					enforce(false, "Unknown escape");
				}
			}
			else
			{
				buf ~= c;
				skip();
			}
		}
	}

	C[] readNumeric()
	{
		auto m = mark();

		static immutable bool[256] numeric = [
			'0': true, '1': true, '2': true, '3': true, '4': true,
			'5': true, '6': true, '7': true, '8': true, '9': true,
			'.': true, '-': true, '+': true, 'e': true, 'E': true,
		];

		while (!eof() && numeric[peek()])
			skip();
		return slice(m, mark());
	}
}

// ---------------------------------------------------------------------------
// JsonWriter -- sink that writes JSON text
// ---------------------------------------------------------------------------

/// JSON serialization/deserialization options.
struct JsonOptions
{
	/// What to do with associative arrays with non-string keys.
	enum NonStringKeys
	{
		/// Fail compilation (default).
		error,
		/// Write keys as-is (numeric keys become unquoted JSON numbers).
		/// Note: produces non-standard JSON.
		asIs,
		/// Serialize key to JSON, then use that string as the JSON object key.
		/// E.g., int key 3 becomes the string key "3".
		stringify,
	}
	NonStringKeys nonStringKeys = NonStringKeys.error; /// ditto
}

/// Serialization sink which writes JSON output.
struct JsonWriter(Output = StringBuilder, JsonOptions options = JsonOptions.init)
{
	Output output;
	bool needComma;

	void handleNumeric(CC)(CC[] str)
	{
		output.put(str);
	}

	void handleString(CC)(CC[] str)
	{
		import std.utf : byChar;
		output.put('"');
		static if (is(CC == char))
			writeStringFragment(str);
		else
		{
			// Convert wide string to char-by-char output
			foreach (char c; str.byChar)
			{
				if (escapes.escaped[c])
					output.put(escapes.chars[c]);
				else
					output.put(c);
			}
		}
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

	private void writeStringFragment(CC)(CC[] s)
	{
		auto start = s.ptr, p_ = start, end = start + s.length;

		while (p_ < end)
		{
			auto c = *p_++;
			if (escapes.escaped[c])
				output.put(start[0 .. p_ - start - 1], escapes.chars[c]),
				start = p_;
		}

		output.put(start[0 .. p_ - start]);
	}

	void handleStringFragments(Reader)(Reader reader)
	{
		output.put('"');
		FragmentSink fs = {writer: &this};
		reader(&fs);
		output.put('"');
	}

	void handleArray(Reader)(Reader reader)
	{
		auto outerComma = needComma;
		needComma = false;
		output.put('[');
		ArrayElementSink as = {writer: &this};
		reader(&as);
		output.put(']');
		needComma = outerComma;
	}

	void handleObject(Reader)(Reader reader)
	{
		auto outerComma = needComma;
		needComma = false;
		output.put('{');
		ObjectFieldSink os = {writer: &this};
		reader(&os);
		output.put('}');
		needComma = outerComma;
	}

	// -- Inner sink structs --

	static struct FragmentSink
	{
		JsonWriter* writer;

		void handleStringFragment(CC)(CC[] s)
		{
			writer.writeStringFragment(s);
		}
	}

	/// Sink for array elements -- inserts commas between elements.
	static struct ArrayElementSink
	{
		JsonWriter* writer;

		alias handleObject = opDispatch!"handleObject";
		alias handleStringFragments = opDispatch!"handleStringFragments";
		alias handleBoolean = opDispatch!"handleBoolean";
		alias handleNull = opDispatch!"handleNull";
		alias handleNumeric = opDispatch!"handleNumeric";
		alias handleString = opDispatch!"handleString";
		alias handleArray = opDispatch!"handleArray";

		template opDispatch(string name)
		{
			void opDispatch(Args...)(auto ref Args args)
			{
				if (writer.needComma)
					writer.output.put(',');

				mixin("writer." ~ name ~ "(args);");
				writer.needComma = true;
			}
		}
	}

	/// Sink for object fields -- handles key:value pairs with commas.
	static struct ObjectFieldSink
	{
		JsonWriter* writer;

		void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
		{
			if (writer.needComma)
				writer.output.put(',');

			writeName(nameReader);
			writer.output.put(':');
			writeValue(valueReader);

			writer.needComma = true;
		}

		private void writeName(NameReader)(NameReader nameReader)
		{
			static if (options.nonStringKeys == JsonOptions.NonStringKeys.error)
			{
				static struct KeySink
				{
					JsonWriter* writer;
					void handleString(CC)(CC[] str) { writer.handleString(str); }
					void handleNull() { writer.handleString(""); }
				}
				KeySink ks = { writer: writer };
				nameReader(&ks);
			}
			else static if (options.nonStringKeys == JsonOptions.NonStringKeys.asIs)
				nameReader(writer);
			else static if (options.nonStringKeys == JsonOptions.NonStringKeys.stringify)
			{
				static struct StringifyKeySink
				{
					JsonWriter* writer;
					void handleString(CC)(CC[] str) { writer.handleString(str); }
					void handleNumeric(CC)(CC[] str)
					{
						writer.output.put('"');
						writer.output.put(str);
						writer.output.put('"');
					}
					void handleBoolean(bool v)
					{
						writer.output.put('"');
						writer.output.put(v ? "true" : "false");
						writer.output.put('"');
					}
					void handleNull()
					{
						writer.output.put(`"null"`);
					}
				}
				StringifyKeySink ks = { writer: writer };
				nameReader(&ks);
			}
		}

		private void writeValue(ValueReader)(ValueReader valueReader)
		{
			valueReader(writer);
		}
	}

	/// Get the JSON string output.
	auto get()
	{
		return output.get();
	}
}

/// JSON sink with pretty-printing (indentation and newlines).
struct PrettyJsonWriter(Output = StringBuilder, char indent = '\t', string newLine = "\n", string preColon = " ", string postColon = preColon)
{
	Output output;
	bool needComma;

	private uint indentLevel;
	private bool indentPending;

	private void putIndent()
	{
		if (indentPending)
		{
			foreach (_; 0 .. indentLevel)
				output.put(indent);
			indentPending = false;
		}
	}

	private void putNewline()
	{
		if (!indentPending)
		{
			output.put(newLine);
			indentPending = true;
		}
	}

	void handleNumeric(CC)(CC[] str)
	{
		putIndent();
		output.put(str);
	}

	void handleString(CC)(CC[] str)
	{
		putIndent();
		output.put('"');
		writeStringFragment(str);
		output.put('"');
	}

	void handleNull()
	{
		putIndent();
		output.put("null");
	}

	void handleBoolean(bool v)
	{
		putIndent();
		output.put(v ? "true" : "false");
	}

	private void writeStringFragment(CC)(CC[] s)
	{
		auto start = s.ptr, p_ = start, end = start + s.length;
		while (p_ < end)
		{
			auto c = *p_++;
			if (escapes.escaped[c])
				output.put(start[0 .. p_ - start - 1], escapes.chars[c]),
				start = p_;
		}
		output.put(start[0 .. p_ - start]);
	}

	void handleArray(Reader)(Reader reader)
	{
		auto outerComma = needComma;
		needComma = false;
		putIndent();
		output.put('[');
		indentLevel++;
		putNewline();
		ArrayElementSink as = {writer: &this};
		reader(&as);
		indentLevel--;
		putNewline();
		putIndent();
		output.put(']');
		needComma = outerComma;
	}

	void handleObject(Reader)(Reader reader)
	{
		auto outerComma = needComma;
		needComma = false;
		putIndent();
		output.put('{');
		indentLevel++;
		putNewline();
		ObjectFieldSink os = {writer: &this};
		reader(&os);
		indentLevel--;
		putNewline();
		putIndent();
		output.put('}');
		needComma = outerComma;
	}

	static struct ArrayElementSink
	{
		PrettyJsonWriter* writer;

		alias handleObject = opDispatch!"handleObject";
		alias handleBoolean = opDispatch!"handleBoolean";
		alias handleNull = opDispatch!"handleNull";
		alias handleNumeric = opDispatch!"handleNumeric";
		alias handleString = opDispatch!"handleString";
		alias handleArray = opDispatch!"handleArray";

		template opDispatch(string name)
		{
			void opDispatch(Args...)(auto ref Args args)
			{
				if (writer.needComma)
				{
					writer.output.put(',');
					writer.putNewline();
				}

				mixin("writer." ~ name ~ "(args);");
				writer.needComma = true;
			}
		}
	}

	static struct ObjectFieldSink
	{
		PrettyJsonWriter* writer;

		void handleField(NameReader, ValueReader)(NameReader nameReader, ValueReader valueReader)
		{
			if (writer.needComma)
			{
				writer.output.put(',');
				writer.putNewline();
			}

			nameReader(writer);
			writer.output.put(preColon);
			writer.output.put(':');
			writer.output.put(postColon);
			// Value should not add its own indent (it follows the key on the same line)
			writer.indentPending = false;
			valueReader(writer);

			writer.needComma = true;
		}
	}

	auto get()
	{
		return output.get();
	}
}

/// Serialize a D value to a pretty-printed JSON string.
string toPrettyJson(T)(auto ref T v)
{
	PrettyJsonWriter!StringBuilder writer;
	JsonCustomSerializer.Impl!Object.read(&writer, v);
	return writer.get();
}

// ---------------------------------------------------------------------------
// JSON-specific transforms (toJSON / fromJSON hooks)
// ---------------------------------------------------------------------------

/// Detect JSONFragment-like types (raw JSON passthrough).
private template isJSONFragment(T)
{
	static if (is(T == struct) && __traits(hasMember, T, "json") &&
		is(typeof(T.init.json) : const(char)[]))
		enum isJSONFragment = __traits(identifier, T) == "JSONFragment";
	else
		enum isJSONFragment = false;
}

/// Serialization transform: detects `toJSON` on user types and JSONFragment.
///
/// Supports:
///   - Value-returning: `auto toJSON() const` — returns a replacement value
///   - Callback: `void toJSON(F)(F f)` — calls `f(replacement)` with the value
///   - JSONFragment: emits `.json` content by parsing and replaying through the sink
template JsonSerializeTransform(alias read, T)
{
	static if (isJSONFragment!T)
	{
		// JSONFragment: parse the raw JSON string and replay events into the sink
		enum hasTransform = true;
		static void serialize(Sink)(Sink sink, auto ref T v)
		{
			auto parser = JsonParser!(immutable(char))(v.json, 0);
			parser.read(sink);
		}
	}
	else static if (__traits(hasMember, T, "toJSON") && is(typeof(T.init.toJSON())))
	{
		// Value-returning form
		enum hasTransform = true;
		static void serialize(Sink)(Sink sink, auto ref T v)
		{
			auto tmp = v.toJSON();
			read(sink, tmp);
		}
	}
	else static if (__traits(hasMember, T, "toJSON"))
	{
		// Callback form: void toJSON(F)(F f) where F accepts a value
		enum hasTransform = true;
		static void serialize(Sink)(Sink sink, auto ref T v)
		{
			static struct PutCallback
			{
				Sink* sink;
				void opCall(V)(auto ref V j)
				{
					read(*sink, j);
				}
			}
			PutCallback cb = { sink: &sink };
			v.toJSON(cb);
		}
	}
	else
	{
		enum hasTransform = false;
	}
}

/// Deserialization transform: detects `fromJSON` on user types.
///
/// `static T fromJSON(P)` where P is the parameter type that determines
/// what intermediate form to deserialize first (e.g., `string`, `SerializedObject`).
template JsonDeserializeTransform(T)
{
	static if (isJSONFragment!T)
	{
		// JSONFragment: buffer into SerializedObject, then re-serialize to JSON string
		enum hasTransform = true;

		alias SO = SerializedObject!(immutable(char));

		static auto makeSink(T* p)
		{
			static struct FragmentSink
			{
				T* target;
				SO temp;

				// Forward all events to the SO (which implements the sink protocol)
				void handleString(S)(S s) { temp.handleString(s); done(); }
				void handleNumeric(CC)(CC[] s) { temp.handleNumeric(s); done(); }
				void handleBoolean(bool v) { temp.handleBoolean(v); done(); }
				void handleNull() { temp.handleNull(); done(); }
				void handleArray(Reader)(Reader r) { temp.handleArray(r); done(); }
				void handleObject(Reader)(Reader r) { temp.handleObject(r); done(); }

				private void done()
				{
					// Re-serialize SO to JSON string
					JsonWriter!StringBuilder writer;
					temp.read(&writer);
					target.json = writer.get();
				}
			}

			return FragmentSink(p);
		}
	}
	else static if (__traits(hasMember, T, "fromJSON"))
	{
		enum hasTransform = true;

		alias Q = Parameters!(T.fromJSON)[0];

		static auto makeSink(T* p)
		{
			// Wrapper sink: deserialize into intermediate type Q using the
			// standard deserializer, then apply T.fromJSON to produce T.
			static struct TransformSink
			{
				T* target;
				Q temp;

				// Create the inner sink that deserializes into temp
				auto innerSink()
				{
					return Deserializer!Object.makeSink!Q(&temp);
				}

				// Forward all sink events to the inner sink for Q
				void handleString(S)(S s) { auto s_ = innerSink(); s_.handleString(s); done(); }
				void handleStringFragments(Reader)(Reader r) { auto s_ = innerSink(); s_.handleStringFragments(r); done(); }
				void handleNumeric(CC)(CC[] s) { auto s_ = innerSink(); s_.handleNumeric(s); done(); }
				void handleBoolean(bool v) { auto s_ = innerSink(); s_.handleBoolean(v); done(); }
				void handleNull() { auto s_ = innerSink(); s_.handleNull(); done(); }
				void handleArray(Reader)(Reader r) { auto s_ = innerSink(); s_.handleArray(r); done(); }
				void handleObject(Reader)(Reader r) { auto s_ = innerSink(); s_.handleObject(r); done(); }

				private void done()
				{
					static if (is(typeof(*target = T.fromJSON(temp))))
						*target = T.fromJSON(temp);
					else
					{
						import core.lifetime : move;
						auto converted = T.fromJSON(temp);
						move(converted, *target);
					}
				}
			}

			return TransformSink(p);
		}
	}
	else
	{
		enum hasTransform = false;
	}
}

/// JSON-aware serializer (handles toJSON hooks).
alias JsonCustomSerializer = CustomSerializer!JsonSerializeTransform;

/// JSON-aware deserializer (handles fromJSON hooks).
template JsonCustomDeserializer(alias anchor)
{
	alias JsonCustomDeserializer = CustomDeserializer!(JsonDeserializeTransform, anchor);
}

alias jsonCustomDeserializer = JsonCustomDeserializer!Object.makeSink;

// ---------------------------------------------------------------------------
// Convenience wrappers
// ---------------------------------------------------------------------------

/// Parse a JSON string into a D type.
template jsonParse(T, JsonOptions options = JsonOptions.init)
{
	T jsonParse(C)(C[] s)
	{
		auto parser = JsonParser!(C, options)(s, 0);
		T result;
		auto sink = jsonCustomDeserializer(&result);
		parser.skipWhitespace();
		if (!parser.eof)
			parser.read(sink);
		return result;
	}
}

/// Serialize a D value to a JSON string.
string toJson(JsonOptions options = JsonOptions.init, T)(auto ref T v)
{
	JsonWriter!(StringBuilder, options) writer;
	JsonCustomSerializer.Impl!Object.read(&writer, v);
	return writer.get();
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

debug(ae_unittest):

private struct Inner
{
	int x;
	string s;
}

private struct TestStruct
{
	int a;
	string name;
	bool flag;
	Inner inner;
	int[] arr;
	string[string] map;
}

private TestStruct testValue()
{
	TestStruct t;
	t.a = 42;
	t.name = "hello";
	t.flag = true;
	t.inner = Inner(7, "world");
	t.arr = [1, 2, 3];
	t.map = ["key1": "val1", "key2": "val2"];
	return t;
}

// JSON string -> D struct
unittest
{
	auto result = jsonParse!Inner(`{"x":7,"s":"world"}`);
	assert(result.x == 7);
	assert(result.s == "world");
}

// D struct -> JSON string
unittest
{
	auto json = toJson(Inner(7, "world"));
	assert(json == `{"x":7,"s":"world"}`, json);
}

// Round-trip
unittest
{
	struct S
	{
		int i;
		string s;
	}

	auto json = toJson(S(42, "foo"));
	assert(json == `{"i":42,"s":"foo"}`, json);

	auto parsed = jsonParse!S(`{"i":42,"s":"foo"}`);
	assert(parsed.i == 42);
	assert(parsed.s == "foo");
}

// Basic JSON values
unittest
{
	assert(toJson("Hello \"world\"") == `"Hello \"world\""`, toJson("Hello \"world\""));
	assert(toJson(["Hello", "world"]) == `["Hello","world"]`);
	assert(toJson([true, false]) == `[true,false]`);
	assert(toJson([4, 2]) == `[4,2]`);
	assert(toJson((int[]).init) == `[]`);
}

// Parse basic values
unittest
{
	assert(jsonParse!(int[])(`[4,2]`) == [4, 2]);
	assert(jsonParse!(string[])(`["Hello","world"]`) == ["Hello", "world"]);
	assert(jsonParse!bool(`true`) == true);
	assert(jsonParse!bool(`false`) == false);
	assert(jsonParse!int(`42`) == 42);
	assert(jsonParse!string(`"hello"`) == "hello");
}

// AA serialization/parse
unittest
{
	auto json = toJson(["a": 1, "b": 2]);
	auto parsed = jsonParse!(int[string])(json);
	assert(parsed["a"] == 1);
	assert(parsed["b"] == 2);
}

// Null handling
unittest
{
	struct S
	{
		string s;
	}

	auto result = jsonParse!S(`{"s":null}`);
	assert(result.s is null);
}

// SerializedObject integration -- all 6 composition paths
unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	auto original = testValue();

	// Path 3: JSON string -> SerializedObject
	auto jsonStr = `{"a":42,"name":"hello","flag":true,"inner":{"x":7,"s":"world"},"arr":[1,2,3],"map":{"key1":"val1","key2":"val2"}}`;
	SO store;
	auto parser = JsonParser!(immutable(char))(jsonStr, 0);
	parser.read(&store);
	assert(store.type == SO.Type.object);

	// Path 4: SerializedObject -> JSON string
	JsonWriter!StringBuilder writer;
	store.read(&writer);
	auto jsonOut = writer.get();
	auto reparsed = jsonParse!TestStruct(jsonOut);
	assert(reparsed.a == 42);
	assert(reparsed.name == "hello");
	assert(reparsed.flag == true);
	assert(reparsed.inner.x == 7);
	assert(reparsed.inner.s == "world");
	assert(reparsed.arr == [1, 2, 3]);

	// Path 5: D struct -> SerializedObject
	SO store2;
	Serializer.Impl!Object.read(&store2, original);
	assert(store2.type == SO.Type.object);

	// Path 6: SerializedObject -> D struct
	TestStruct result;
	auto sink = deserializer(&result);
	store2.read(sink);
	assert(result.a == 42);
	assert(result.name == "hello");
	assert(result.flag == true);
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
	assert(result.map == ["key1": "val1", "key2": "val2"]);
}

// JSON -> SerializedObject -> D struct (no string round-trip)
unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	auto jsonStr = `{"a":42,"name":"hello","flag":true,"inner":{"x":7,"s":"world"},"arr":[1,2,3],"map":{"key1":"val1","key2":"val2"}}`;
	SO store;
	auto parser = JsonParser!(immutable(char))(jsonStr, 0);
	parser.read(&store);

	TestStruct result;
	auto sink = deserializer(&result);
	store.read(sink);

	assert(result.a == 42);
	assert(result.name == "hello");
	assert(result.flag == true);
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
	assert(result.map == ["key1": "val1", "key2": "val2"]);
}

// D struct -> SerializedObject -> JSON string
unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	auto original = testValue();

	SO store;
	Serializer.Impl!Object.read(&store, original);

	JsonWriter!StringBuilder writer;
	store.read(&writer);
	auto jsonOut = writer.get();

	auto result = jsonParse!TestStruct(jsonOut);
	assert(result.a == 42);
	assert(result.name == "hello");
	assert(result.flag == true);
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
}

// JSON-to-JSON round-trip (parser -> writer)
unittest
{
	auto input = `{"i":42,"s":"foo"}`;
	auto parser = JsonParser!(immutable(char))(input, 0);
	JsonWriter!StringBuilder writer;
	parser.read(&writer);
	assert(writer.get() == input, writer.get());
}

// Float handling
unittest
{
	assert(toJson(4.5) == `4.5`);
	assert(jsonParse!double(`4.5`) == 4.5);
}

// SerializedObject as a field type (JSONFragment replacement)
unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	// --- Round-trip: JSON-RPC-like struct with SO fields ---
	static struct JsonRpcRequest
	{
		string jsonrpc;
		string method;
		@Optional SO params;
		@Optional SO id;
	}

	// Deserialize from JSON
	auto req = jsonParse!JsonRpcRequest(`{"jsonrpc":"2.0","method":"add","params":[2,3],"id":1}`);
	assert(req.jsonrpc == "2.0");
	assert(req.method == "add");
	assert(req.id.type == SO.Type.numeric);

	// Re-serialize to JSON
	auto json = toJson(req);
	assert(json == `{"jsonrpc":"2.0","method":"add","params":[2,3],"id":1}`, json);

	// Deserialize the params further into a typed value
	int[] params;
	auto sink = deserializer(&params);
	req.params.read(sink);
	assert(params == [2, 3]);

	// --- SO with object value ---
	auto req2 = jsonParse!JsonRpcRequest(`{"jsonrpc":"2.0","method":"add","params":{"a":1,"b":2},"id":"abc"}`);
	assert(req2.params.type == SO.Type.object);
	assert(req2.id.type == SO.Type.string_);

	// Round-trip
	auto json2 = toJson(req2);
	auto reparsed = jsonParse!JsonRpcRequest(json2);
	assert(reparsed.method == "add");
	assert(reparsed.id.type == SO.Type.string_);

	// --- SO with null/boolean/missing values ---
	auto req3 = jsonParse!JsonRpcRequest(`{"jsonrpc":"2.0","method":"notify"}`);
	assert(req3.params.type == SO.Type.none);  // @Optional, not present
	assert(req3.id.type == SO.Type.none);

	// Notification round-trip (no params, no id)
	auto json3 = toJson(req3);
	assert(json3 == `{"jsonrpc":"2.0","method":"notify"}`, json3);

	// --- SO as AA key substitute (codec pattern) ---
	// Use toJson of SO for canonical key form
	auto id1 = jsonParse!SO(`1`);
	auto id2 = jsonParse!SO(`"abc"`);
	assert(toJson(id1) == "1");
	assert(toJson(id2) == `"abc"`);

	// --- Nested SO in arrays/objects ---
	auto arrJson = `[1,"hello",true,null,[1,2],{"a":3}]`;
	auto arr = jsonParse!(SO[])(arrJson);
	assert(arr.length == 6);
	assert(arr[0].type == SO.Type.numeric);
	assert(arr[1].type == SO.Type.string_);
	assert(arr[2].type == SO.Type.boolean);
	assert(arr[3].type == SO.Type.null_);
	assert(arr[4].type == SO.Type.array);
	assert(arr[5].type == SO.Type.object);
	assert(toJson(arr) == arrJson, toJson(arr));

	// --- Map of SO (like JSONFragment[string]) ---
	auto objJson = `{"a":1,"b":"hello","c":true}`;
	auto obj = jsonParse!(SO[string])(objJson);
	assert(obj["a"].type == SO.Type.numeric);
	assert(obj["b"].type == SO.Type.string_);
	assert(obj["c"].type == SO.Type.boolean);
}

// toJSON / fromJSON hooks via JsonSerializeTransform / JsonDeserializeTransform
unittest
{
	import std.conv : to;

	// Value-returning toJSON + fromJSON
	static struct Wrapper
	{
		int value;
		string toJSON() const { return to!string(value); }
		static Wrapper fromJSON(string s) { return Wrapper(to!int(s)); }
	}

	// Serialize: toJSON returns string "42", so JSON output is `"42"`
	assert(toJson(Wrapper(42)) == `"42"`);

	// Deserialize: fromJSON receives "42", constructs Wrapper(42)
	auto w = jsonParse!Wrapper(`"42"`);
	assert(w.value == 42);

	// Round-trip
	auto json = toJson(Wrapper(99));
	assert(jsonParse!Wrapper(json).value == 99);
}

// Callback form of toJSON
unittest
{
	static struct CallbackWrapper
	{
		int x, y;
		void toJSON(F)(F f) { f([x, y]); }
	}

	assert(toJson(CallbackWrapper(3, 4)) == `[3,4]`);
}

// Nested struct with toJSON fields
unittest
{
	import std.conv : to;

	static struct Wrapper
	{
		int value;
		string toJSON() const { return to!string(value); }
		static Wrapper fromJSON(string s) { return Wrapper(to!int(s)); }
	}

	static struct Outer
	{
		string name;
		Wrapper w;
	}

	auto json = toJson(Outer("hello", Wrapper(7)));
	assert(json == `{"name":"hello","w":"7"}`, json);

	auto parsed = jsonParse!Outer(`{"name":"hello","w":"7"}`);
	assert(parsed.name == "hello");
	assert(parsed.w.value == 7);
}

// Verify plain Serializer does NOT invoke toJSON (layering test)
unittest
{
	import std.conv : to;

	static struct Wrapper
	{
		int value;
		string toJSON() const { return to!string(value); }
	}

	// Plain Serializer serializes the struct fields, ignoring toJSON
	JsonWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, Wrapper(42));
	assert(writer.get() == `{"value":42}`, writer.get());
}

// JSONFragment support
unittest
{
	// Define a JSONFragment-compatible struct (same layout as ae.utils.json.JSONFragment)
	static struct JSONFragment
	{
		string json;
	}

	// Serialize: emits raw JSON verbatim
	assert(toJson(JSONFragment(`42`)) == `42`);
	assert(toJson(JSONFragment(`"hello"`)) == `"hello"`);
	assert(toJson(JSONFragment(`[1,2,3]`)) == `[1,2,3]`);
	assert(toJson(JSONFragment(`{"a":1}`)) == `{"a":1}`);
	assert(toJson(JSONFragment(`true`)) == `true`);
	assert(toJson(JSONFragment(`null`)) == `null`);

	// Deserialize: captures raw JSON
	auto f1 = jsonParse!JSONFragment(`42`);
	assert(f1.json == `42`, f1.json);

	auto f2 = jsonParse!JSONFragment(`"hello"`);
	assert(f2.json == `"hello"`, f2.json);

	auto f3 = jsonParse!JSONFragment(`[1,2,3]`);
	assert(f3.json == `[1,2,3]`, f3.json);

	auto f4 = jsonParse!JSONFragment(`{"a":1}`);
	assert(f4.json == `{"a":1}`, f4.json);

	auto f5 = jsonParse!JSONFragment(`true`);
	assert(f5.json == `true`, f5.json);

	auto f6 = jsonParse!JSONFragment(`null`);
	assert(f6.json == `null`, f6.json);

	// Round-trip
	auto fArr = jsonParse!(JSONFragment[])(`[1,true,"foo",[55]]`);
	assert(fArr.length == 4);
	assert(fArr[0].json == `1`);
	assert(fArr[1].json == `true`);
	assert(fArr[2].json == `"foo"`);
	assert(fArr[3].json == `[55]`);
	assert(toJson(fArr) == `[1,true,"foo",[55]]`);

	// JSONFragment in a struct field
	static struct Msg
	{
		string method;
		@Optional JSONFragment params;
	}

	auto msg = jsonParse!Msg(`{"method":"add","params":[2,3]}`);
	assert(msg.method == "add");
	assert(msg.params.json == `[2,3]`, msg.params.json);
	assert(toJson(msg) == `{"method":"add","params":[2,3]}`, toJson(msg));
}

// JsonOptions: non-string keys
unittest
{
	// stringify mode: int keys become quoted strings
	{
		enum opts = JsonOptions(JsonOptions.NonStringKeys.stringify);
		auto json = toJson!opts(["a": 1, "b": 2]);
		auto parsed = jsonParse!(int[string])(json);
		assert(parsed["a"] == 1);
		assert(parsed["b"] == 2);
	}

	// stringify mode with int[int]
	{
		enum opts = JsonOptions(JsonOptions.NonStringKeys.stringify);
		auto json = toJson!opts([3: 4, 5: 6]);
		// Keys should be quoted strings: {"3":4,"5":6}
		auto parsed = jsonParse!(int[string])(json);
		assert(parsed["3"] == 4 || parsed["3"] == 4);
		assert(parsed["5"] == 6 || parsed["5"] == 6);
	}

	// asIs mode: int keys written unquoted
	{
		enum opts = JsonOptions(JsonOptions.NonStringKeys.asIs);
		JsonWriter!(StringBuilder, opts) writer;
		JsonCustomSerializer.Impl!Object.read(&writer, [3: 4]);
		auto json = writer.get();
		// Non-standard JSON: {3:4}
		assert(json == `{3:4}`, json);
	}

	// error mode (default): non-string keys are a compile error
	static assert(!__traits(compiles, toJson([3: 4])));
}

// Pretty printing
unittest
{
	static struct X { int a; string b; int[] c; }
	X x = {17, "aoeu", [1, 2, 3]};
	assert(toPrettyJson(x) ==
`{
	"a" : 17,
	"b" : "aoeu",
	"c" : [
		1,
		2,
		3
	]
}`, toPrettyJson(x));
}

unittest
{
	// Nested objects
	static struct Inner { int x; }
	static struct Outer { string name; Inner inner; }
	auto json = toPrettyJson(Outer("hello", Inner(42)));
	assert(json ==
`{
	"name" : "hello",
	"inner" : {
		"x" : 42
	}
}`, json);
}

unittest
{
	// Simple values
	assert(toPrettyJson(42) == `42`);
	assert(toPrettyJson("hello") == `"hello"`);
	assert(toPrettyJson(true) == `true`);
}
