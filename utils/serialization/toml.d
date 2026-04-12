/**
 * TOML serialization source and sink (via toml-d).
 *
 * Source/sink protocol adapters for TOML (Tom's Obvious, Minimal
 * Language). The parser (source) walks a TOMLDocument tree and emits
 * events into any sink; the writer (sink) accepts events and builds
 * a TOMLDocument.
 *
 * This module requires toml-d as a dependency. Use the `ae:toml`
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

module ae.utils.serialization.toml;

import std.conv;

import toml : TOMLDocument, TOMLValue, TOML_TYPE, parseTOML;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// TomlParser — source that reads a TOMLDocument tree
// ---------------------------------------------------------------------------

struct TomlParser
{
    /// Emit a TOML document (table) into `sink` as a Map.
    static void read(Sink)(TOMLDocument doc, Sink sink)
    {
        emitTable(doc.table, sink);
    }

    /// Emit a TOMLValue into `sink`.
    static void readValue(Sink)(TOMLValue val, Sink sink)
    {
        emitValue(val, sink);
    }
}

private void emitValue(Sink)(TOMLValue val, Sink sink)
{
    final switch (val.type)
    {
    case TOML_TYPE.STRING:
        auto s = val.str;
        sink.handle(String!(typeof(s))(s));
        break;
    case TOML_TYPE.INTEGER:
        sink.handle(Numeric!string(to!string(val.integer)));
        break;
    case TOML_TYPE.FLOAT:
        sink.handle(Numeric!string(to!string(val.floating)));
        break;
    case TOML_TYPE.TRUE:
        sink.handle(Boolean(true));
        break;
    case TOML_TYPE.FALSE:
        sink.handle(Boolean(false));
        break;
    case TOML_TYPE.OFFSET_DATETIME:
        sink.handle(String!string(val.offsetDatetime.toISOExtString()));
        break;
    case TOML_TYPE.LOCAL_DATETIME:
        sink.handle(String!string(val.localDatetime.toISOExtString()));
        break;
    case TOML_TYPE.LOCAL_DATE:
        sink.handle(String!string(val.localDate.toISOExtString()));
        break;
    case TOML_TYPE.LOCAL_TIME:
        sink.handle(String!string(val.localTime.toISOExtString()));
        break;
    case TOML_TYPE.ARRAY:
        TomlArrayReader ar = {arr: val.array};
        sink.handle(Array!(typeof(ar))(ar));
        break;
    case TOML_TYPE.TABLE:
        emitTable(val.table, sink);
        break;
    }
}

private void emitTable(Sink)(TOMLValue[string] table, Sink sink)
{
    TomlTableReader tr = {table: table};
    sink.handle(Map!(typeof(tr))(tr));
}

private struct TomlArrayReader
{
    TOMLValue[] arr;

    void opCall(Sink)(Sink sink)
    {
        foreach (ref elem; arr)
            emitValue(elem, sink);
    }
}

private struct TomlTableReader
{
    TOMLValue[string] table;

    void opCall(Sink)(Sink sink)
    {
        foreach (key, ref value; table)
        {
            ConstStringReader nr = {s: key};
            TomlValueReader vr = {val: value};
            sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
        }
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

private struct TomlValueReader
{
    TOMLValue val;

    void opCall(Sink)(Sink sink)
    {
        emitValue(val, sink);
    }
}

// ---------------------------------------------------------------------------
// TomlWriter — sink that builds a TOMLDocument
// ---------------------------------------------------------------------------

struct TomlWriter
{
    TOMLDocument result;

    void handle(V)(V v)
    {
        static if (isProtocolMap!V)
        {
            TomlTableSink ts;
            v.reader(&ts);
            result = TOMLDocument(ts.table);
        }
        else
            static assert(false, "TomlWriter: top-level must be Map, got " ~ V.stringof);
    }
}

private TOMLValue toTomlValue(V)(V v)
{
    static if (isProtocolNull!V)
        return TOMLValue(""); // TOML has no null; emit empty string
    else static if (isProtocolBoolean!V)
        return TOMLValue(v.value);
    else static if (isProtocolNumeric!V)
    {
        auto text = to!string(v.text);
        // Try integer first
        try
            return TOMLValue(to!long(text));
        catch (ConvException) {}

        try
            return TOMLValue(to!double(text));
        catch (ConvException) {}

        return TOMLValue(text);
    }
    else static if (isProtocolString!V)
        return TOMLValue(to!string(v.text));
    else static if (isProtocolArray!V)
    {
        TomlArraySink as;
        v.reader(&as);
        return TOMLValue(as.values);
    }
    else static if (isProtocolMap!V)
    {
        TomlTableSink ts;
        v.reader(&ts);
        return TOMLValue(ts.table);
    }
    else
        static assert(false, "toTomlValue: unsupported type " ~ V.stringof);
}

private struct TomlTableSink
{
    TOMLValue[string] table;

    void handle(V)(V v)
    {
        static if (isProtocolField!V)
        {
            static struct NameCapture
            {
                string name;
                void handle(VV)(VV vv)
                {
                    static if (isProtocolString!VV)
                        name = to!string(vv.text);
                    else static if (isProtocolNumeric!VV)
                        name = to!string(vv.text);
                    else
                        static assert(false, "NameCapture: unsupported key type " ~ VV.stringof);
                }
            }

            NameCapture nc;
            v.nameReader(&nc);

            static struct ValueCapture
            {
                TOMLValue result;
                void handle(VV)(VV vv)
                {
                    result = toTomlValue(vv);
                }
            }

            ValueCapture vc;
            v.valueReader(&vc);

            table[nc.name] = vc.result;
        }
        else
            static assert(false, "TomlTableSink: expected Field, got " ~ V.stringof);
    }
}

private struct TomlArraySink
{
    TOMLValue[] values;

    void handle(V)(V v)
    {
        values ~= toTomlValue(v);
    }
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse TOML text into a D value.
T parseToml(T)(string text)
{
    auto doc = parseTOML(text);
    T result;
    auto sink = deserializer(&result);
    TomlParser.read(doc, sink);
    return result;
}

/// Deserialize a D value from a TOMLDocument.
T fromTomlDoc(T)(TOMLDocument doc)
{
    T result;
    auto sink = deserializer(&result);
    TomlParser.read(doc, sink);
    return result;
}

/// Serialize a D value to a TOMLDocument.
TOMLDocument toTomlDoc(T)(auto ref T value)
{
    TomlWriter writer;
    Serializer.Impl!Object.read(&writer, value);
    return writer.result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// Simple key-value pairs
debug(ae_unittest) unittest
{
    static struct S
    {
        string name;
        int port;
    }

    auto result = parseToml!S("name = \"hello\"\nport = 8080\n");
    assert(result.name == "hello");
    assert(result.port == 8080);
}

// Boolean values
debug(ae_unittest) unittest
{
    static struct S
    {
        bool enabled;
        bool debug_;
    }

    auto result = parseToml!S("enabled = true\ndebug_ = false\n");
    assert(result.enabled == true);
    assert(result.debug_ == false);
}

// Float values
debug(ae_unittest) unittest
{
    static struct S
    {
        double pi;
        double negzero;
    }

    auto result = parseToml!S("pi = 3.14\nnegzero = -0.0\n");
    assert(result.pi > 3.13 && result.pi < 3.15);
}

// String types
debug(ae_unittest) unittest
{
    static struct S
    {
        string basic;
        string literal;
    }

    auto result = parseToml!S("basic = \"hello\\nworld\"\nliteral = 'hello\\nworld'\n");
    assert(result.basic == "hello\nworld");
    assert(result.literal == "hello\\nworld");
}

// Arrays
debug(ae_unittest) unittest
{
    static struct S
    {
        int[] ports;
        string[] tags;
    }

    auto result = parseToml!S("ports = [80, 443, 8080]\ntags = [\"web\", \"api\"]\n");
    assert(result.ports == [80, 443, 8080]);
    assert(result.tags == ["web", "api"]);
}

// Nested tables
debug(ae_unittest) unittest
{
    static struct Server
    {
        string host;
        int port;
    }
    static struct Config
    {
        Server server;
    }

    auto result = parseToml!Config("[server]\nhost = \"localhost\"\nport = 8080\n");
    assert(result.server.host == "localhost");
    assert(result.server.port == 8080);
}

// Inline tables
debug(ae_unittest) unittest
{
    static struct Point
    {
        int x;
        int y;
    }
    static struct S
    {
        Point point;
    }

    auto result = parseToml!S("point = {x = 1, y = 2}\n");
    assert(result.point.x == 1);
    assert(result.point.y == 2);
}

// Parse into SerializedObject
debug(ae_unittest) unittest
{
    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));

    auto doc = parseTOML("name = \"hello\"\nvalue = 42\n");
    SO store;
    TomlParser.read(doc, &store);
    assert(store.type == SO.Type.object);
}

// Round-trip: D struct → TOMLDocument → D struct
debug(ae_unittest) unittest
{
    static struct Inner { int x; string s; }
    static struct Outer { string name; Inner inner; }

    auto original = Outer("test", Inner(7, "world"));
    auto doc = toTomlDoc(original);
    auto result = fromTomlDoc!Outer(doc);
    assert(result.name == "test");
    assert(result.inner.x == 7);
    assert(result.inner.s == "world");
}

// Array of tables
debug(ae_unittest) unittest
{
    static struct Product
    {
        string name;
        int sku;
    }
    static struct S
    {
        Product[] products;
    }

    auto toml =
        "[[products]]\nname = \"Hammer\"\nsku = 738594937\n\n" ~
        "[[products]]\nname = \"Nail\"\nsku = 284758393\n";
    auto result = parseToml!S(toml);
    assert(result.products.length == 2);
    assert(result.products[0].name == "Hammer");
    assert(result.products[1].name == "Nail");
}

// Dotted keys
debug(ae_unittest) unittest
{
    static struct Fruit
    {
        string color;
    }
    static struct S
    {
        Fruit apple;
    }

    auto result = parseToml!S("apple.color = \"red\"\n");
    assert(result.apple.color == "red");
}
