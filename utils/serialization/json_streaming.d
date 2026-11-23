/**
 * Streaming JSON parser using fibers.
 *
 * A JSON parser that can be fed data incrementally in arbitrary-sized
 * chunks. The parser runs in a fiber and yields when it needs more
 * input. This enables parsing JSON from streaming sources (TCP sockets,
 * pipes, etc.) without buffering the entire document.
 *
 * The parser emits events into the standard source/sink protocol,
 * so it can feed any sink: `Deserializer`, `SerializedObject`,
 * `JsonWriter`, etc.
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

module ae.utils.serialization.json_streaming;

import core.thread : Fiber;

import std.conv;
import std.exception;
import std.format;
import std.utf;

import ae.utils.text : fromHex;

import ae.utils.serialization.serialization;

/// Heap-allocated fiber-based streaming JSON parser.
///
/// Usage:
/// ---
/// auto parser = new StreamingJsonParser!(immutable(char));
/// parser.start(sink);       // starts the fiber
/// parser.feed(chunk1);      // resumes the fiber with data
/// parser.feed(chunk2);
/// parser.endInput();        // signals end of input
/// assert(parser.done);
/// ---
class StreamingJsonParser(C = immutable(char))
{
	/// Start parsing, emitting events into `sink`.
	void start(Sink)(Sink sink)
	{
		assert(!parsingStarted);
		parsingStarted = true;

		fiber = new Fiber({
			try
			{
				this.parseValue(sink);
				this.parsingComplete = true;
			}
			catch (Throwable t)
			{
				this.parseError = t;
			}
		});

		// Start the fiber — it will run until it needs input
		fiber.call();
		if (parseError)
			throw parseError;
	}

	/// Feed a chunk of input data.
	void feed(const(C)[] data)
	{
		assert(parsingStarted, "Must call start() before feed()");
		if (parsingComplete)
			return;

		currentBuf = data;
		currentPos = 0;

		fiber.call();
		if (parseError)
			throw parseError;
	}

	/// Signal end of input.
	void endInput()
	{
		inputDone = true;
		if (!parsingComplete && parsingStarted)
		{
			currentBuf = null;
			currentPos = 0;
			fiber.call();
			if (parseError)
				throw parseError;
		}
	}

	/// True when parsing has completed successfully.
	@property bool done() { return parsingComplete; }

private:
	const(C)[] currentBuf;
	size_t currentPos;
	bool inputDone;
	bool parsingStarted;
	bool parsingComplete;

	Fiber fiber;
	Throwable parseError;

	// ------------------------------------------------------------------
	// Character-level input (yields when buffer exhausted)
	// ------------------------------------------------------------------

	C nextChar()
	{
		while (currentPos >= currentBuf.length)
		{
			if (inputDone)
				throw new Exception("Unexpected end of JSON input");
			Fiber.yield();
		}
		return currentBuf[currentPos++];
	}

	C peekChar()
	{
		while (currentPos >= currentBuf.length)
		{
			if (inputDone)
				throw new Exception("Unexpected end of JSON input (peek)");
			Fiber.yield();
		}
		return currentBuf[currentPos];
	}

	static bool isWhite(C c)
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r';
	}

	void skipWhitespace()
	{
		while (true)
		{
			while (currentPos >= currentBuf.length)
			{
				if (inputDone)
					return;
				Fiber.yield();
			}
			if (!isWhite(currentBuf[currentPos]))
				return;
			currentPos++;
		}
	}

	void expect(C c)
	{
		auto n = nextChar();
		enforce(n == c, "Expected %s, got %s".format(c, n));
	}

	// ------------------------------------------------------------------
	// Parser (procedural, yields when input needed)
	// ------------------------------------------------------------------

	void parseValue(Sink)(Sink sink)
	{
		skipWhitespace();
		C c = peekChar();
		ContainerState state = {parser: this};

		switch (c)
		{
		case '{':
			currentPos++;
			auto or_ = ObjectReader(&state);
			sink.handle(Map!(typeof(or_))(or_));
			if (!state.consumed)
			{
				DrainSink ds;
				or_(&ds);
			}
			break;
		case '[':
			currentPos++;
			auto ar = ArrayReader(&state);
			sink.handle(Array!(typeof(ar))(ar));
			if (!state.consumed)
			{
				DrainSink ds;
				ar(&ds);
			}
			break;
		default:
			parseScalar(sink, c);
			break;
		}
	}

	// Keep scalar parsing locals off the recursive container path.
	void parseScalar(Sink)(Sink sink, C c)
	{
		switch (c)
		{
		case '"':
			currentPos++;
			auto str = readWholeString();
			sink.handle(String!(typeof(str))(str));
			break;
		case 't':
			currentPos++;
			expect('r'); expect('u'); expect('e');
			sink.handle(Boolean(true));
			break;
		case 'f':
			currentPos++;
			expect('a'); expect('l'); expect('s'); expect('e');
			sink.handle(Boolean(false));
			break;
		case 'n':
			currentPos++;
			expect('u'); expect('l'); expect('l');
			sink.handle(Null());
			break;
		case '-':
		case '0': .. case '9':
			auto num = readNumeric();
			sink.handle(Numeric!(typeof(num))(num));
			break;
		default:
			throw new Exception("Unknown JSON symbol: %s".format(c));
		}
	}

	// Reader copies share the state for the current event.
	static struct ContainerState
	{
		StreamingJsonParser parser;
		bool consumed;
	}

	static struct FieldState
	{
		StreamingJsonParser parser;
		bool nameRead;
		bool valueRead;
	}

	static struct ArrayReader
	{
		ContainerState* state;

		this(ContainerState* state) { this.state = state; }

		void opCall(Sink)(Sink sink)
		{
			assert(!state.consumed);
			state.consumed = true;
			auto parser = state.parser;
			parser.skipWhitespace();
			if (parser.peekChar() == ']')
			{
				parser.currentPos++;
				return;
			}
			while (true)
			{
				parser.parseValue(sink);
				parser.skipWhitespace();
				if (parser.peekChar() == ']')
				{
					parser.currentPos++;
					return;
				}
				else
					parser.expect(',');
			}
		}
	}

	static struct ObjectReader
	{
		ContainerState* state;

		this(ContainerState* state) { this.state = state; }

		void opCall(Sink)(Sink sink)
		{
			assert(!state.consumed);
			state.consumed = true;
			auto parser = state.parser;
			parser.skipWhitespace();
			if (parser.peekChar() == '}')
			{
				parser.currentPos++;
				return;
			}

			while (true)
			{
				import ae.utils.serialization.serialization : Field;

				FieldState field = {parser: parser};
				sink.handle(Field!(NameReader, ObjectValueReader)(
					NameReader(&field), ObjectValueReader(&field)));
				if (!field.valueRead)
				{
					DrainSink ds;
					ObjectValueReader(&field)(&ds);
				}

				parser.skipWhitespace();
				if (parser.peekChar() == '}')
				{
					parser.currentPos++;
					return;
				}
				else
					parser.expect(',');
			}
		}
	}

	static struct NameReader
	{
		FieldState* state;

		this(FieldState* state) { this.state = state; }

		void opCall(Sink)(Sink sink)
		{
			assert(!state.nameRead);
			state.nameRead = true;
			auto parser = state.parser;
			import ae.utils.serialization.serialization : String;
			// JSON object keys are always strings — read directly
			// to avoid instantiating non-string handlers on key sinks.
			parser.skipWhitespace();
			parser.expect('"');
			auto str = parser.readWholeString();
			sink.handle(String!(typeof(str))(str));
		}
	}

	static struct ObjectValueReader
	{
		FieldState* state;

		this(FieldState* state) { this.state = state; }

		void opCall(Sink)(Sink sink)
		{
			assert(!state.valueRead);
			state.valueRead = true;
			if (!state.nameRead)
			{
				DrainSink ds;
				NameReader(state)(&ds);
			}
			state.parser.skipWhitespace();
			state.parser.expect(':');
			state.parser.parseValue(sink);
		}
	}

	C[] readWholeString()
	{
		C[] buf;
		while (true)
		{
			C c = nextChar();
			if (c == '"')
				return buf;
			else if (c == '\\')
			{
				C esc = nextChar();
				switch (esc)
				{
				case '"':  buf ~= '"';  break;
				case '/':  buf ~= '/';  break;
				case '\\': buf ~= '\\'; break;
				case 'b':  buf ~= '\b'; break;
				case 'f':  buf ~= '\f'; break;
				case 'n':  buf ~= '\n'; break;
				case 'r':  buf ~= '\r'; break;
				case 't':  buf ~= '\t'; break;
				case 'u':
				{
					char[4] hexBuf;
					foreach (i; 0 .. 4)
						hexBuf[i] = cast(char) nextChar();
					auto w = cast(wchar) fromHex!ushort(hexBuf);
					char[4] tmpbuf;
					auto len = encode(tmpbuf, w);
					buf ~= cast(C[]) tmpbuf[0 .. len];
					break;
				}
				default:
					throw new Exception("Unknown escape: \\%s".format(esc));
				}
			}
			else
				buf ~= c;
		}
	}

	C[] readNumeric()
	{
		C[] buf;

		static immutable bool[256] numeric = [
			'0': true, '1': true, '2': true, '3': true, '4': true,
			'5': true, '6': true, '7': true, '8': true, '9': true,
			'.': true, '-': true, '+': true, 'e': true, 'E': true,
		];

		while (true)
		{
			while (currentPos >= currentBuf.length)
			{
				if (inputDone)
					return buf;
				Fiber.yield();
			}
			if (!numeric[currentBuf[currentPos]])
				return buf;
			buf ~= currentBuf[currentPos++];
		}
	}
}

// ===========================================================================
// Unit tests
// ===========================================================================


// Single chunk -> struct
debug(ae_unittest) unittest
{
	static struct S
	{
		string name;
		int value;
	}

	S result;
	auto sink = deserializer(&result);
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(sink);
	parser.feed(`{"name":"hello","value":42}`);
	parser.endInput();

	assert(parser.done);
	assert(result.name == "hello");
	assert(result.value == 42);
}

// One char at a time
debug(ae_unittest) unittest
{
	static struct S
	{
		string name;
		int value;
	}

	S result;
	auto sink = deserializer(&result);
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(sink);

	auto json = `{"name":"hello","value":42}`;
	foreach (c; json)
		parser.feed([c]);
	parser.endInput();

	assert(parser.done);
	assert(result.name == "hello");
	assert(result.value == 42);
}

// Round-trip through JsonWriter
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonWriter;
	import ae.utils.textout : StringBuilder;

	JsonWriter!StringBuilder writer;
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(&writer);
	parser.feed(`{"name":"hello","value":42}`);
	parser.endInput();

	assert(writer.get() == `{"name":"hello","value":42}`, writer.get());
}

// Fiber parser -> SerializedObject
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;

	SerializedObject!(immutable(char)) store;
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(&store);

	auto json = `{"name":"hello","value":42}`;
	foreach (c; json)
		parser.feed([c]);
	parser.endInput();

	assert(store.type == store.Type.object);
}

// Nested structures one char at a time
debug(ae_unittest) unittest
{
	static struct Inner { int x; string s; }
	static struct Outer { string name; Inner inner; int[] arr; }

	auto json = `{"name":"test","inner":{"x":7,"s":"world"},"arr":[1,2,3]}`;

	Outer result;
	auto sink = deserializer(&result);
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(sink);

	foreach (c; json)
		parser.feed([c]);
	parser.endInput();

	assert(result.name == "test");
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
}

// Boolean, null round-trip
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonWriter;
	import ae.utils.textout : StringBuilder;

	JsonWriter!StringBuilder writer;
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(&writer);

	auto json = `{"a":true,"b":false,"c":null}`;
	foreach (c; json)
		parser.feed([c]);
	parser.endInput();

	assert(writer.get() == json, writer.get());
}

// String escapes
debug(ae_unittest) unittest
{
	static struct S { string s; }

	S result;
	auto sink = deserializer(&result);
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(sink);
	parser.feed(`{"s":"hello\nworld"}`);
	parser.endInput();

	assert(result.s == "hello\nworld");
}

// An ignored root still drains deeply nested containers through the closing delimiter.
debug(ae_unittest) unittest
{
	import std.array : replicate;

	static struct Sink
	{
		size_t events;

		void handle(V)(V value)
		{
			static if (isProtocolArray!V)
				events++;
			else
				assert(false, "Expected the root array");
			// Leave the root reader unread.
		}
	}

	Sink sink;
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(&sink);
	auto input = replicate(`[{"child":`, 17) ~ "[]" ~ replicate("}]", 17);
	parser.feed(input[0 .. $ - 1]);
	assert(!parser.done);
	parser.feed(input[$ - 1 .. $]);
	assert(parser.done);
	parser.endInput();
	assert(sink.events == 1);
}

// Empty object and array
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonWriter;
	import ae.utils.textout : StringBuilder;

	{
		JsonWriter!StringBuilder writer;
		auto parser = new StreamingJsonParser!(immutable(char));
		parser.start(&writer);
		parser.feed(`{}`);
		parser.endInput();
		assert(writer.get() == `{}`, writer.get());
	}
	{
		JsonWriter!StringBuilder writer;
		auto parser = new StreamingJsonParser!(immutable(char));
		parser.start(&writer);
		parser.feed(`[]`);
		parser.endInput();
		assert(writer.get() == `[]`, writer.get());
	}
}

// Varying chunk sizes
debug(ae_unittest) unittest
{
	static struct S
	{
		string name;
		int value;
	}

	auto json = `{"name":"hello","value":42}`;

	S result;
	auto sink = deserializer(&result);
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(sink);

	size_t i = 0;
	while (i < json.length)
	{
		auto end = i + 3;
		if (end > json.length) end = json.length;
		parser.feed(json[i .. end]);
		i = end;
	}
	parser.endInput();

	assert(result.name == "hello");
	assert(result.value == 42);
}

debug(ae_unittest) private void readTestJson(bool oneCharAtATime, Sink)(string json, Sink sink)
{
	auto parser = new StreamingJsonParser!(immutable(char));
	parser.start(sink);
	static if (oneCharAtATime)
		foreach (c; json)
			parser.feed([c]);
	else
		parser.feed(json);
	parser.endInput();
	assert(parser.done);
}

debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : toJson;

	static struct Fields
	{
		string[][string] skipped;
		string[string][] nameOnly;
		string valueOnly;
		string kept;
		string after;
	}

	static foreach (oneCharAtATime; [false, true])
	{
		{
			static void readInto(Sink)(Sink sink)
			{
				auto json = toJson(Fields(
					["nested": ["\n", "🥀"]], [["nested": "\t"]], "v", "k", "a"));
				readTestJson!oneCharAtATime(json, sink);
			}

			testFieldSkipping!readInto();
		}
	}
}

debug(ae_unittest) unittest
{
	import std.typecons : tuple;

	import ae.utils.serialization.json : toJson;

	static foreach (oneCharAtATime; [false, true])
	{
		{
			static void readInto(Sink)(Sink sink)
			{
				auto json = toJson(tuple(["\n", "🥀"], ["nested": ["\t"]], "s"));
				readTestJson!oneCharAtATime(json, sink);
			}

			testElementSkipping!readInto();
		}
	}
}
