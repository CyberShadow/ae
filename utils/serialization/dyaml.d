/**
 * YAML serialization source and sink (via D-YAML).
 *
 * Source/sink protocol adapters for `dyaml.Node`. The parser (source)
 * walks a YAML node tree and emits events into any sink; the writer
 * (sink) accepts events and builds a YAML node tree.
 *
 * This module requires D-YAML as a dependency. Use the `ae:dyaml`
 * dub sub-package to pull it in.
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

module ae.utils.serialization.dyaml;

import std.array;
import std.conv;
import std.exception;

import dyaml.dumper;
import dyaml.loader;
import dyaml.node;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// YamlParser — source that reads a dyaml.Node tree
// ---------------------------------------------------------------------------

struct YamlParser
{
	/// Read a YAML node tree, emitting events into `sink`.
	static void read(Sink)(Node node, Sink sink)
	{
		import ae.utils.serialization.serialization : Null, Boolean, Numeric,
			String, Array, Map;

		final switch (node.type)
		{
		case NodeType.null_:
			sink.handle(Null());
			break;
		case NodeType.boolean:
			sink.handle(Boolean(node.as!bool));
			break;
		case NodeType.integer:
			auto s = node.as!string;
			sink.handle(Numeric!(typeof(s))(s));
			break;
		case NodeType.decimal:
			auto s = node.as!string;
			sink.handle(Numeric!(typeof(s))(s));
			break;
		case NodeType.string:
			auto s = node.as!string;
			sink.handle(String!(typeof(s))(s));
			break;
		case NodeType.sequence:
			SequenceReader sr = {node: &node};
			sink.handle(Array!(typeof(sr))(sr));
			break;
		case NodeType.mapping:
			MappingReader mr = {node: &node};
			sink.handle(Map!(typeof(mr))(mr));
			break;
		case NodeType.binary:
			auto s = node.as!string;
			sink.handle(String!(typeof(s))(s));
			break;
		case NodeType.timestamp:
			auto s = node.as!string;
			sink.handle(String!(typeof(s))(s));
			break;
		case NodeType.merge:
			sink.handle(String!(string)("<<"));
			break;
		case NodeType.invalid:
			sink.handle(Null());
			break;
		}
	}
}

private struct SequenceReader
{
	Node* node;

	void opCall(Sink)(Sink sink)
	{
		foreach (ref child; node.sequence)
			YamlParser.read(child, sink);
	}
}

private struct MappingReader
{
	Node* node;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : Field;

		foreach (pair; node.mapping)
		{
			NameReader nr = {key: pair.key};
			ValueReader vr = {value: pair.value};
			sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
		}
	}
}

private struct NameReader
{
	Node key;

	void opCall(Sink)(Sink sink)
	{
		import ae.utils.serialization.serialization : String;
		auto s = key.as!string;
		sink.handle(String!(typeof(s))(s));
	}
}

private struct ValueReader
{
	Node value;

	void opCall(Sink)(Sink sink)
	{
		YamlParser.read(value, sink);
	}
}

// ---------------------------------------------------------------------------
// YamlWriter — sink that builds a dyaml.Node tree
// ---------------------------------------------------------------------------

struct YamlWriter
{
	Node result;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolNull, isProtocolBoolean,
			isProtocolNumeric, isProtocolString, isProtocolArray, isProtocolMap;

		static if (isProtocolNull!V)
			result = Node(YAMLNull());
		else static if (isProtocolBoolean!V)
			result = Node(v.value);
		else static if (isProtocolNumeric!V)
		{
			// Try integer first, then floating point, fall back to string
			try
			{
				result = Node(to!long(v.text));
				return;
			}
			catch (ConvException) {}

			try
			{
				result = Node(to!double(v.text));
				return;
			}
			catch (ConvException) {}

			result = Node(v.text.to!string);
		}
		else static if (isProtocolString!V)
			result = Node(v.text.to!string);
		else static if (isProtocolArray!V)
		{
			ArraySink as;
			v.reader(&as);
			result = Node(as.nodes);
		}
		else static if (isProtocolMap!V)
		{
			ObjectSink os;
			v.reader(&os);
			result = Node(os.pairs);
		}
		else
			static assert(false, "YamlWriter: unsupported type " ~ V.stringof);
	}
}

private struct ArraySink
{
	Node[] nodes;

	void handle(V)(V v)
	{
		YamlWriter w;
		w.handle(v);
		nodes ~= w.result;
	}
}

private struct ObjectSink
{
	Node.Pair[] pairs;

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolField;

		static if (isProtocolField!V)
		{
			static struct NameCapture
			{
				string name;

				void handle(VV)(VV vv)
				{
					import ae.utils.serialization.serialization : isProtocolString,
						isProtocolNumeric, isProtocolNull, isProtocolBoolean;
					static if (isProtocolString!VV)
						name = vv.text.to!string;
					else static if (isProtocolNumeric!VV)
						name = vv.text.to!string;
					else static if (isProtocolNull!VV)
						name = "null";
					else static if (isProtocolBoolean!VV)
						name = vv.value ? "true" : "false";
					else
						static assert(false, "NameCapture: unsupported YAML key type " ~ VV.stringof);
				}
			}

			NameCapture nc;
			v.nameReader(&nc);

			YamlWriter vw;
			v.valueReader(&vw);

			pairs ~= Node.Pair(Node(nc.name), vw.result);
		}
		else
			static assert(false, "ObjectSink: expected Field, got " ~ V.stringof);
	}
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Deserialize a D value from a YAML string.
T parseYaml(T)(string yamlText)
{
	auto loader = Loader.fromString(yamlText);
	auto node = loader.load();
	T result;
	auto sink = deserializer(&result);
	YamlParser.read(node, sink);
	return result;
}

/// Serialize a D value to a YAML string.
string toYaml(T)(auto ref T value)
{
	auto node = toYamlNode(value);
	auto d = dumper();
	auto output = new Appender!string();
	d.dump(output, node);
	return output.data;
}

/// Serialize a D value to a YAML Node.
Node toYamlNode(T)(auto ref T value)
{
	YamlWriter writer;
	Serializer.Impl!Object.read(&writer, value);
	return writer.result;
}

/// Deserialize a D value from a YAML Node.
T fromYamlNode(T)(Node node)
{
	T result;
	auto sink = deserializer(&result);
	YamlParser.read(node, sink);
	return result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


// Parse YAML mapping -> D struct
debug(ae_unittest) unittest
{
	static struct S
	{
		string name;
		int value;
	}

	auto result = parseYaml!S("name: hello\nvalue: 42\n");
	assert(result.name == "hello");
	assert(result.value == 42);
}

// Parse YAML -> SerializedObject
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;
	alias SO = SerializedObject!(immutable(char));

	auto loader = Loader.fromString("name: hello\nvalue: 42\n");
	auto node = loader.load();

	SO store;
	YamlParser.read(node, &store);
	assert(store.type == SO.Type.object);
}

// Build YAML node from D struct via YamlWriter
debug(ae_unittest) unittest
{
	static struct S
	{
		string name;
		int value;
	}

	auto node = toYamlNode(S("hello", 42));
	assert(node["name"].as!string == "hello");
	assert(node["value"].as!long == 42);
}

// Round-trip: D struct -> YAML Node -> D struct
debug(ae_unittest) unittest
{
	static struct Inner { int x; string s; }
	static struct Outer { string name; Inner inner; int[] arr; }

	Outer original;
	original.name = "test";
	original.inner.x = 7;
	original.inner.s = "world";
	original.arr = [1, 2, 3];

	auto node = toYamlNode(original);
	auto result = fromYamlNode!Outer(node);

	assert(result.name == "test");
	assert(result.inner.x == 7);
	assert(result.inner.s == "world");
	assert(result.arr == [1, 2, 3]);
}

// Boolean and null values
debug(ae_unittest) unittest
{
	import ae.utils.serialization.store : SerializedObject;
	alias SO = SerializedObject!(immutable(char));

	auto loader = Loader.fromString("[true, false, null]");
	auto node = loader.load();

	SO store;
	YamlParser.read(node, &store);
	assert(store.type == SO.Type.array);
}

// Nested YAML
debug(ae_unittest) unittest
{
	static struct Config
	{
		static struct Server
		{
			string host;
			int port;
		}
		Server server;
		string[] tags;
	}

	auto yaml = "server:\n  host: localhost\n  port: 8080\ntags:\n  - web\n  - api\n";
	auto result = parseYaml!Config(yaml);
	assert(result.server.host == "localhost");
	assert(result.server.port == 8080);
	assert(result.tags == ["web", "api"]);
}

// YAML string -> JsonWriter round-trip
debug(ae_unittest) unittest
{
	import ae.utils.serialization.json : JsonWriter;
	import ae.utils.textout : StringBuilder;

	auto loader = Loader.fromString("{name: hello, value: 42}");
	auto node = loader.load();

	JsonWriter!StringBuilder writer;
	YamlParser.read(node, &writer);

	auto json = writer.get();
	// Should contain both fields (order may vary due to YAML mapping)
	import std.algorithm.searching : canFind;
	assert(json.canFind(`"name"`), json);
	assert(json.canFind(`"hello"`), json);
	assert(json.canFind(`42`), json);
}
