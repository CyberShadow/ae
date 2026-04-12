/**
 * JSON lexer / token stream.
 *
 * Provides a streaming JSON tokenizer that preserves whitespace, enabling
 * format-preserving programmatic modifications via 3-way merge:
 *
 * 1. Lex original JSON → token stream (with whitespace)
 * 2. Parse tokens → SerializedObject
 * 3. Apply modifications to the SerializedObject
 * 4. Re-serialize → token stream (no whitespace)
 * 5. 3-way merge: original tokens + modified tokens → output
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

module ae.utils.serialization.json_lexer;

import std.conv;
import std.exception;
import std.format;
import std.utf;

import ae.utils.text : fromHex;

// ===========================================================================
// Token types
// ===========================================================================

/// JSON token types.
enum JsonTokenType
{
	objectStart,   /// {
	objectEnd,     /// }
	arrayStart,    /// [
	arrayEnd,      /// ]
	colon,         /// :
	comma,         /// ,
	string_,       /// complete string value (unescaped)
	number,        /// complete number text
	true_,         /// true
	false_,        /// false
	null_,         /// null
	whitespace,    /// whitespace between tokens (preserved for formatting)
}

/// A single JSON token.
struct JsonToken
{
	JsonTokenType type;
	const(char)[] value; /// payload: string content (unescaped), number text, or whitespace

	/// The raw source text of the token, for exact-fidelity output.
	/// For strings, this includes the quotes and escape sequences.
	/// For whitespace/structural tokens, same as value.
	const(char)[] rawValue;
}

// ===========================================================================
// StreamingJsonLexer — state-machine tokenizer
// ===========================================================================

/// Streaming JSON tokenizer. Feed arbitrary chunks of input via `feed()`.
/// Completed tokens are delivered to the `onToken` delegate.
/// Whitespace tokens are preserved for format-preserving round-trips.
struct StreamingJsonLexer
{
	void delegate(JsonToken) onToken;

	/// Feed a chunk of input. Can be any size, even 1 byte.
	void feed(const(char)[] data)
	{
		foreach (i; 0 .. data.length)
			feedChar(data[i]);
	}

	/// Signal end of input. Flushes any pending number token.
	void endInput()
	{
		if (state == State.inNumber)
		{
			emitToken(JsonToken(JsonTokenType.number, numBuf.idup, numBuf.idup));
			numBuf = null;
			state = State.value;
		}
		flushWhitespace();
	}

	/// Reset to initial state.
	void reset()
	{
		state = State.value;
		strBuf = null;
		rawBuf = null;
		numBuf = null;
		wsBuf = null;
		kwPos = 0;
		unicodePos = 0;
	}

private:
	enum State
	{
		value,
		inString,
		inEscape,
		inUnicode,
		inNumber,
		inTrue,
		inFalse,
		inNull,
	}

	State state = State.value;

	char[] strBuf;    // unescaped string content
	char[] rawBuf;    // raw string content (with quotes and escapes)
	char[] numBuf;    // number text
	char[] wsBuf;     // whitespace accumulator

	int kwPos;
	static immutable string kwTrue = "true";
	static immutable string kwFalse = "false";
	static immutable string kwNull = "null";

	char[4] unicodeBuf;
	int unicodePos;

	void emitToken(JsonToken tok)
	{
		flushWhitespace();
		if (onToken !is null)
			onToken(tok);
	}

	void flushWhitespace()
	{
		if (wsBuf.length > 0)
		{
			if (onToken !is null)
				onToken(JsonToken(JsonTokenType.whitespace, wsBuf.idup, wsBuf.idup));
			wsBuf = null;
		}
	}

	static bool isWhite(char c)
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r';
	}

	static bool isNumberChar(char c)
	{
		return (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E';
	}

	void feedChar(char c)
	{
		final switch (state)
		{
		case State.value:
			if (isWhite(c))
			{
				wsBuf ~= c;
				return;
			}
			switch (c)
			{
			case '{':
				emitToken(JsonToken(JsonTokenType.objectStart, null, "{"));
				return;
			case '}':
				emitToken(JsonToken(JsonTokenType.objectEnd, null, "}"));
				return;
			case '[':
				emitToken(JsonToken(JsonTokenType.arrayStart, null, "["));
				return;
			case ']':
				emitToken(JsonToken(JsonTokenType.arrayEnd, null, "]"));
				return;
			case ':':
				emitToken(JsonToken(JsonTokenType.colon, null, ":"));
				return;
			case ',':
				emitToken(JsonToken(JsonTokenType.comma, null, ","));
				return;
			case '"':
				state = State.inString;
				strBuf = null;
				rawBuf = null;
				rawBuf ~= '"';
				return;
			case 't':
				state = State.inTrue;
				kwPos = 1;
				return;
			case 'f':
				state = State.inFalse;
				kwPos = 1;
				return;
			case 'n':
				state = State.inNull;
				kwPos = 1;
				return;
			default:
				if (c == '-' || (c >= '0' && c <= '9'))
				{
					state = State.inNumber;
					numBuf = null;
					numBuf ~= c;
					return;
				}
				throw new Exception("Unexpected character in JSON: '%s'".format(c));
			}

		case State.inString:
			rawBuf ~= c;
			if (c == '"')
			{
				emitToken(JsonToken(JsonTokenType.string_, strBuf.idup, rawBuf.idup));
				strBuf = null;
				rawBuf = null;
				state = State.value;
			}
			else if (c == '\\')
			{
				state = State.inEscape;
			}
			else
			{
				strBuf ~= c;
			}
			return;

		case State.inEscape:
			rawBuf ~= c;
			switch (c)
			{
			case '"':  strBuf ~= '"';  state = State.inString; return;
			case '\\': strBuf ~= '\\'; state = State.inString; return;
			case '/':  strBuf ~= '/';  state = State.inString; return;
			case 'b':  strBuf ~= '\b'; state = State.inString; return;
			case 'f':  strBuf ~= '\f'; state = State.inString; return;
			case 'n':  strBuf ~= '\n'; state = State.inString; return;
			case 'r':  strBuf ~= '\r'; state = State.inString; return;
			case 't':  strBuf ~= '\t'; state = State.inString; return;
			case 'u':
				unicodePos = 0;
				state = State.inUnicode;
				return;
			default:
				throw new Exception("Unknown escape sequence: \\%s".format(c));
			}

		case State.inUnicode:
			rawBuf ~= c;
			unicodeBuf[unicodePos++] = c;
			if (unicodePos == 4)
			{
				auto w = cast(wchar) fromHex!ushort(cast(const(char)[4]) unicodeBuf);
				char[4] tmpbuf;
				auto len = encode(tmpbuf, w);
				strBuf ~= tmpbuf[0 .. len];
				state = State.inString;
			}
			return;

		case State.inNumber:
			if (isNumberChar(c))
			{
				numBuf ~= c;
			}
			else
			{
				emitToken(JsonToken(JsonTokenType.number, numBuf.idup, numBuf.idup));
				numBuf = null;
				state = State.value;
				feedChar(c); // reprocess
			}
			return;

		case State.inTrue:
			enforce(c == kwTrue[kwPos], "Expected '%s' in 'true', got '%s'".format(kwTrue[kwPos], c));
			kwPos++;
			if (kwPos == 4)
			{
				emitToken(JsonToken(JsonTokenType.true_, null, "true"));
				state = State.value;
			}
			return;

		case State.inFalse:
			enforce(c == kwFalse[kwPos], "Expected '%s' in 'false', got '%s'".format(kwFalse[kwPos], c));
			kwPos++;
			if (kwPos == 5)
			{
				emitToken(JsonToken(JsonTokenType.false_, null, "false"));
				state = State.value;
			}
			return;

		case State.inNull:
			enforce(c == kwNull[kwPos], "Expected '%s' in 'null', got '%s'".format(kwNull[kwPos], c));
			kwPos++;
			if (kwPos == 4)
			{
				emitToken(JsonToken(JsonTokenType.null_, null, "null"));
				state = State.value;
			}
			return;
		}
	}
}

// ===========================================================================
// Batch tokenization
// ===========================================================================

/// Tokenize a complete JSON string into a token array.
JsonToken[] tokenize(const(char)[] json)
{
	JsonToken[] tokens;
	StreamingJsonLexer lexer;
	lexer.onToken = (JsonToken tok) { tokens ~= tok; };
	lexer.feed(json);
	lexer.endInput();
	return tokens;
}

// ===========================================================================
// Token-to-Event converter
// ===========================================================================

/// Converts a token array into serialization protocol events.
/// Handles nested objects and arrays by creating reader callbacks.
struct TokenToEventConverter
{
	JsonToken[] tokens;

	void read(Sink)(Sink sink)
	{
		size_t pos = 0;
		readValue(sink, pos);
	}

private:
	/// Skip whitespace tokens at the current position.
	void skipWS(ref size_t pos)
	{
		while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
			pos++;
	}

	void readValue(Sink)(Sink sink, ref size_t pos)
	{
		import ae.utils.serialization.serialization : Null, Boolean, Numeric,
			String, Array, Map;

		skipWS(pos);
		enforce(pos < tokens.length, "Unexpected end of token stream");
		auto tok = tokens[pos];
		pos++;

		final switch (tok.type)
		{
		case JsonTokenType.objectStart:
			auto or_ = objectReader(&pos);
			sink.handle(Map!(typeof(or_))(or_));
			break;
		case JsonTokenType.arrayStart:
			auto ar = arrayReader(&pos);
			sink.handle(Array!(typeof(ar))(ar));
			break;
		case JsonTokenType.string_:
			sink.handle(String!(typeof(tok.value))(tok.value));
			break;
		case JsonTokenType.number:
			sink.handle(Numeric!(typeof(tok.value))(tok.value));
			break;
		case JsonTokenType.true_:
			sink.handle(Boolean(true));
			break;
		case JsonTokenType.false_:
			sink.handle(Boolean(false));
			break;
		case JsonTokenType.null_:
			sink.handle(Null());
			break;
		case JsonTokenType.whitespace:
			assert(false, "whitespace should have been skipped");
		case JsonTokenType.objectEnd:
		case JsonTokenType.arrayEnd:
		case JsonTokenType.colon:
		case JsonTokenType.comma:
			throw new Exception("Unexpected token: %s".format(tok.type));
		}
	}

	auto arrayReader(size_t* pos)
	{
		static struct ArrayReader
		{
			TokenToEventConverter* converter;
			size_t* pos;

			void opCall(ElemSink)(ElemSink sink)
			{
				converter.skipWS(*pos);
				if (*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.arrayEnd)
				{
					(*pos)++;
					return;
				}
				while (true)
				{
					converter.readValue(sink, *pos);
					converter.skipWS(*pos);
					if (*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.arrayEnd)
					{
						(*pos)++;
						return;
					}
					converter.skipWS(*pos);
					enforce(*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.comma,
						"Expected ',' or ']' in array");
					(*pos)++;
				}
			}
		}
		ArrayReader r = {converter: &this, pos: pos}; return r;
	}

	auto objectReader(size_t* pos)
	{
		static struct ObjectReader
		{
			TokenToEventConverter* converter;
			size_t* pos;

			void opCall(FieldSink)(FieldSink sink)
			{
				converter.skipWS(*pos);
				if (*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.objectEnd)
				{
					(*pos)++;
					return;
				}
				while (true)
				{
					import ae.utils.serialization.serialization : Field;
					auto nr = converter.nameReader(pos);
					auto vr = converter.valueReader(pos);
					sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));

					converter.skipWS(*pos);
					if (*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.objectEnd)
					{
						(*pos)++;
						return;
					}
					converter.skipWS(*pos);
					enforce(*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.comma,
						"Expected ',' or '}' in object");
					(*pos)++;
				}
			}
		}
		ObjectReader r = {converter: &this, pos: pos}; return r;
	}

	auto nameReader(size_t* pos)
	{
		static struct NameReader
		{
			TokenToEventConverter* converter;
			size_t* pos;

			void opCall(Sink)(Sink sink)
			{
				import ae.utils.serialization.serialization : String;
				// JSON object keys are always strings — call handle(String)
				// directly to avoid instantiating non-string handlers on
				// key-only sinks (e.g., JsonWriter's KeySink).
				converter.skipWS(*pos);
				enforce(*pos < converter.tokens.length &&
					converter.tokens[*pos].type == JsonTokenType.string_,
					"Expected string key in object");
				auto val = converter.tokens[*pos].value;
				sink.handle(String!(typeof(val))(val));
				(*pos)++;
			}
		}
		NameReader r = {converter: &this, pos: pos}; return r;
	}

	auto valueReader(size_t* pos)
	{
		static struct ValueReader
		{
			TokenToEventConverter* converter;
			size_t* pos;

			void opCall(Sink)(Sink sink)
			{
				converter.skipWS(*pos);
				enforce(*pos < converter.tokens.length && converter.tokens[*pos].type == JsonTokenType.colon,
					"Expected ':' after object key");
				(*pos)++;
				converter.readValue(sink, *pos);
			}
		}
		ValueReader r = {converter: &this, pos: pos}; return r;
	}
}

// ===========================================================================
// Token writer — reconstruct JSON from tokens
// ===========================================================================

/// Write tokens back to a string, preserving original formatting.
string tokensToString(const(JsonToken)[] tokens)
{
	import ae.utils.textout : StringBuilder;
	StringBuilder output;
	foreach (ref tok; tokens)
		output.put(tok.rawValue);
	return output.get();
}

// ===========================================================================
// Format-preserving programmatic modifications
// ===========================================================================

/// Strip whitespace tokens from a token array.
JsonToken[] stripWhitespace(const(JsonToken)[] tokens)
{
	JsonToken[] result;
	foreach (ref tok; tokens)
		if (tok.type != JsonTokenType.whitespace)
			result ~= tok;
	return result;
}

private bool tokensMatch(ref const(JsonToken) a, ref const(JsonToken) b)
{
	if (a.type != b.type) return false;
	switch (a.type)
	{
	case JsonTokenType.string_:
	case JsonTokenType.number:
		return a.value == b.value;
	default:
		return true; // structural tokens match by type alone
	}
}

/// Compute the length of one complete JSON value in a token stream,
/// starting at position 0. Returns 1 for scalars, or the full balanced
/// extent for objects/arrays (including the closing bracket).
private size_t subtreeLength(const(JsonToken)[] tokens)
{
	if (tokens.length == 0) return 0;

	auto type = tokens[0].type;
	if (type != JsonTokenType.objectStart && type != JsonTokenType.arrayStart)
		return 1; // scalar token

	auto endType = (type == JsonTokenType.objectStart)
		? JsonTokenType.objectEnd : JsonTokenType.arrayEnd;

	size_t depth = 1;
	size_t i = 1;
	while (i < tokens.length && depth > 0)
	{
		if (tokens[i].type == type)
			depth++;
		else if (tokens[i].type == endType)
			depth--;
		i++;
	}
	return i;
}

// ---------------------------------------------------------------------------
// Structure-aware merge: walk original tokens and modified SO in parallel.
//
// Instead of re-serializing the SO to JSON (which loses field order due to
// AA iteration) and doing a linear token merge, we walk the original token
// stream as a "skeleton" and pull values from the modified SO. This
// naturally preserves original formatting and field order.
// ---------------------------------------------------------------------------

private void mergeSkipWS(const(JsonToken)[] tokens, ref size_t pos)
{
	while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
		pos++;
}

/// Serialize an SO value to a flat token array (no whitespace).
private JsonToken[] soToTokens(SO)(ref SO so)
{
	import ae.utils.serialization.json : toJson;
	return stripWhitespace(tokenize(toJson(so)));
}

/// Walk original tokens and modified SO in parallel, producing merged output
/// that preserves original formatting where possible.
private void mergeSOIntoTokens(SO)(ref SO so, const(JsonToken)[] tokens, ref size_t pos, ref JsonToken[] result)
{
	// Copy leading whitespace from original
	while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
	{
		result ~= tokens[pos];
		pos++;
	}
	if (pos >= tokens.length) return;

	if (so.type == SO.Type.object && tokens[pos].type == JsonTokenType.objectStart)
	{
		mergeSOObjectIntoTokens(so, tokens, pos, result);
	}
	else if (so.type == SO.Type.array && tokens[pos].type == JsonTokenType.arrayStart)
	{
		mergeSOArrayIntoTokens(so, tokens, pos, result);
	}
	else
	{
		// Scalar or type mismatch: compare and keep original or substitute
		auto soToks = soToTokens(so);
		auto origLen = subtreeLength(tokens[pos .. $]);

		if (soToks.length == 1 && origLen == 1 && tokensMatch(tokens[pos], soToks[0]))
		{
			// Same value — keep original (preserves rawValue)
			result ~= tokens[pos];
			pos++;
		}
		else
		{
			// Different value — emit from SO, skip original
			foreach (ref t; soToks)
				result ~= t;
			pos += origLen;
		}
	}
}

private void mergeSOObjectIntoTokens(SO)(ref SO so, const(JsonToken)[] tokens, ref size_t pos, ref JsonToken[] result)
{
	// Emit {
	result ~= tokens[pos];
	pos++;

	bool firstKept = true;

	while (true)
	{
		// Collect inter-field region: whitespace, optional comma, whitespace
		size_t regionStart = pos;

		while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
			pos++;

		// Check for end of object
		if (pos >= tokens.length || tokens[pos].type == JsonTokenType.objectEnd)
		{
			// Emit trailing whitespace before }
			foreach (i; regionStart .. pos)
				result ~= tokens[i];
			break;
		}

		// Skip comma if present
		if (tokens[pos].type == JsonTokenType.comma)
			pos++;

		// Skip whitespace after comma
		while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
			pos++;

		size_t prefixEnd = pos;

		// Read key from original
		assert(tokens[pos].type == JsonTokenType.string_,
			format("Expected string key, got %s", tokens[pos].type));
		auto key = cast(immutable(char)[]) tokens[pos].value;
		auto keyPos = pos;
		pos++;

		// Whitespace before colon
		size_t wsColonStart = pos;
		while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
			pos++;

		// Colon
		assert(tokens[pos].type == JsonTokenType.colon);
		pos++;
		size_t wsColonEnd = pos;

		// Position right after colon (ws before value will be handled by recursive call)
		size_t valueRegionStart = pos;

		// Find where the value ends (for skipping deleted fields)
		size_t tempPos = pos;
		mergeSkipWS(tokens, tempPos);
		auto valueLen = subtreeLength(tokens[tempPos .. $]);
		size_t valueRegionEnd = tempPos + valueLen;

		auto pval = key in so._object;
		if (pval !is null)
		{
			// Emit separator prefix (whitespace and comma)
			if (firstKept)
			{
				// First kept field: emit only whitespace from prefix
				foreach (i; regionStart .. prefixEnd)
					if (tokens[i].type == JsonTokenType.whitespace)
						result ~= tokens[i];
			}
			else
			{
				// Subsequent kept field: emit full prefix with comma
				bool hasComma = false;
				foreach (i; regionStart .. prefixEnd)
					if (tokens[i].type == JsonTokenType.comma)
						hasComma = true;
				if (!hasComma)
					result ~= JsonToken(JsonTokenType.comma, null, ",");
				foreach (i; regionStart .. prefixEnd)
					result ~= tokens[i];
			}

			// Emit key
			result ~= tokens[keyPos];

			// Emit ws + colon
			foreach (i; wsColonStart .. wsColonEnd)
				result ~= tokens[i];

			// Recursively merge value (handles ws before value)
			pos = valueRegionStart;
			mergeSOIntoTokens(*pval, tokens, pos, result);

			firstKept = false;
		}
		else
		{
			// Field deleted — skip entirely
			pos = valueRegionEnd;
		}
	}

	// Emit }
	if (pos < tokens.length && tokens[pos].type == JsonTokenType.objectEnd)
	{
		result ~= tokens[pos];
		pos++;
	}
}

private void mergeSOArrayIntoTokens(SO)(ref SO so, const(JsonToken)[] tokens, ref size_t pos, ref JsonToken[] result)
{
	// Emit [
	result ~= tokens[pos];
	pos++;

	size_t elemIdx = 0;
	bool first = true;

	while (true)
	{
		size_t regionStart = pos;

		while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
			pos++;

		if (pos >= tokens.length || tokens[pos].type == JsonTokenType.arrayEnd)
		{
			foreach (i; regionStart .. pos)
				result ~= tokens[i];
			break;
		}

		if (tokens[pos].type == JsonTokenType.comma)
			pos++;

		while (pos < tokens.length && tokens[pos].type == JsonTokenType.whitespace)
			pos++;

		size_t prefixEnd = pos;

		if (elemIdx < so._array.length)
		{
			if (first)
			{
				foreach (i; regionStart .. prefixEnd)
					if (tokens[i].type == JsonTokenType.whitespace)
						result ~= tokens[i];
			}
			else
			{
				bool hasComma = false;
				foreach (i; regionStart .. prefixEnd)
					if (tokens[i].type == JsonTokenType.comma)
						hasComma = true;
				if (!hasComma)
					result ~= JsonToken(JsonTokenType.comma, null, ",");
				foreach (i; regionStart .. prefixEnd)
					result ~= tokens[i];
			}

			mergeSOIntoTokens(so._array[elemIdx], tokens, pos, result);
			first = false;
		}
		else
		{
			// Extra element in original (array shrunk) — skip
			mergeSkipWS(tokens, pos);
			auto vlen = subtreeLength(tokens[pos .. $]);
			pos += vlen;
		}

		elemIdx++;
	}

	// Emit ]
	if (pos < tokens.length && tokens[pos].type == JsonTokenType.arrayEnd)
	{
		result ~= tokens[pos];
		pos++;
	}
}

/// High-level: apply programmatic modifications to JSON while preserving formatting.
///
/// Parses the JSON into a `SerializedObject`, applies the modification,
/// then walks the original token stream and modified SO in parallel to
/// produce output that preserves original whitespace and field order.
string jsonModifyPreservingFormat(alias modify)(const(char)[] json)
{
	import ae.utils.serialization.store : SerializedObject;

	// 1. Lex original
	auto originalTokens = tokenize(json);

	// 2. Parse into SO
	auto converter = TokenToEventConverter(originalTokens);
	alias SO = SerializedObject!(immutable(char));
	SO so;
	converter.read(&so);

	// 3. Apply modifications
	modify(so);

	// 4. Walk original tokens and modified SO together
	JsonToken[] result;
	size_t pos = 0;
	mergeSOIntoTokens(so, originalTokens, pos, result);

	// Trailing whitespace
	while (pos < originalTokens.length && originalTokens[pos].type == JsonTokenType.whitespace)
	{
		result ~= originalTokens[pos];
		pos++;
	}

	return tokensToString(result);
}

// ===========================================================================
// Unit tests
// ===========================================================================


// Tokenizer basics
debug(ae_unittest) unittest
{
	auto tokens = tokenize(`{"name":"hello","value":42}`);
	// Filter out whitespace for this test
	auto content = stripWhitespace(tokens);
	assert(content.length == 9, format("Expected 9 tokens, got %d", content.length));
	assert(content[0].type == JsonTokenType.objectStart);
	assert(content[1].type == JsonTokenType.string_);
	assert(content[1].value == "name");
	assert(content[2].type == JsonTokenType.colon);
	assert(content[3].type == JsonTokenType.string_);
	assert(content[3].value == "hello");
	assert(content[4].type == JsonTokenType.comma);
	assert(content[7].type == JsonTokenType.number);
	assert(content[7].value == "42");
	assert(content[8].type == JsonTokenType.objectEnd);
}

// One char at a time
debug(ae_unittest) unittest
{
	JsonToken[] tokens;
	StreamingJsonLexer lexer;
	lexer.onToken = (JsonToken tok) { tokens ~= tok; };

	auto json = `{"a": 1}`;
	foreach (c; json)
		lexer.feed([c]);
	lexer.endInput();

	auto content = stripWhitespace(tokens);
	assert(content.length == 5); // { "a" : 1 }
}

// Whitespace preservation
debug(ae_unittest) unittest
{
	auto json = "{\n  \"name\" : \"hello\"\n}";
	auto tokens = tokenize(json);

	// Round-trip through tokens preserves exact formatting
	assert(tokensToString(tokens) == json);
}

// String escapes preserved in rawValue
debug(ae_unittest) unittest
{
	auto tokens = tokenize(`{"s":"hello\nworld"}`);
	auto content = stripWhitespace(tokens);
	// The string token's value is unescaped
	assert(content[3].value == "hello\nworld");
	// The rawValue preserves the original escape
	assert(content[3].rawValue == `"hello\nworld"`);
}

// Token-to-event: round-trip through deserializer
debug(ae_unittest) unittest
{
	import ae.utils.serialization.serialization : deserializer;

	auto tokens = tokenize(`{"name":"hello","value":42}`);
	auto converter = TokenToEventConverter(tokens);

	static struct S { string name; int value; }
	S result;
	auto sink = deserializer(&result);
	converter.read(sink);
	assert(result.name == "hello");
	assert(result.value == 42);
}

// Token-to-event: nested structures
debug(ae_unittest) unittest
{
	import ae.utils.serialization.serialization : deserializer;

	static struct Inner { int x; string s; }
	static struct Outer { string name; Inner inner; int[] arr; }

	auto json = `{"name":"test","inner":{"x":7,"s":"world"},"arr":[1,2,3]}`;
	auto tokens = tokenize(json);
	auto converter = TokenToEventConverter(tokens);

	Outer result;
	auto sink = deserializer(&result);
	converter.read(sink);
	assert(result.name == "test");
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
}

// Token-to-event: round-trip through JsonWriter
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonWriter;
	import ae.utils.textout : StringBuilder;

	auto json = `{"name":"hello","value":42}`;
	auto tokens = tokenize(json);
	auto converter = TokenToEventConverter(tokens);

	JsonWriter!StringBuilder writer;
	converter.read(&writer);
	assert(writer.get() == json, writer.get());
}

// Pretty-printed JSON round-trip through tokens
debug(ae_unittest) unittest
{
	auto json = "{\n  \"name\": \"hello\",\n  \"value\": 42\n}";
	auto tokens = tokenize(json);
	assert(tokensToString(tokens) == json);
}

// 3-way merge: unchanged document
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;
	alias SO = SerializedObject!(immutable(char));

	auto json = "{\n  \"name\": \"hello\",\n  \"value\": 42\n}";
	auto result = jsonModifyPreservingFormat!(
		(ref SO so) { /* no modifications */ }
	)(json);
	assert(result == json, result);
}

// 3-way merge: modify a value
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;
	alias SO = SerializedObject!(immutable(char));

	auto json = "{\n  \"name\": \"hello\",\n  \"value\": 42\n}";
	auto result = jsonModifyPreservingFormat!(
		(ref SO so) {
			import ae.utils.serialization.serialization : Numeric;
			so["value"] = SO.init;
			so["value"].handle(Numeric!(string)("99"));
		}
	)(json);

	// The formatting around "name" should be preserved
	assert(result.canFind(`"name": "hello"`), result);
	// The value should be changed
	assert(result.canFind("99"), result);
}

private bool canFind(string haystack, string needle)
{
	import std.algorithm.searching : canFind;
	return haystack.canFind(needle);
}

// 3-way merge: modify a string value
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;
	alias SO = SerializedObject!(immutable(char));

	auto json = "{\n  \"name\":   \"hello\",\n  \"value\": 42\n}";
	auto result = jsonModifyPreservingFormat!(
		(ref SO so) {
			import ae.utils.serialization.serialization : String;
			so["name"] = SO.init;
			so["name"].handle(String!(string)("world"));
		}
	)(json);

	// Value 42 should still have its formatting
	assert(result.canFind(`"value": 42`), result);
	// Name should be changed
	assert(result.canFind(`"world"`), result);
}
