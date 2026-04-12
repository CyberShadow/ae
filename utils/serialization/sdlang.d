/**
 * SDLang serialization source (via SDLang-D).
 *
 * Source/sink protocol adapter for `sdlang.Tag`. The parser (source)
 * walks an SDLang tag tree and emits events into any sink.
 *
 * This module requires SDLang-D as a dependency. Use the `ae:sdlang`
 * dub sub-package to pull it in.
 *
 * SDLang tags map to the protocol as follows:
 * $(UL
 *   $(LI Single-value tag, no attributes, no children → value directly)
 *   $(LI Multi-value tag, no attributes, no children → repeated Fields
 *     (one per value, same key name); works with `allowRepeatedKeys`)
 *   $(LI Tag with attributes and/or children → Map with blank keys
 *     for positional values and named keys for attributes/children)
 *   $(LI No-value tag, no attributes, no children → null)
 * )
 *
 * The document root is an `SdlMap` with `allowRepeatedKeys = true`
 * and `allowBlankKeys = true`.
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

module ae.utils.serialization.sdlang;

import std.conv;
import std.exception;

import sdlang.ast;
import sdlang.parser;
import sdlang.token;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// SDLang protocol types
// ---------------------------------------------------------------------------

/// Custom Map type for SDLang that carries format-specific properties.
/// Tags can have repeated names and positional (blank-key) values.
struct SdlMap(Reader)
{
	enum isProtocolMap = true;
	enum allowRepeatedKeys = true;
	enum allowBlankKeys = true;
	Reader reader;
}

/// Custom Field type for SDLang.
struct SdlField(NR, VR)
{
	enum isProtocolField = true;
	NR nameReader;
	VR valueReader;
}

// ---------------------------------------------------------------------------
// SdlParser — source that reads an SDLang Tag tree
// ---------------------------------------------------------------------------

struct SdlParser
{
	/// Emit the contents of a root tag into `sink` as a Map.
	static void read(Sink)(Tag root, Sink sink)
	{
		TagChildrenReader reader = {tag: root};
		sink.handle(SdlMap!(typeof(reader))(reader));
	}
}

/// Emits all child tags of a Tag as Fields into a sink.
private struct TagChildrenReader
{
	Tag tag;

	void opCall(Sink)(Sink sink)
	{
		foreach (child; tag.all.tags)
			emitTag(child, sink);
	}
}

/// Emit a single SDLang Value as a protocol event.
private void emitValue(Sink)(Value val, Sink sink)
{
	if (val.peek!bool)
		sink.handle(Boolean(val.get!bool));
	else if (val.peek!(typeof(null)))
		sink.handle(Null());
	else
	{
		// Everything else (int, long, float, double, string, Date, etc.)
		// goes through string representation → Numeric or String.
		auto s = val.to!string;
		if (val.peek!int || val.peek!long)
			sink.handle(Numeric!string(s));
		else if (val.peek!float || val.peek!double || val.peek!real)
			sink.handle(Numeric!string(s));
		else
			sink.handle(String!string(s));
	}
}

/// Emit a tag as a Field (or repeated Fields) into the sink.
private void emitTag(Sink)(Tag child, Sink sink)
{
	auto hasAttrs = child.all.attributes.length > 0;
	auto hasChildren = child.all.tags.length > 0;
	auto numValues = child.values.length;

	string tagName = child.name;
	if (child.namespace != "")
		tagName = child.namespace ~ ":" ~ tagName;

	if (!hasAttrs && !hasChildren && numValues == 1)
	{
		// Simple: Field(name, value)
		ConstStringReader nr = {s: tagName};
		SingleValueReader vr = {val: child.values[0]};
		sink.handle(SdlField!(typeof(nr), typeof(vr))(nr, vr));
	}
	else if (!hasAttrs && !hasChildren && numValues > 1)
	{
		// Multi-value: emit as repeated Fields (one per value).
		foreach (val; child.values)
		{
			ConstStringReader nr = {s: tagName};
			SingleValueReader vr = {val: val};
			sink.handle(SdlField!(typeof(nr), typeof(vr))(nr, vr));
		}
	}
	else if (!hasAttrs && !hasChildren && numValues == 0)
	{
		// No content: Field(name, null)
		ConstStringReader nr = {s: tagName};
		NullReader nullr;
		sink.handle(SdlField!(typeof(nr), typeof(nullr))(nr, nullr));
	}
	else
	{
		// Complex: has attributes and/or children
		ConstStringReader nr = {s: tagName};
		TagContentReader cr = {tag: child};
		sink.handle(SdlField!(typeof(nr), typeof(cr))(nr, cr));
	}
}

private struct ConstStringReader
{
	string s;
	void opCall(Sink)(Sink sink)
	{
		sink.handle(String!string(s));
	}
}

private struct SingleValueReader
{
	Value val;
	void opCall(Sink)(Sink sink)
	{
		emitValue(val, sink);
	}
}

private struct NullReader
{
	void opCall(Sink)(Sink sink)
	{
		sink.handle(Null());
	}
}

/// Reads a complex tag's content: positional values + attributes + children.
private struct TagContentReader
{
	Tag tag;

	void opCall(Sink)(Sink sink)
	{
		TagContentMapReader mr = {tag: tag};
		sink.handle(SdlMap!(typeof(mr))(mr));
	}
}

private struct TagContentMapReader
{
	Tag tag;

	void opCall(Sink)(Sink sink)
	{
		// Positional values as blank-key fields
		foreach (val; tag.values)
		{
			ConstStringReader nr = {s: ""};
			SingleValueReader vr = {val: val};
			sink.handle(SdlField!(typeof(nr), typeof(vr))(nr, vr));
		}

		// Attributes as named fields
		foreach (attr; tag.all.attributes)
		{
			string attrName = attr.name;
			if (attr.namespace != "")
				attrName = attr.namespace ~ ":" ~ attrName;
			ConstStringReader nr = {s: attrName};
			SingleValueReader vr = {val: attr.value};
			sink.handle(SdlField!(typeof(nr), typeof(vr))(nr, vr));
		}

		// Children as named fields (emitted recursively)
		foreach (child; tag.all.tags)
			emitTag(child, sink);
	}
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse SDLang text into a D value.
T parseSdlang(T)(string text)
{
	auto root = parseSource(text);
	T result;
	auto sink = deserializer(&result);
	SdlParser.read(root, sink);
	return result;
}

/// Deserialize a D value from an SDLang Tag tree.
T fromSdlangTag(T)(Tag root)
{
	T result;
	auto sink = deserializer(&result);
	SdlParser.read(root, sink);
	return result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


// Simple scalar tags
debug(ae_unittest) unittest
{
	static struct Config
	{
		string name;
		string description;
	}

	auto result = parseSdlang!Config("name \"hello\"\ndescription \"world\"\n");
	assert(result.name == "hello");
	assert(result.description == "world");
}

// Numeric values
debug(ae_unittest) unittest
{
	static struct S
	{
		int port;
		string host;
	}

	auto result = parseSdlang!S("host \"localhost\"\nport 8080\n");
	assert(result.host == "localhost");
	assert(result.port == 8080);
}

// Boolean values
debug(ae_unittest) unittest
{
	static struct S
	{
		bool enabled;
		bool active;
	}

	auto result = parseSdlang!S("enabled true\nactive false\n");
	assert(result.enabled == true);
	assert(result.active == false);
}

// Comments
debug(ae_unittest) unittest
{
	static struct S
	{
		string name;
		int value;
	}

	auto result = parseSdlang!S(
		"// line comment\nname \"hello\"\n-- dash comment\n# hash comment\nvalue 42\n"
		~ "/* block\n   comment */\n");
	assert(result.name == "hello");
	assert(result.value == 42);
}

// Tag with children
debug(ae_unittest) unittest
{
	static struct Inner
	{
		string host;
		int port;
	}
	static struct Config
	{
		Inner server;
	}

	auto result = parseSdlang!Config("server {\n    host \"localhost\"\n    port 8080\n}\n");
	assert(result.server.host == "localhost");
	assert(result.server.port == 8080);
}

// Multi-value tag → array
debug(ae_unittest) unittest
{
	static struct Config
	{
		string[] authors;
	}

	auto result = parseSdlang!Config("authors \"Alice\" \"Bob\"\n");
	assert(result.authors == ["Alice", "Bob"]);
}

// String escapes
debug(ae_unittest) unittest
{
	static struct S
	{
		string text;
	}

	auto result = parseSdlang!S("text \"hello\\nworld\"\n");
	assert(result.text == "hello\nworld");
}

// Raw strings
debug(ae_unittest) unittest
{
	static struct S
	{
		string text;
	}

	auto result = parseSdlang!S("text `hello\\nworld`\n");
	assert(result.text == "hello\\nworld");
}

// Parse into SerializedObject
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;
	alias SO = SerializedObject!(immutable(char));

	auto root = parseSource("name \"hello\"\nvalue 42\n");
	SO store;
	SdlParser.read(root, &store);
	assert(store.type == SO.Type.object);
}

// Semicolon-separated tags on one line
debug(ae_unittest) unittest
{
	static struct S
	{
		string a;
		string b;
	}

	auto result = parseSdlang!S("a \"hello\"; b \"world\"\n");
	assert(result.a == "hello");
	assert(result.b == "world");
}

// Tag with attributes (complex tag → SdlMap)
debug(ae_unittest) unittest
{
	static struct Dep
	{
		@Positional string name;
		@SerializedAlias("version") string version_;
		string path;
	}
	static struct Config
	{
		Dep dependency;
	}

	auto result = parseSdlang!Config("dependency \"ae\" version=\"*\" path=\".\"\n");
	assert(result.dependency.name == "ae", "got: " ~ result.dependency.name);
	assert(result.dependency.version_ == "*", "got: " ~ result.dependency.version_);
	assert(result.dependency.path == ".");
}

// Repeated tags (allowRepeatedKeys) - multiple tags with same name → array
debug(ae_unittest) unittest
{
	static struct Config
	{
		string[] libs;
	}

	auto result = parseSdlang!Config("libs \"foo\"\nlibs \"bar\"\nlibs \"baz\"\n");
	assert(result.libs == ["foo", "bar", "baz"], to!string(result.libs));
}

// Nested children
debug(ae_unittest) unittest
{
	static struct Server
	{
		string host;
		int port;
	}
	static struct Logging
	{
		string level;
	}
	static struct Config
	{
		Server server;
		Logging logging;
	}

	auto result = parseSdlang!Config(
		"server {\n    host \"localhost\"\n    port 8080\n}\nlogging {\n    level \"info\"\n}\n");
	assert(result.server.host == "localhost");
	assert(result.server.port == 8080);
	assert(result.logging.level == "info");
}

// Number type suffixes
debug(ae_unittest) unittest
{
	static struct S
	{
		long bignum;
		double pi;
	}

	auto result = parseSdlang!S("bignum 123L\npi 3.14f\n");
	assert(result.bignum == 123);
	assert(result.pi > 3.13 && result.pi < 3.15);
}

// Line continuation
debug(ae_unittest) unittest
{
	static struct Config
	{
		string[] sourceFiles;
	}

	auto result = parseSdlang!Config("sourceFiles \"a.d\" \\\n    \"b.d\" \\\n    \"c.d\"\n");
	assert(result.sourceFiles == ["a.d", "b.d", "c.d"]);
}

// Dub-like integration test
debug(ae_unittest) unittest
{
	static struct SubPkg
	{
		string name;
		string targetType;
		string[] sourceFiles;
	}

	@IgnoreUnknown static struct DubLike
	{
		string name;
		string description;
		string license;
		string targetType;
		string[] sourcePaths;
		SubPkg[] subPackage;
	}

	auto sdl =
		"name \"ae\"\n" ~
		"description \"A utility library\"\n" ~
		"license \"MPL-2.0\"\n" ~
		"targetType \"library\"\n" ~
		"sourcePaths \"sys\" \"utils\" \"net\"\n" ~
		"\n" ~
		"subPackage {\n" ~
		"    name \"zlib\"\n" ~
		"    targetType \"library\"\n" ~
		"    sourceFiles \"utils/gzip.d\" \\\n" ~
		"        \"utils/zlib.d\"\n" ~
		"}\n" ~
		"\n" ~
		"subPackage {\n" ~
		"    name \"sqlite\"\n" ~
		"    targetType \"library\"\n" ~
		"    sourceFiles \"sys/database.d\" \"sys/sqlite3.d\"\n" ~
		"}\n";

	auto result = parseSdlang!DubLike(sdl);
	assert(result.name == "ae");
	assert(result.description == "A utility library");
	assert(result.license == "MPL-2.0");
	assert(result.targetType == "library");
	assert(result.sourcePaths == ["sys", "utils", "net"]);
	assert(result.subPackage.length == 2, to!string(result.subPackage.length));
	assert(result.subPackage[0].name == "zlib");
	assert(result.subPackage[0].targetType == "library");
	assert(result.subPackage[0].sourceFiles == ["utils/gzip.d", "utils/zlib.d"]);
	assert(result.subPackage[1].name == "sqlite");
	assert(result.subPackage[1].sourceFiles == ["sys/database.d", "sys/sqlite3.d"]);
}
