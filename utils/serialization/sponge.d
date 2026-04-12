/**
 * Opaque serialization buffer ("sponge").
 *
 * `SerializationSponge` is a flat byte buffer that records serialization
 * protocol events and can replay them into any sink. Unlike
 * `SerializedObject`, which builds a tree of values that can be
 * inspected and mutated, the sponge is an opaque recording that is
 * more memory-efficient: a single contiguous buffer with no per-node
 * heap allocations.
 *
 * Trade-offs vs `SerializedObject`:
 * $(UL
 *   $(LI + More memory-efficient (single buffer, no tree of GC objects))
 *   $(LI + Faster to capture and replay (linear writes/reads))
 *   $(LI - Cannot be inspected, queried, or mutated)
 * )
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

module ae.utils.serialization.sponge;

import std.conv;
import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// Wire opcodes for the flat buffer
// ---------------------------------------------------------------------------

private enum Op : ubyte
{
    null_,
    true_,
    false_,
    numeric,
    string_,
    arrayBegin,
    arrayEnd,
    mapBegin,
    mapEnd,
    // Fields are implicit: inside a map, events alternate name/value.
    // No explicit field opcode needed — the map reader emits pairs.
}

// ---------------------------------------------------------------------------
// SerializationSponge — both sink and source
// ---------------------------------------------------------------------------

struct SerializationSponge
{
    // Flat buffer of opcodes and inline data.
    ubyte[] buffer;

    enum isSerializationSink = true;
    enum isSerializationSource = true;

    // ===== Sink interface =====

    void handle(V)(V v)
    {
        static if (isProtocolNull!V)
            buffer ~= Op.null_;
        else static if (isProtocolBoolean!V)
            buffer ~= v.value ? Op.true_ : Op.false_;
        else static if (isProtocolNumeric!V)
        {
            buffer ~= Op.numeric;
            putString(to!string(v.text));
        }
        else static if (isProtocolString!V)
        {
            buffer ~= Op.string_;
            putString(to!string(v.text));
        }
        else static if (isProtocolArray!V)
        {
            buffer ~= Op.arrayBegin;
            v.reader(&this);
            buffer ~= Op.arrayEnd;
        }
        else static if (isProtocolMap!V)
        {
            buffer ~= Op.mapBegin;
            MapFieldSink ms = {sponge: &this};
            v.reader(&ms);
            buffer ~= Op.mapEnd;
        }
        else
            static assert(false, "SerializationSponge: unsupported type " ~ V.stringof);
    }

    private void putString(const(char)[] s)
    {
        putLength(s.length);
        buffer ~= cast(const(ubyte)[]) s;
    }

    private void putLength(size_t len)
    {
        // Variable-length encoding: 7 bits per byte, high bit = continuation
        auto val = len;
        while (val >= 0x80)
        {
            buffer ~= cast(ubyte)(val & 0x7F | 0x80);
            val >>= 7;
        }
        buffer ~= cast(ubyte) val;
    }

    // ===== Source interface =====

    void read(Sink)(Sink sink)
    {
        size_t pos;
        readAt(sink, pos);
    }

    private void readAt(Sink)(Sink sink, ref size_t pos)
    {
        auto op = cast(Op) buffer[pos++];

        final switch (op)
        {
        case Op.null_:
            sink.handle(Null());
            break;
        case Op.true_:
            sink.handle(Boolean(true));
            break;
        case Op.false_:
            sink.handle(Boolean(false));
            break;
        case Op.numeric:
        {
            auto s = getString(pos);
            sink.handle(Numeric!string(s));
            break;
        }
        case Op.string_:
        {
            auto s = getString(pos);
            sink.handle(String!string(s));
            break;
        }
        case Op.arrayBegin:
        {
            SpongeArrayReader reader = {sponge: &this, pos: &pos};
            sink.handle(Array!(typeof(reader))(reader));
            break;
        }
        case Op.mapBegin:
        {
            SpongeMapReader reader = {sponge: &this, pos: &pos};
            sink.handle(Map!(typeof(reader))(reader));
            break;
        }
        case Op.arrayEnd:
        case Op.mapEnd:
            assert(false, "Unexpected end marker in sponge stream");
        }
    }

    private string getString(ref size_t pos)
    {
        auto len = getLength(pos);
        auto s = cast(const(char)[]) buffer[pos .. pos + len];
        pos += len;
        return s.idup;
    }

    private size_t getLength(ref size_t pos)
    {
        size_t val;
        uint shift;
        while (true)
        {
            auto b = buffer[pos++];
            val |= cast(size_t)(b & 0x7F) << shift;
            if ((b & 0x80) == 0)
                break;
            shift += 7;
        }
        return val;
    }
}

// Map fields need special handling: the reader callback receives Field
// protocol events, but we need to flatten name+value into the buffer
// without a Field opcode.
private struct MapFieldSink
{
    SerializationSponge* sponge;

    void handle(V)(V v)
    {
        static if (isProtocolField!V)
        {
            // Record the name
            v.nameReader(sponge);
            // Record the value
            v.valueReader(sponge);
        }
        else
            static assert(false, "MapFieldSink: expected Field, got " ~ V.stringof);
    }
}

private struct SpongeArrayReader
{
    SerializationSponge* sponge;
    size_t* pos;

    void opCall(Sink)(Sink sink)
    {
        while (cast(Op) sponge.buffer[*pos] != Op.arrayEnd)
            sponge.readAt(sink, *pos);
        (*pos)++; // skip arrayEnd
    }
}

private struct SpongeMapReader
{
    SerializationSponge* sponge;
    size_t* pos;

    void opCall(Sink)(Sink sink)
    {
        while (cast(Op) sponge.buffer[*pos] != Op.mapEnd)
        {
            SpongeNameReader nr = {sponge: sponge, pos: pos};
            SpongeValueReader vr = {sponge: sponge, pos: pos};
            sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
        }
        (*pos)++; // skip mapEnd
    }
}

private struct SpongeNameReader
{
    SerializationSponge* sponge;
    size_t* pos;

    void opCall(Sink)(Sink sink)
    {
        sponge.readAt(sink, *pos);
    }
}

private struct SpongeValueReader
{
    SerializationSponge* sponge;
    size_t* pos;

    void opCall(Sink)(Sink sink)
    {
        sponge.readAt(sink, *pos);
    }
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Capture a D value into a sponge.
SerializationSponge toSponge(T)(auto ref T value)
{
    SerializationSponge sponge;
    Serializer.Impl!Object.read(&sponge, value);
    return sponge;
}

/// Replay a sponge into a D value.
T fromSponge(T)(ref SerializationSponge sponge)
{
    T result;
    auto sink = deserializer(&result);
    sponge.read(sink);
    return result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// Null
debug(ae_unittest) unittest
{
    SerializationSponge sponge;
    sponge.handle(Null());
    assert(sponge.buffer == [cast(ubyte) Op.null_]);

    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));
    SO store;
    sponge.read(&store);
    assert(store.type == SO.Type.null_);
}

// Boolean
debug(ae_unittest) unittest
{
    SerializationSponge sponge;
    sponge.handle(Boolean(true));
    assert(sponge.buffer.length == 1);
    assert(fromSponge!bool(sponge) == true);
}

// Integer round-trip
debug(ae_unittest) unittest
{
    static struct S { int x; string name; }
    auto original = S(42, "hello");
    auto sponge = toSponge(original);
    auto result = fromSponge!S(sponge);
    assert(result.x == 42);
    assert(result.name == "hello");
}

// Nested struct round-trip
debug(ae_unittest) unittest
{
    static struct Inner { int a; int b; }
    static struct Outer { string name; Inner inner; }

    auto original = Outer("test", Inner(1, 2));
    auto sponge = toSponge(original);
    auto result = fromSponge!Outer(sponge);
    assert(result.name == "test");
    assert(result.inner.a == 1);
    assert(result.inner.b == 2);
}

// Array round-trip
debug(ae_unittest) unittest
{
    auto original = [10, 20, 30];
    auto sponge = toSponge(original);
    auto result = fromSponge!(int[])(sponge);
    assert(result == [10, 20, 30]);
}

// String array round-trip
debug(ae_unittest) unittest
{
    auto original = ["hello", "world"];
    auto sponge = toSponge(original);
    auto result = fromSponge!(string[])(sponge);
    assert(result == ["hello", "world"]);
}

// Complex nested round-trip
debug(ae_unittest) unittest
{
    static struct Config
    {
        string name;
        int port;
        bool enabled;
        string[] tags;
    }

    auto original = Config("server", 8080, true, ["web", "api"]);
    auto sponge = toSponge(original);
    auto result = fromSponge!Config(sponge);
    assert(result.name == "server");
    assert(result.port == 8080);
    assert(result.enabled == true);
    assert(result.tags == ["web", "api"]);
}

// Sponge is more compact than SerializedObject
debug(ae_unittest) unittest
{
    static struct S { int x; int y; int z; }
    auto sponge = toSponge(S(1, 2, 3));
    // The sponge should be a single contiguous buffer
    assert(sponge.buffer.length > 0);
    // Verify round-trip
    auto result = fromSponge!S(sponge);
    assert(result == S(1, 2, 3));
}

// Cross-format: JSON → sponge → struct
debug(ae_unittest) unittest
{
    import ae.utils.serialization.json : JsonParser;

    // Parse JSON into sponge
    SerializationSponge sponge;
    auto parser = JsonParser!()(`{"x":1,"y":2}`, 0);
    parser.read(&sponge);

    // Replay into struct
    static struct S { int x; int y; }
    auto result = fromSponge!S(sponge);
    assert(result.x == 1);
    assert(result.y == 2);
}

// Cross-format: struct → sponge → SerializedObject → struct
debug(ae_unittest) unittest
{
    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));

    static struct S { int x; string s; }
    auto sponge = toSponge(S(42, "hello"));

    // Replay into SO (which accepts all protocol types)
    SO store;
    sponge.read(&store);
    assert(store.type == SO.Type.object);

    // Then deserialize from SO
    auto result = store.deserializeTo!S();
    assert(result.x == 42);
    assert(result.s == "hello");
}

// Variable-length encoding: large string
debug(ae_unittest) unittest
{
    // String longer than 127 bytes exercises multi-byte length encoding
    char[200] buf = 'a';
    auto s = buf[].idup;
    auto sponge = toSponge(s);
    auto result = fromSponge!string(sponge);
    assert(result == s);
}
