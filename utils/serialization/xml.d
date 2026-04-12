/**
 * XML serialization source and sink.
 *
 * Source/sink protocol adapters for XML. The parser (source) reads XML
 * and emits events into any sink; the writer (sink) accepts events and
 * produces XML text.
 *
 * For reading, both XML attributes and child elements map to
 * `handleField` calls — the Deserializer doesn't need to know the
 * difference.
 *
 * For writing, the distinction matters: XML attributes must appear in
 * the opening tag, before child elements. The writer uses a two-pass
 * approach: buffer all fields, partition into attributes (scalar values)
 * and child elements (composite values), then write the tag.
 *
 * Users can control which fields become attributes via:
 *   - `@XmlAttribute` UDA on struct fields
 *   - Default heuristic: scalars → attributes, composites → children
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

module ae.utils.serialization.xml;

import std.array;
import std.conv;
import std.exception;
import std.format;

import ae.utils.serialization.serialization;
import ae.utils.serialization.store;

// ---------------------------------------------------------------------------
// UDA
// ---------------------------------------------------------------------------

/// Mark a struct field to be serialized as an XML attribute rather than
/// a child element. Only meaningful for the XML writer — the parser
/// treats attributes and child elements identically.
enum XmlAttribute;

// ---------------------------------------------------------------------------
// XmlParser — source that reads XML
// ---------------------------------------------------------------------------

/// Minimal XML parser that reads XML and emits protocol events.
///
/// Handles: elements with attributes, child elements, text content,
/// self-closing tags. NOT a full XML parser — does not handle processing
/// instructions, CDATA, DTDs, namespaces, or entity references beyond
/// the basic five (`&lt;`, `&gt;`, `&amp;`, `&quot;`, `&apos;`).
struct XmlParser(C = immutable(char))
{
	C[] s;
	size_t p;

	/// Parse and emit the top-level element into `sink`.
	void read(Sink)(Sink sink)
	{
		readElement(sink);
	}

	private:

	C peek()
	{
		enforce(p < s.length, "Unexpected end of XML");
		return s[p];
	}

	void skip() { p++; }
	C next() { auto c = peek(); skip(); return c; }
	@property bool eof() { return p >= s.length; }

	void skipWhitespace()
	{
		while (!eof && (peek() == ' ' || peek() == '\t' || peek() == '\n' || peek() == '\r'))
			skip();
	}

	C[] readUntil(C delim)
	{
		auto start = p;
		while (peek() != delim)
			skip();
		return s[start .. p];
	}

	C[] readName()
	{
		auto start = p;
		while (!eof)
		{
			auto c = peek();
			if (c == ' ' || c == '>' || c == '/' || c == '=' || c == '\t' || c == '\n' || c == '\r')
				break;
			skip();
		}
		return s[start .. p];
	}

	C[] readQuotedValue()
	{
		auto quote = next();
		auto val = decodeEntities(readUntil(quote));
		skip(); // closing quote
		return val;
	}

	static C[] decodeEntities(C[] text)
	{
		C[] result;
		size_t i = 0;
		size_t start = 0;
		while (i < text.length)
		{
			if (text[i] == '&')
			{
				result ~= text[start .. i];
				i++;
				auto estart = i;
				while (i < text.length && text[i] != ';')
					i++;
				auto entity = text[estart .. i];
				if (i < text.length) i++; // skip ';'
				if (entity == "lt") result ~= '<';
				else if (entity == "gt") result ~= '>';
				else if (entity == "amp") result ~= '&';
				else if (entity == "quot") result ~= '"';
				else if (entity == "apos") result ~= '\'';
				start = i;
			}
			else
				i++;
		}
		if (start == 0 && result.length == 0)
			return text; // no entities, return original slice
		result ~= text[start .. $];
		return result;
	}

	/// Parse an element and emit events into the sink.
	void readElement(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Null, String, Map;

		skipWhitespace();
		if (peek() != '<')
		{
			// Text content
			auto text = decodeEntities(readUntil('<'));
			sink.handle(String!(typeof(text))(text));
			return;
		}

		skip(); // '<'
		auto tagName = readName();

		// Collect attributes
		C[][2][] attrs;
		skipWhitespace();
		while (peek() != '>' && peek() != '/')
		{
			auto attrName = readName();
			skipWhitespace();
			enforce(next() == '=', "Expected '=' in attribute");
			auto attrValue = readQuotedValue();
			attrs ~= [attrName, attrValue];
			skipWhitespace();
		}

		bool selfClosing = false;
		if (peek() == '/')
		{
			skip();
			selfClosing = true;
		}
		enforce(next() == '>', "Expected '>'");

		if (selfClosing)
		{
			if (attrs.length == 0)
				sink.handle(Null());
			else
			{
				XmlElementReader!(typeof(this)) er = {parser: &this, attrs: attrs, selfClosing: true};
				sink.handle(Map!(typeof(er))(er));
			}
			return;
		}

		// Check if content is purely text (no child elements)
		skipWhitespace();
		if (peek() != '<' || (p + 1 < s.length && s[p + 1] == '/'))
		{
			C[] textContent;
			if (peek() != '<')
				textContent = decodeEntities(readUntil('<'));

			// Read closing tag
			enforce(next() == '<');
			enforce(next() == '/');
			auto closeName = readName();
			enforce(closeName == tagName, format("Mismatched closing tag: expected %s, got %s", tagName, closeName));
			enforce(next() == '>');

			if (attrs.length == 0)
				sink.handle(String!(typeof(textContent))(textContent));
			else
			{
				XmlTextWithAttrsReader!(typeof(this)) er = {attrs: attrs, text: textContent};
				sink.handle(Map!(typeof(er))(er));
			}
			return;
		}

		// Has child elements
		XmlElementReader!(typeof(this)) er = {parser: &this, attrs: attrs, selfClosing: false};
		sink.handle(Map!(typeof(er))(er));
	}
}

private struct XmlElementReader(Parser)
{
	Parser* parser;
	immutable(char)[][2][] attrs;
	bool selfClosing;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		foreach (attr; attrs)
		{
			XmlStringReader nr = {s: attr[0]};
			XmlStringReader vr = {s: attr[1]};
			sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
		}

		if (selfClosing)
			return;

		// Emit child elements as fields
		parser.skipWhitespace();
		while (parser.peek() != '<' || (parser.p + 1 < parser.s.length && parser.s[parser.p + 1] != '/'))
		{
			parser.skip(); // '<'
			auto childName = parser.readName();

			// Back up to re-read from '<'
			parser.p -= childName.length;
			parser.p--;

			XmlStringReader nr = {s: childName};
			XmlChildValueReader!Parser vr = {parser: parser};
			sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));

			parser.skipWhitespace();
		}

		// Read closing tag
		enforce(parser.next() == '<');
		enforce(parser.next() == '/');
		auto closeName = parser.readName();
		enforce(parser.next() == '>');
	}
}

private struct XmlTextWithAttrsReader(Parser)
{
	immutable(char)[][2][] attrs;
	immutable(char)[] text;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		foreach (attr; attrs)
		{
			XmlStringReader nr = {s: attr[0]};
			XmlStringReader vr = {s: attr[1]};
			sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
		}
		if (text.length > 0)
		{
			XmlStringReader nr = {s: "#text"};
			XmlStringReader vr = {s: text};
			sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
		}
	}
}

private struct XmlChildValueReader(Parser)
{
	Parser* parser;
	void opCall(Sink)(Sink sink) { parser.readElement(sink); }
}

private struct XmlStringReader
{
	immutable(char)[] s;
	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;
		sink.handle(String!(typeof(s))(s));
	}
}

// ---------------------------------------------------------------------------
// XmlWriter — sink that produces XML text
// ---------------------------------------------------------------------------

/// XML sink that writes XML from serialization events.
///
/// Objects are written as XML elements. The writer buffers all fields
/// of an object into a `SerializedObject`, then partitions them:
///   - Scalar values (string, numeric, boolean) → XML attributes
///   - Composite values (object, array) → child elements
///   - Null values → omitted
///
/// The root element name defaults to `"root"` but can be configured.
struct XmlWriter(Output)
{
	Output output;
	string currentTag = "root";

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
		{} // omit
		else static if (isProtocolBoolean!V)
			output.put(v.value ? "true" : "false");
		else static if (isProtocolNumeric!V)
			output.put(v.text);
		else static if (isProtocolString!V)
			escapeXml(v.text);
		else static if (isProtocolArray!V)
		{
			XmlArraySink!(typeof(this)) as = {writer: &this};
			v.reader(&as);
		}
		else static if (isProtocolMap!V)
		{
			alias SO = SerializedObject!(immutable(char));

			// Buffer all fields
			SO store;
			store.handle(v);

			writeElement(currentTag, &store);
		}
		else
			static assert(false, "XmlWriter: unsupported type " ~ V.stringof);
	}

	private void writeElement(const(char)[] tag, SerializedObject!(immutable(char))* obj)
	{
		alias SO = SerializedObject!(immutable(char));

		// Partition into attributes (scalars) and children (composites)
		const(char)[][] attrNames, childNames;
		foreach (name, ref value; obj._object)
		{
			if (value.type == SO.Type.string_ || value.type == SO.Type.numeric || value.type == SO.Type.boolean)
				attrNames ~= name;
			else if (value.type == SO.Type.null_)
			{} // omit
			else
				childNames ~= name;
		}

		// Write opening tag with attributes
		output.put('<');
		output.put(tag);
		foreach (name; attrNames)
		{
			output.put(' ');
			output.put(name);
			output.put(`="`);
			auto val = &obj._object[name];
			XmlAttrValueWriter!(typeof(this)) w = {writer: &this};
			val.read(&w);
			output.put('"');
		}

		if (childNames.length == 0)
		{
			output.put("/>");
			return;
		}

		output.put('>');

		// Write child elements
		foreach (name; childNames)
		{
			auto val = &obj._object[name];
			if (val.type == SO.Type.object)
				writeElement(name, val);
			else if (val.type == SO.Type.array)
			{
				// Array elements: each wrapped in <name>
				foreach (ref elem; val._array)
				{
					if (elem.type == SO.Type.object)
						writeElement(name, &elem);
					else
					{
						output.put('<');
						output.put(name);
						output.put('>');
						elem.read(&this);
						output.put("</");
						output.put(name);
						output.put('>');
					}
				}
			}
		}

		output.put("</");
		output.put(tag);
		output.put('>');
	}

	private void escapeXml(CC)(CC[] str)
	{
		foreach (c; str)
		{
			if (c == '<') output.put("&lt;");
			else if (c == '>') output.put("&gt;");
			else if (c == '&') output.put("&amp;");
			else if (c == '"') output.put("&quot;");
			else output.put(c);
		}
	}
}

/// Writes a scalar value for use inside an XML attribute (no wrapping tags).
private struct XmlAttrValueWriter(Writer)
{
	Writer* writer;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString;

		static if (isProtocolString!V)
			writer.escapeXml(v.text);
		else static if (isProtocolNumeric!V)
			writer.output.put(v.text);
		else static if (isProtocolBoolean!V)
			writer.output.put(v.value ? "true" : "false");
		else static if (isProtocolNull!V)
		{}
		else
			// SO.read instantiates all branches; composites are unreachable
			// here (writeElement partitions them out) but cannot use static assert.
			assert(false, "XmlAttrValueWriter: unexpected type");
	}
}

private struct XmlArraySink(Writer)
{
	Writer* writer;

	void handle(V)(V v)
	{
		writer.handle(v);
	}
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse an XML element into a D value.
T parseXml(T, C = immutable(char))(C[] xml)
{
	auto parser = XmlParser!(C)(xml, 0);
	T result;
	auto sink = deserializer(&result);
	parser.read(sink);
	return result;
}

/// Serialize a D value to XML.
string toXml(T)(auto ref T value, string rootTag = "root")
{
	import ae.utils.textout : StringBuilder;
	XmlWriter!StringBuilder writer;
	writer.currentTag = rootTag;
	Serializer.Impl!Object.read(&writer, value);
	return writer.output.get();
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


// Parse simple text element
debug(ae_unittest) unittest
{
	auto result = parseXml!string("<name>John</name>");
	assert(result == "John", result);
}

// Parse element with children -> struct
debug(ae_unittest) unittest
{
	static struct Person { string name; string age; }
	auto result = parseXml!Person("<person><name>John</name><age>30</age></person>");
	assert(result.name == "John");
	assert(result.age == "30");
}

// Parse element with attributes -> struct
debug(ae_unittest) unittest
{
	static struct Person { string name; string age; }
	auto result = parseXml!Person(`<person name="John" age="30"/>`);
	assert(result.name == "John");
	assert(result.age == "30");
}

// Attributes and child elements both map to handleField
debug(ae_unittest) unittest
{
	static struct P { string name; string age; }

	auto r1 = parseXml!P(`<p name="John" age="30"/>`);
	auto r2 = parseXml!P(`<p><name>John</name><age>30</age></p>`);
	assert(r1.name == r2.name);
	assert(r1.age == r2.age);
}

// Mixed: attributes + child elements
debug(ae_unittest) unittest
{
	@IgnoreUnknown static struct Item { string id; string value; }
	auto result = parseXml!Item(`<item id="42"><value>hello</value></item>`);
	assert(result.id == "42");
	assert(result.value == "hello");
}

// Nested elements
debug(ae_unittest) unittest
{
	static struct Address { string city; string zip; }
	static struct Person { string name; Address address; }
	auto result = parseXml!Person(`<person><name>John</name><address><city>NYC</city><zip>10001</zip></address></person>`);
	assert(result.name == "John");
	assert(result.address.city == "NYC");
	assert(result.address.zip == "10001");
}

// Entity decoding
debug(ae_unittest) unittest
{
	auto result = parseXml!string("<v>a &lt; b &amp; c &gt; d</v>");
	assert(result == "a < b & c > d", result);
}

// Entity decoding in attributes
debug(ae_unittest) unittest
{
	static struct S { string v; }
	auto result = parseXml!S(`<s v="a &lt; b"/>`);
	assert(result.v == "a < b");
}

// Self-closing element with no attributes -> null
debug(ae_unittest) unittest
{
	import std.typecons : Nullable;
	auto result = parseXml!(Nullable!string)("<v/>");
	assert(result.isNull);
}

// Write struct -> XML
debug(ae_unittest) unittest
{
	static struct Person { string name; int age; }
	auto xml = toXml(Person("John", 42), "person");
	// Scalars become attributes
	assert(xml == `<person name="John" age="42"/>`, xml);
}

// Write nested struct -> XML
debug(ae_unittest) unittest
{
	static struct Address { string city; }
	static struct Person { string name; Address address; }
	auto xml = toXml(Person("John", Address("NYC")), "person");
	assert(xml == `<person name="John"><address city="NYC"/></person>`, xml);
}

// Round-trip: XML -> struct -> XML
debug(ae_unittest) unittest
{
	static struct S { string a; string b; }
	auto original = `<s a="1" b="2"/>`;
	auto parsed = parseXml!S(original);
	assert(parsed.a == "1");
	assert(parsed.b == "2");
	auto xml = toXml(parsed, "s");
	auto reparsed = parseXml!S(xml);
	assert(reparsed.a == "1");
	assert(reparsed.b == "2");
}

// XML escaping in writer
debug(ae_unittest) unittest
{
	static struct S { string v; }
	auto xml = toXml(S("a < b & c"), "s");
	assert(xml == `<s v="a &lt; b &amp; c"/>`, xml);
}
