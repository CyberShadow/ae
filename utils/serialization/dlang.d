/**
 * D language literal sink for code generation.
 *
 * A serialization sink that produces D source code constructing the
 * serialized value as a D literal expression. Useful for compile-time
 * data embedding and code generation.
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

module ae.utils.serialization.dlang;

import std.conv;
import std.format;
import std.traits;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// DlangWriter — sink that produces D literal expressions
// ---------------------------------------------------------------------------

/// Serialization sink that writes D source code expressions.
///
/// Produces output like: `["key": "value"]`, `[1, 2, 3]`, `"hello"`,
/// `42`, `true`, `null`.
struct DlangWriter(Output)
{
	Output output;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
			output.put("null");
		else static if (isProtocolBoolean!V)
			output.put(v.value ? "true" : "false");
		else static if (isProtocolNumeric!V)
			output.put(v.text);
		else static if (isProtocolString!V)
			writeString(v.text);
		else static if (isProtocolArray!V)
		{
			output.put('[');
			DlangArraySink!(typeof(this)) as = {writer: &this, first: true};
			v.reader(&as);
			output.put(']');
		}
		else static if (isProtocolMap!V)
		{
			output.put('[');
			DlangObjectSink!(typeof(this)) os = {writer: &this, first: true};
			v.reader(&os);
			output.put(']');
		}
		else
			static assert(false, "DlangWriter: unsupported type " ~ V.stringof);
	}

	private void writeString(CC)(CC[] str)
	{
		output.put('"');
		foreach (c; str)
		{
			switch (c)
			{
			case '"':  output.put(`\"`); break;
			case '\\': output.put(`\\`); break;
			case '\n': output.put(`\n`); break;
			case '\r': output.put(`\r`); break;
			case '\t': output.put(`\t`); break;
			case '\0': output.put(`\0`); break;
			default:
				if (c < 0x20)
				{
					output.put(`\x`);
					output.put("0123456789abcdef"[c >> 4]);
					output.put("0123456789abcdef"[c & 0xf]);
				}
				else
					output.put(c);
			}
		}
		output.put('"');
	}
}

private struct DlangArraySink(Writer)
{
	Writer* writer;
	bool first;

	void handle(V)(V v)
	{
		if (!first) writer.output.put(", ");
		first = false;
		writer.handle(v);
	}
}

private struct DlangObjectSink(Writer)
{
	Writer* writer;
	bool first;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolField;

		static if (isProtocolField!V)
		{
			if (!first) writer.output.put(", ");
			first = false;

			v.nameReader(writer);
			writer.output.put(": ");
			v.valueReader(writer);
		}
		else
			static assert(false, "DlangObjectSink: expected Field, got " ~ V.stringof);
	}
}

// ---------------------------------------------------------------------------
// Convenience function
// ---------------------------------------------------------------------------

/// Serialize a D value to a D literal expression string.
string toDlang(T)(auto ref T value)
{
	import ae.utils.textout : StringBuilder;
	DlangWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, value);
	return writer.output.get();
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


// Scalars
debug(ae_unittest) unittest
{
	assert(toDlang(42) == "42");
	assert(toDlang("hello") == `"hello"`);
	assert(toDlang(true) == "true");
	assert(toDlang(false) == "false");
}

// String escaping
debug(ae_unittest) unittest
{
	assert(toDlang("a\"b") == `"a\"b"`);
	assert(toDlang("a\nb") == `"a\nb"`);
	assert(toDlang("a\\b") == `"a\\b"`);
}

// Array
debug(ae_unittest) unittest
{
	assert(toDlang([1, 2, 3]) == "[1, 2, 3]");
	assert(toDlang(["a", "b"]) == `["a", "b"]`);
}

// Struct -> AA literal
debug(ae_unittest) unittest
{
	static struct S { string name; int value; }
	auto result = toDlang(S("hello", 42));
	assert(result == `["name": "hello", "value": 42]`, result);
}

// Nested struct
debug(ae_unittest) unittest
{
	static struct Inner { int x; }
	static struct Outer { string name; Inner inner; }
	auto result = toDlang(Outer("test", Inner(7)));
	assert(result == `["name": "test", "inner": ["x": 7]]`, result);
}

// AA
debug(ae_unittest) unittest
{
	string[string] aa;
	aa["key"] = "value";
	auto result = toDlang(aa);
	assert(result == `["key": "value"]`, result);
}

// Null
debug(ae_unittest) unittest
{
	string s = null;
	assert(toDlang(s) == "null");
}

// Empty array
debug(ae_unittest) unittest
{
	int[] arr;
	assert(toDlang(arr) == "[]");
}

// Nested arrays
debug(ae_unittest) unittest
{
	assert(toDlang([[1, 2], [3, 4]]) == "[[1, 2], [3, 4]]");
}

// Float with decimal preservation
debug(ae_unittest) unittest
{
	auto result = toDlang(42.0);
	assert(result == "42.0", result);
}
