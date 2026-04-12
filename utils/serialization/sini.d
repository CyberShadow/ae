/**
 * Structured INI — source/sink protocol implementation.
 *
 * SINI parser (source) and writer (sink) using the standard
 * serialization protocol from `ae.utils.serialization.serialization`.
 *
 * Strategy: buffer the INI into a `SerializedObject` tree, then replay.
 * INI sections map to nested objects; key=value pairs become string fields.
 * Dot-separated section names (e.g. `[server.tls]`) create nested objects.
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

module ae.utils.serialization.sini;

import std.exception;
import std.range : empty, front, popFront, isInputRange, ElementType;
import std.string;
import std.traits;

import ae.utils.serialization.serialization;
import ae.utils.serialization.store;

// ---------------------------------------------------------------------------
// SiniParser — source that parses SINI text into events
// ---------------------------------------------------------------------------

struct SiniParser
{
	alias SO = SerializedObject!(immutable(char));

	/// Parse SINI from a range of lines and push events into a sink.
	static void read(R, Sink)(R lines, Sink sink)
	{
		// Phase 1: buffer into a SerializedObject tree
		SO root;
		root.type = SO.Type.object;

		while (!lines.empty)
		{
			auto line = lines.front.chomp().stripLeft();
			lines.popFront();

			if (line.empty || line[0] == '#' || line[0] == ';')
				continue;

			if (line.startsWith("["))
			{
				line = line.stripRight();
				enforce(line[$ - 1] == ']', "Malformed section line (no ']')");
				auto sectionPath = line[1 .. $ - 1];
				auto segments = sectionPath.split(".");

				// Read key=value lines until next section or EOF
				while (!lines.empty)
				{
					auto kvLine = lines.front.chomp().stripLeft();
					if (kvLine.empty || kvLine[0] == '#' || kvLine[0] == ';')
					{
						lines.popFront();
						continue;
					}
					if (kvLine.startsWith("["))
						break; // next section

					lines.popFront();
					auto pos = kvLine.indexOf('=');
					enforce(pos > 0, "Malformed value line (no '=')");
					auto name = kvLine[0 .. pos].strip();
					auto value = kvLine[pos + 1 .. $].strip();

					auto keySegments = name.split(".");
					auto fullPath = segments ~ keySegments;
					setNestedValue(&root, fullPath, value);
				}
			}
			else
			{
				// Top-level key=value (no section header)
				auto pos = line.indexOf('=');
				enforce(pos > 0, "Malformed value line (no '=')");
				auto name = line[0 .. pos].strip();
				auto value = line[pos + 1 .. $].strip();
				auto segments = name.split(".");
				setNestedValue(&root, segments, value);
			}
		}

		// Phase 2: replay the tree into the sink
		root.read(sink);
	}

	/// Navigate into nested objects and set a string value at the leaf.
	private static void setNestedValue(S)(SO* obj, S[] path, const(char)[] value)
	{
		assert(path.length > 0);

		SO* current = obj;
		// Navigate/create intermediate objects
		foreach (segment; path[0 .. $ - 1])
		{
			auto key = cast(immutable(char)[]) segment;
			if (current.type == SO.Type.none)
				current.type = SO.Type.object;

			auto p = key in current._object;
			if (p is null)
			{
				current._object[key] = SO.init;
				current._object[key].type = SO.Type.object;
				p = key in current._object;
			}
			else if (p.type == SO.Type.none)
			{
				p.type = SO.Type.object;
			}
			current = p;
		}

		// Set the leaf value as a string
		auto leafKey = cast(immutable(char)[]) path[$ - 1];
		if (current.type == SO.Type.none)
			current.type = SO.Type.object;
		current._object[leafKey] = SO.init;
		import ae.utils.serialization.serialization : String;
		current._object[leafKey].handle(String!(typeof(value))(value));
	}
}

/// Parse SINI lines into a D struct.
T parseSini(T, R)(R lines)
	if (isInputRange!R && isSomeString!(ElementType!R))
{
	T result;
	auto sink = deserializer(&result);
	SiniParser.read(lines, sink);
	return result;
}

/// Parse SINI string into a D struct.
T parseSiniString(T)(string s)
{
	return parseSini!T(s.splitLines());
}

// ---------------------------------------------------------------------------
// SiniWriter — sink that writes SINI text
// ---------------------------------------------------------------------------

struct SiniWriter(Output)
{
	Output output;

	alias SO = SerializedObject!(immutable(char));

	void handle(V)(V v)
	{
		import ae.utils.serialization.serialization : isProtocolMap;

		static if (isProtocolMap!V)
		{
			SO store;
			store.handle(v);
			writeObjectFromStore(&store, null);
		}
		else
			static assert(false, "SINI writer expects an object at top level");
	}

	private void writeObjectFromStore(SO* obj, string prefix)
	{
		static struct FieldCollector
		{
			string[] leafNames;
			string[] leafValues;
			string[] objNames;
			SO[] objStores;

			void handle(V)(V v)
			{
				import std.conv : to;
				import ae.utils.serialization.serialization : isProtocolField,
					isProtocolNull, isProtocolBoolean, isProtocolNumeric,
					isProtocolString, isProtocolArray, isProtocolMap;

				static if (isProtocolField!V)
				{
					import ae.utils.serialization.filter : NameCaptureSink;

					NameCaptureSink ns;
					v.nameReader(&ns);

					SO val;
					v.valueReader(&val);

					if (val.type == SO.Type.object)
					{
						objNames ~= ns.name;
						objStores ~= val;
					}
					else
					{
						leafNames ~= ns.name;
						static struct StrSink
						{
							string result;
							void handle(VV)(VV vv)
							{
								import ae.utils.serialization.serialization : isProtocolNull,
									isProtocolBoolean, isProtocolNumeric, isProtocolString,
									isProtocolArray, isProtocolMap;
								static if (isProtocolString!VV)
									result = vv.text.to!string;
								else static if (isProtocolNumeric!VV)
									result = vv.text.to!string;
								else static if (isProtocolBoolean!VV)
									result = vv.value ? "true" : "false";
								else static if (isProtocolNull!VV)
									result = "";
								else static if (isProtocolArray!VV)
									result = "<array>";
								else static if (isProtocolMap!VV)
									result = "<object>";
								else
									static assert(false, "StrSink: unsupported type " ~ VV.stringof);
							}
						}
						StrSink ss;
						val.read(&ss);
						leafValues ~= ss.result;
					}
				}
				else
					static assert(false, "FieldCollector: expected Field, got " ~ V.stringof);
			}
		}

		FieldCollector fc;
		static struct ObjectExtractor
		{
			FieldCollector* fc;
			void handle(V)(V v)
			{
				import ae.utils.serialization.serialization : isProtocolMap;
				static if (isProtocolMap!V)
					v.reader(fc);
				else
					assert(false, "ObjectExtractor: expected Map, got " ~ V.stringof);
			}
		}
		ObjectExtractor ex = {fc: &fc};
		obj.read(&ex);

		if (fc.leafNames.length > 0 && prefix.length > 0)
		{
			output.put("[");
			output.put(prefix);
			output.put("]\n");
		}

		foreach (i; 0 .. fc.leafNames.length)
		{
			output.put(fc.leafNames[i]);
			output.put(" = ");
			output.put(fc.leafValues[i]);
			output.put("\n");
		}

		foreach (i; 0 .. fc.objNames.length)
		{
			auto subPrefix = prefix.length > 0
				? prefix ~ "." ~ fc.objNames[i]
				: fc.objNames[i];
			writeObjectFromStore(&fc.objStores[i], subPrefix);
		}
	}
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------


debug(ae_unittest) unittest
{
	static struct Config
	{
		static struct Server
		{
			string host;
			int port;
			static struct Tls
			{
				string enabled;
				string cert;
			}
			Tls tls;
		}
		Server server;
		static struct Logging
		{
			string level;
		}
		Logging logging;
	}

	auto ini = `[server]
host = localhost
port = 8080
[server.tls]
enabled = true
cert = /etc/cert.pem
[logging]
level = info`;

	auto cfg = parseSiniString!Config(ini);
	assert(cfg.server.host == "localhost", "got: " ~ cfg.server.host);
	assert(cfg.server.port == 8080);
	assert(cfg.server.tls.enabled == "true");
	assert(cfg.server.tls.cert == "/etc/cert.pem");
	assert(cfg.logging.level == "info");
}

debug(ae_unittest) unittest
{
	static struct S
	{
		string n1;
		static struct Inner
		{
			string n2;
		}
		Inner s;
	}

	auto ini = `n1 = v1
s.n2 = v2`;

	auto result = parseSiniString!S(ini);
	assert(result.n1 == "v1");
	assert(result.s.n2 == "v2");
}

debug(ae_unittest) unittest
{
	static struct S
	{
		string a;
		string b;
	}

	auto ini = `# comment
a = 1
; another comment

b = 2`;

	auto result = parseSiniString!S(ini);
	assert(result.a == "1");
	assert(result.b == "2");
}

debug(ae_unittest) unittest
{
	static struct File
	{
		static struct S
		{
			string n1, n2;
		}
		S s;
	}

	auto ini = `s.n1=v1
[s]
n2=v2`;

	auto result = parseSiniString!File(ini);
	assert(result.s.n1 == "v1");
	assert(result.s.n2 == "v2");
}

debug(ae_unittest) unittest
{
	static struct S
	{
		string[string] map;
	}

	auto ini = `[map]
foo = bar
baz = qux`;

	auto result = parseSiniString!S(ini);
	assert(result.map["foo"] == "bar");
	assert(result.map["baz"] == "qux");
}

debug(ae_unittest) unittest
{
	import ae.utils.serialization.store;
	alias SO = SerializedObject!(immutable(char));

	auto ini = `[server]
host = localhost
port = 8080`;

	SO store;
	SiniParser.read(ini.splitLines(), &store);
	assert(store.type == SO.Type.object);

	static struct Config
	{
		static struct Server { string host; int port; }
		Server server;
	}

	Config result;
	auto sink = deserializer(&result);
	store.read(sink);
	assert(result.server.host == "localhost");
	assert(result.server.port == 8080);
}

debug(ae_unittest) unittest
{
	import ae.utils.textout;

	static struct Config
	{
		static struct Server
		{
			string host;
			int port;
		}
		Server server;
		static struct Logging
		{
			string level;
		}
		Logging logging;
	}

	Config cfg;
	cfg.server.host = "localhost";
	cfg.server.port = 8080;
	cfg.logging.level = "info";

	SiniWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, cfg);
	auto iniOut = writer.output.get();

	auto result = parseSiniString!Config(iniOut);
	assert(result.server.host == "localhost");
	assert(result.server.port == 8080);
	assert(result.logging.level == "info");
}

debug(ae_unittest) unittest
{
	import ae.utils.textout;

	static struct Config
	{
		static struct Server
		{
			string host;
			static struct Tls
			{
				string enabled;
				string cert;
			}
			Tls tls;
		}
		Server server;
	}

	Config cfg;
	cfg.server.host = "example.com";
	cfg.server.tls.enabled = "true";
	cfg.server.tls.cert = "/etc/cert.pem";

	SiniWriter!StringBuilder writer;
	Serializer.Impl!Object.read(&writer, cfg);
	auto iniOut = writer.output.get();

	auto result = parseSiniString!Config(iniOut);
	assert(result.server.host == "example.com");
	assert(result.server.tls.enabled == "true");
	assert(result.server.tls.cert == "/etc/cert.pem");
}
