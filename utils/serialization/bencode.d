/**
 * Bencode serialization source and sink.
 *
 * Bencode (BitTorrent encoding) has four types:
 * - Integers: i42e
 * - Byte strings: 4:spam
 * - Lists: l...e
 * - Dictionaries: d...e (keys are byte strings, sorted)
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

module ae.utils.serialization.bencode;

import std.conv;
import std.exception;
import std.format;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// BencodeParser -- source that parses bencode
// ---------------------------------------------------------------------------

struct BencodeParser(C = immutable(char))
{
	C[] s;
	size_t p;

	C next()
	{
		enforce(p < s.length, "Unexpected end of bencode input");
		return s[p++];
	}

	C peek()
	{
		enforce(p < s.length, "Unexpected end of bencode input");
		return s[p];
	}

	void skip() { p++; }

	@property bool eof() { return p >= s.length; }

	void read(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Numeric, String, Array, Map;

		auto c = peek();
		if (c == 'i')
		{
			skip(); // skip 'i'
			auto start = p;
			while (peek() != 'e')
				skip();
			auto num = s[start .. p];
			sink.handle(Numeric!(typeof(num))(num));
			skip(); // skip 'e'
		}
		else if (c >= '0' && c <= '9')
		{
			auto str = readString();
			sink.handle(String!(typeof(str))(str));
		}
		else if (c == 'l')
		{
			skip(); // skip 'l'
			ListReader!(typeof(this)) lr = {parser: &this};
			sink.handle(Array!(typeof(lr))(lr));
		}
		else if (c == 'd')
		{
			skip(); // skip 'd'
			DictReader!(typeof(this)) dr = {parser: &this};
			sink.handle(Map!(typeof(dr))(dr));
		}
		else
			throw new Exception("Invalid bencode character: %s".format(c));
	}

	C[] readString()
	{
		auto start = p;
		while (peek() != ':')
			skip();
		auto len = to!size_t(s[start .. p]);
		skip(); // skip ':'
		auto end = p + len;
		enforce(end <= s.length, "Bencode string extends past end of input");
		auto result = s[p .. end];
		p = end;
		return result;
	}
}

private struct ListReader(Parser)
{
	Parser* parser;

	void opCall(Sink)(Sink sink)
	{
		while (parser.peek() != 'e')
			parser.read(sink);
		parser.skip(); // skip 'e'
	}
}

private struct DictReader(Parser)
{
	Parser* parser;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		while (parser.peek() != 'e')
		{
			DictKeyReader!Parser kr = {parser: parser};
			DictValueReader!Parser vr = {parser: parser};
			sink.handle(Field!(typeof(kr), typeof(vr))(kr, vr));
		}
		parser.skip(); // skip 'e'
	}
}

private struct DictKeyReader(Parser)
{
	Parser* parser;
	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;
		auto str = parser.readString();
		sink.handle(String!(typeof(str))(str));
	}
}

private struct DictValueReader(Parser)
{
	Parser* parser;
	void opCall(Sink)(Sink sink)
	{
		parser.read(sink);
	}
}

// ---------------------------------------------------------------------------
// BencodeWriter -- sink that writes bencode
// ---------------------------------------------------------------------------

struct BencodeWriter(Output)
{
	Output output;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
			output.put("0:");
		else static if (isProtocolBoolean!V)
			output.put(v.value ? "i1e" : "i0e");
		else static if (isProtocolNumeric!V)
		{
			output.put('i');
			output.put(v.text);
			output.put('e');
		}
		else static if (isProtocolString!V)
		{
			import ae.utils.text : toDec, decimalSize;
			auto len = v.text.length;
			char[decimalSize!size_t] buf = void;
			output.put(toDec(len, buf));
			output.put(':');
			output.put(v.text);
		}
		else static if (isProtocolArray!V)
		{
			output.put('l');
			v.reader(&this);
			output.put('e');
		}
		else static if (isProtocolMap!V)
		{
			output.put('d');
			BencodeFieldSink!(typeof(this)) fs = {writer: &this};
			v.reader(&fs);
			output.put('e');
		}
		else
			static assert(false, "BencodeWriter: unsupported type " ~ V.stringof);
	}
}

private struct BencodeFieldSink(Writer)
{
	Writer* writer;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolField;

		static if (isProtocolField!V)
		{
			v.nameReader(writer);
			v.valueReader(writer);
		}
		else
			static assert(false, "BencodeFieldSink: expected Field, got " ~ V.stringof);
	}
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


debug(ae_unittest) unittest
{
	auto parser = BencodeParser!(immutable(char))("i42e", 0);
	int result;
	auto sink = deserializer(&result);
	parser.read(sink);
	assert(result == 42);
}

debug(ae_unittest) unittest
{
	auto parser = BencodeParser!(immutable(char))("i-7e", 0);
	int result;
	auto sink = deserializer(&result);
	parser.read(sink);
	assert(result == -7);
}

debug(ae_unittest) unittest
{
	auto parser = BencodeParser!(immutable(char))("4:spam", 0);
	string result;
	auto sink = deserializer(&result);
	parser.read(sink);
	assert(result == "spam");
}

debug(ae_unittest) unittest
{
	auto parser = BencodeParser!(immutable(char))("li1ei2ei3ee", 0);
	int[] result;
	auto sink = deserializer(&result);
	parser.read(sink);
	assert(result == [1, 2, 3]);
}

debug(ae_unittest) unittest
{
	static struct Torrent
	{
		string name;
		int length;
	}

	auto parser = BencodeParser!(immutable(char))("d6:lengthi42e4:name4:teste", 0);
	Torrent result;
	auto sink = deserializer(&result);
	parser.read(sink);
	assert(result.name == "test");
	assert(result.length == 42);
}

debug(ae_unittest) unittest
{
	auto input = "d5:filesl4:a.tx4:b.txe4:infod6:lengthi100e4:name4:testee";
	auto parser = BencodeParser!(immutable(char))(input, 0);

	static struct Info { string name; int length; }
	static struct Meta { string[] files; Info info; }

	Meta result;
	auto sink = deserializer(&result);
	parser.read(sink);
	assert(result.files == ["a.tx", "b.tx"]);
	assert(result.info.name == "test");
	assert(result.info.length == 100);
}

debug(ae_unittest) unittest
{
	import ae.utils.textout;

	BencodeWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, 42);
	assert(writer.output.get() == "i42e");
}

debug(ae_unittest) unittest
{
	import ae.utils.textout;

	BencodeWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, "spam");
	assert(writer.output.get() == "4:spam");
}

debug(ae_unittest) unittest
{
	import ae.utils.textout;

	BencodeWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, [1, 2, 3]);
	assert(writer.output.get() == "li1ei2ei3ee");
}

debug(ae_unittest) unittest
{
	import ae.utils.textout;

	static struct S { string name; int age; }

	S original = S("John", 30);

	BencodeWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, original);
	auto encoded = writer.output.get();

	auto parser = BencodeParser!(immutable(char))(encoded, 0);
	S result;
	auto sink = deserializer(&result);
	parser.read(sink);

	assert(result.name == "John");
	assert(result.age == 30);
}
