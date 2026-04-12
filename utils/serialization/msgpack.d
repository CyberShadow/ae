/**
 * MessagePack serialization source and sink.
 *
 * Source/sink protocol adapters for MessagePack, a compact binary
 * serialization format. The parser (source) reads MessagePack bytes
 * and emits events into any sink; the writer (sink) accepts events
 * and produces MessagePack bytes.
 *
 * This module has no external dependencies — the MessagePack wire
 * format is implemented directly.
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

module ae.utils.serialization.msgpack;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.conv;
import std.exception;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// MsgpackParser — source that reads MessagePack bytes
// ---------------------------------------------------------------------------

struct MsgpackParser
{
    const(ubyte)[] data;
    size_t p;

    /// Parse a MessagePack value and emit events into sink.
    void read(Sink)(Sink sink)
    {
        enforce(p < data.length, "Unexpected end of MessagePack input");
        auto b = data[p++];

        // positive fixint: 0x00..0x7f
        if (b <= 0x7F)
        {
            sink.handle(Numeric!string(to!string(b)));
            return;
        }

        // fixmap: 0x80..0x8f
        if ((b & 0xF0) == 0x80)
        {
            readMap(b & 0x0F, sink);
            return;
        }

        // fixarray: 0x90..0x9f
        if ((b & 0xF0) == 0x90)
        {
            readArray(b & 0x0F, sink);
            return;
        }

        // fixstr: 0xa0..0xbf
        if ((b & 0xE0) == 0xA0)
        {
            auto len = b & 0x1F;
            auto str = readString(len);
            sink.handle(String!(const(char)[])(str));
            return;
        }

        // negative fixint: 0xe0..0xff
        if (b >= 0xE0)
        {
            auto val = cast(byte) b;
            sink.handle(Numeric!string(to!string(val)));
            return;
        }

        switch (b)
        {
        // nil
        case 0xC0:
            sink.handle(Null());
            break;

        // (never used)
        case 0xC1:
            throw new Exception("MessagePack: reserved format 0xC1");

        // boolean
        case 0xC2:
            sink.handle(Boolean(false));
            break;
        case 0xC3:
            sink.handle(Boolean(true));
            break;

        // bin 8/16/32
        case 0xC4:
            emitBin(readByte(), sink);
            break;
        case 0xC5:
            emitBin(read16(), sink);
            break;
        case 0xC6:
            emitBin(read32(), sink);
            break;

        // ext 8/16/32 — skip type byte, emit data as hex string
        case 0xC7:
        {
            auto len = readByte();
            p++; // skip type
            emitBin(len, sink);
            break;
        }
        case 0xC8:
        {
            auto len = read16();
            p++; // skip type
            emitBin(len, sink);
            break;
        }
        case 0xC9:
        {
            auto len = read32();
            p++; // skip type
            emitBin(len, sink);
            break;
        }

        // float 32
        case 0xCA:
        {
            auto bytes = readBytes(4);
            float val = bigEndianToNative!float(bytes[0 .. 4]);
            sink.handle(Numeric!string(to!string(val)));
            break;
        }

        // float 64
        case 0xCB:
        {
            auto bytes = readBytes(8);
            double val = bigEndianToNative!double(bytes[0 .. 8]);
            sink.handle(Numeric!string(to!string(val)));
            break;
        }

        // uint 8/16/32/64
        case 0xCC:
            sink.handle(Numeric!string(to!string(readByte())));
            break;
        case 0xCD:
            sink.handle(Numeric!string(to!string(read16())));
            break;
        case 0xCE:
            sink.handle(Numeric!string(to!string(read32())));
            break;
        case 0xCF:
            sink.handle(Numeric!string(to!string(read64())));
            break;

        // int 8/16/32/64
        case 0xD0:
            sink.handle(Numeric!string(to!string(cast(byte) readByte())));
            break;
        case 0xD1:
            sink.handle(Numeric!string(to!string(cast(short) read16())));
            break;
        case 0xD2:
            sink.handle(Numeric!string(to!string(cast(int) read32())));
            break;
        case 0xD3:
            sink.handle(Numeric!string(to!string(cast(long) read64())));
            break;

        // fixext 1/2/4/8/16 — skip type byte, emit data as bin
        case 0xD4:
            p++; // skip type
            emitBin(1, sink);
            break;
        case 0xD5:
            p++; // skip type
            emitBin(2, sink);
            break;
        case 0xD6:
            p++; // skip type
            emitBin(4, sink);
            break;
        case 0xD7:
            p++; // skip type
            emitBin(8, sink);
            break;
        case 0xD8:
            p++; // skip type
            emitBin(16, sink);
            break;

        // str 8/16/32
        case 0xD9:
        {
            auto str = readString(readByte());
            sink.handle(String!(const(char)[])(str));
            break;
        }
        case 0xDA:
        {
            auto str = readString(read16());
            sink.handle(String!(const(char)[])(str));
            break;
        }
        case 0xDB:
        {
            auto str = readString(read32());
            sink.handle(String!(const(char)[])(str));
            break;
        }

        // array 16/32
        case 0xDC:
            readArray(read16(), sink);
            break;
        case 0xDD:
            readArray(read32(), sink);
            break;

        // map 16/32
        case 0xDE:
            readMap(read16(), sink);
            break;
        case 0xDF:
            readMap(read32(), sink);
            break;

        default:
            throw new Exception("MessagePack: unknown format byte 0x" ~ to!string(b, 16));
        }
    }

    private void readArray(Sink)(size_t count, Sink sink)
    {
        MsgpackArrayReader reader = {parser: &this, remaining: count};
        sink.handle(Array!(typeof(reader))(reader));
    }

    private void readMap(Sink)(size_t count, Sink sink)
    {
        MsgpackMapReader reader = {parser: &this, remaining: count};
        sink.handle(Map!(typeof(reader))(reader));
    }

    private void emitBin(Sink)(size_t len, Sink sink)
    {
        auto bytes = readBytes(len);
        // Emit binary as array of numeric bytes
        MsgpackBinReader reader = {bytes: bytes};
        sink.handle(Array!(typeof(reader))(reader));
    }

    private ubyte readByte()
    {
        enforce(p < data.length, "Unexpected end of MessagePack input");
        return data[p++];
    }

    private ushort read16()
    {
        auto bytes = readBytes(2);
        return bigEndianToNative!ushort(bytes[0 .. 2]);
    }

    private uint read32()
    {
        auto bytes = readBytes(4);
        return bigEndianToNative!uint(bytes[0 .. 4]);
    }

    private ulong read64()
    {
        auto bytes = readBytes(8);
        return bigEndianToNative!ulong(bytes[0 .. 8]);
    }

    private const(ubyte)[] readBytes(size_t n)
    {
        enforce(p + n <= data.length, "Unexpected end of MessagePack input");
        auto result = data[p .. p + n];
        p += n;
        return result;
    }

    private const(char)[] readString(size_t len)
    {
        return cast(const(char)[]) readBytes(len);
    }
}

private struct MsgpackArrayReader
{
    MsgpackParser* parser;
    size_t remaining;

    void opCall(Sink)(Sink sink)
    {
        foreach (_; 0 .. remaining)
            parser.read(sink);
    }
}

private struct MsgpackMapReader
{
    MsgpackParser* parser;
    size_t remaining;

    void opCall(Sink)(Sink sink)
    {
        foreach (_; 0 .. remaining)
        {
            MsgpackKeyReader kr = {parser: parser};
            MsgpackValueReader vr = {parser: parser};
            sink.handle(Field!(typeof(kr), typeof(vr))(kr, vr));
        }
    }
}

private struct MsgpackKeyReader
{
    MsgpackParser* parser;
    void opCall(Sink)(Sink sink) { parser.read(sink); }
}

private struct MsgpackValueReader
{
    MsgpackParser* parser;
    void opCall(Sink)(Sink sink) { parser.read(sink); }
}

private struct MsgpackBinReader
{
    const(ubyte)[] bytes;

    void opCall(Sink)(Sink sink)
    {
        foreach (b; bytes)
            sink.handle(Numeric!string(to!string(b)));
    }
}

// ---------------------------------------------------------------------------
// MsgpackWriter — sink that produces MessagePack bytes
// ---------------------------------------------------------------------------

struct MsgpackWriter
{
    ubyte[] result;

    void handle(V)(V v)
    {
        result = encodeValue(v);
    }

    static ubyte[] encodeValue(V)(V v)
    {
        static if (isProtocolNull!V)
        {
            return [0xC0];
        }
        else static if (isProtocolBoolean!V)
        {
            return [v.value ? cast(ubyte) 0xC3 : cast(ubyte) 0xC2];
        }
        else static if (isProtocolNumeric!V)
        {
            auto text = to!string(v.text);
            // Try integer first
            try
            {
                auto val = to!long(text);
                return encodeInt(val);
            }
            catch (ConvException) {}

            // Fall back to float64
            try
            {
                auto dval = to!double(text);
                ubyte[] result;
                result ~= 0xCB;
                result ~= nativeToBigEndian(dval)[];
                return result;
            }
            catch (ConvException) {}

            // Last resort: encode as string
            return encodeStr(text);
        }
        else static if (isProtocolString!V)
        {
            return encodeStr(to!string(v.text));
        }
        else static if (isProtocolArray!V)
        {
            MsgpackArrayCollector ac;
            v.reader(&ac);

            ubyte[] result = encodeArrayHeader(ac.items.length);
            foreach (ref item; ac.items)
                result ~= item;
            return result;
        }
        else static if (isProtocolMap!V)
        {
            MsgpackMapCollector mc;
            v.reader(&mc);

            ubyte[] result = encodeMapHeader(mc.pairs.length);
            foreach (ref pair; mc.pairs)
                result ~= pair;
            return result;
        }
        else
            static assert(false, "MsgpackWriter: unsupported type " ~ V.stringof);
    }

    static ubyte[] encodeInt(long val)
    {
        // positive fixint
        if (val >= 0 && val <= 0x7F)
            return [cast(ubyte) val];

        // negative fixint
        if (val >= -32 && val < 0)
            return [cast(ubyte) val];

        // uint 8
        if (val >= 0 && val <= ubyte.max)
            return [0xCC, cast(ubyte) val];

        // uint 16
        if (val >= 0 && val <= ushort.max)
        {
            ubyte[] result;
            result ~= 0xCD;
            result ~= nativeToBigEndian(cast(ushort) val)[];
            return result;
        }

        // uint 32
        if (val >= 0 && val <= uint.max)
        {
            ubyte[] result;
            result ~= 0xCE;
            result ~= nativeToBigEndian(cast(uint) val)[];
            return result;
        }

        // uint 64
        if (val >= 0)
        {
            ubyte[] result;
            result ~= 0xCF;
            result ~= nativeToBigEndian(cast(ulong) val)[];
            return result;
        }

        // int 8
        if (val >= byte.min)
            return [0xD0, cast(ubyte) cast(byte) val];

        // int 16
        if (val >= short.min)
        {
            ubyte[] result;
            result ~= 0xD1;
            result ~= nativeToBigEndian(cast(short) val)[];
            return result;
        }

        // int 32
        if (val >= int.min)
        {
            ubyte[] result;
            result ~= 0xD2;
            result ~= nativeToBigEndian(cast(int) val)[];
            return result;
        }

        // int 64
        {
            ubyte[] result;
            result ~= 0xD3;
            result ~= nativeToBigEndian(val)[];
            return result;
        }
    }

    static ubyte[] encodeStr(string s)
    {
        ubyte[] result;
        auto len = s.length;

        if (len <= 31)
            result ~= cast(ubyte)(0xA0 | len);
        else if (len <= ubyte.max)
            result ~= [cast(ubyte) 0xD9, cast(ubyte) len];
        else if (len <= ushort.max)
        {
            result ~= 0xDA;
            result ~= nativeToBigEndian(cast(ushort) len)[];
        }
        else
        {
            result ~= 0xDB;
            result ~= nativeToBigEndian(cast(uint) len)[];
        }

        result ~= cast(const(ubyte)[]) s;
        return result;
    }

    static ubyte[] encodeArrayHeader(size_t count)
    {
        if (count <= 15)
            return [cast(ubyte)(0x90 | count)];
        else if (count <= ushort.max)
        {
            ubyte[] result;
            result ~= 0xDC;
            result ~= nativeToBigEndian(cast(ushort) count)[];
            return result;
        }
        else
        {
            ubyte[] result;
            result ~= 0xDD;
            result ~= nativeToBigEndian(cast(uint) count)[];
            return result;
        }
    }

    static ubyte[] encodeMapHeader(size_t count)
    {
        if (count <= 15)
            return [cast(ubyte)(0x80 | count)];
        else if (count <= ushort.max)
        {
            ubyte[] result;
            result ~= 0xDE;
            result ~= nativeToBigEndian(cast(ushort) count)[];
            return result;
        }
        else
        {
            ubyte[] result;
            result ~= 0xDF;
            result ~= nativeToBigEndian(cast(uint) count)[];
            return result;
        }
    }
}

private struct MsgpackArrayCollector
{
    ubyte[][] items;

    void handle(V)(V v)
    {
        items ~= MsgpackWriter.encodeValue(v);
    }
}

private struct MsgpackMapCollector
{
    ubyte[][] pairs;

    void handle(V)(V v)
    {
        static if (isProtocolField!V)
        {
            MsgpackWriter kw, vw;
            v.nameReader(&kw);
            v.valueReader(&vw);
            ubyte[] pair;
            pair ~= kw.result;
            pair ~= vw.result;
            pairs ~= pair;
        }
        else
            static assert(false, "MsgpackMapCollector: expected Field, got " ~ V.stringof);
    }
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse MessagePack bytes into a D value.
T parseMsgpack(T)(const(ubyte)[] data)
{
    auto parser = MsgpackParser(data, 0);
    T result;
    auto sink = deserializer(&result);
    parser.read(sink);
    return result;
}

/// Serialize a D value to MessagePack bytes.
ubyte[] toMsgpack(T)(auto ref T value)
{
    MsgpackWriter writer;
    Serializer.Impl!Object.read(&writer, value);
    return writer.result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// Positive fixint
debug(ae_unittest) unittest
{
    assert(parseMsgpack!int([0x00]) == 0);
    assert(parseMsgpack!int([0x01]) == 1);
    assert(parseMsgpack!int([0x7F]) == 127);
}

// Negative fixint
debug(ae_unittest) unittest
{
    assert(parseMsgpack!int([0xFF]) == -1);
    assert(parseMsgpack!int([0xE0]) == -32);
}

// uint 8/16/32/64
debug(ae_unittest) unittest
{
    assert(parseMsgpack!int([0xCC, 0xFF]) == 255);
    assert(parseMsgpack!int([0xCD, 0x01, 0x00]) == 256);
    assert(parseMsgpack!int([0xCE, 0x00, 0x01, 0x00, 0x00]) == 65536);
    assert(parseMsgpack!long([0xCF, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00]) == 4294967296L);
}

// int 8/16/32/64
debug(ae_unittest) unittest
{
    assert(parseMsgpack!int([0xD0, 0x80]) == -128);
    assert(parseMsgpack!int([0xD1, 0x80, 0x00]) == -32768);
    assert(parseMsgpack!int([0xD2, 0x80, 0x00, 0x00, 0x00]) == -2147483648);
    assert(parseMsgpack!long([0xD3, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE]) == -2);
}

// nil
debug(ae_unittest) unittest
{
    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));

    auto parser = MsgpackParser([0xC0], 0);
    SO store;
    parser.read(&store);
    assert(store.type == SO.Type.null_);
}

// Boolean
debug(ae_unittest) unittest
{
    assert(parseMsgpack!bool([0xC2]) == false);
    assert(parseMsgpack!bool([0xC3]) == true);
}

// Float 32/64
debug(ae_unittest) unittest
{
    // float32: 3.14 ≈ 0x4048F5C3
    auto f = parseMsgpack!double([0xCA, 0x40, 0x48, 0xF5, 0xC3]);
    assert(f > 3.13 && f < 3.15);

    // float64: 3.14 = 0x40091EB851EB851F
    auto d = parseMsgpack!double([0xCB, 0x40, 0x09, 0x1E, 0xB8, 0x51, 0xEB, 0x85, 0x1F]);
    assert(d > 3.13 && d < 3.15);
}

// Fixstr
debug(ae_unittest) unittest
{
    // fixstr "hello" = 0xa5 + "hello"
    assert(parseMsgpack!string([0xA5, 0x68, 0x65, 0x6C, 0x6C, 0x6F]) == "hello");
    // empty fixstr
    assert(parseMsgpack!string([0xA0]) == "");
}

// str 8
debug(ae_unittest) unittest
{
    // str 8, length 5, "hello"
    assert(parseMsgpack!string([0xD9, 0x05, 0x68, 0x65, 0x6C, 0x6C, 0x6F]) == "hello");
}

// Fixarray
debug(ae_unittest) unittest
{
    // fixarray [1, 2, 3]
    assert(parseMsgpack!(int[])([0x93, 0x01, 0x02, 0x03]) == [1, 2, 3]);
    // empty fixarray
    assert(parseMsgpack!(int[])([0x90]).length == 0);
}

// Fixmap → struct
debug(ae_unittest) unittest
{
    static struct S { int a; int b; }

    // fixmap(2): "a"→1, "b"→2
    auto data = cast(immutable(ubyte)[]) [
        0x82,                   // fixmap(2)
        0xA1, 0x61,             // fixstr "a"
        0x01,                   // 1
        0xA1, 0x62,             // fixstr "b"
        0x02,                   // 2
    ];

    auto result = parseMsgpack!S(data);
    assert(result.a == 1);
    assert(result.b == 2);
}

// Round-trip: struct → MessagePack → struct
debug(ae_unittest) unittest
{
    static struct Config
    {
        string name;
        int port;
        bool enabled;
        string[] tags;
    }

    auto original = Config("test", 8080, true, ["web", "api"]);
    auto packed = toMsgpack(original);
    auto result = parseMsgpack!Config(packed);
    assert(result.name == "test");
    assert(result.port == 8080);
    assert(result.enabled == true);
    assert(result.tags == ["web", "api"]);
}

// Round-trip: nested structs
debug(ae_unittest) unittest
{
    static struct Inner { int x; string s; }
    static struct Outer { string name; Inner inner; }

    auto original = Outer("hello", Inner(42, "world"));
    auto packed = toMsgpack(original);
    auto result = parseMsgpack!Outer(packed);
    assert(result.name == "hello");
    assert(result.inner.x == 42);
    assert(result.inner.s == "world");
}

// Round-trip: negative integers
debug(ae_unittest) unittest
{
    static struct S { int x; long y; }
    auto original = S(-42, -100000);
    auto packed = toMsgpack(original);
    auto result = parseMsgpack!S(packed);
    assert(result.x == -42);
    assert(result.y == -100000);
}

// Round-trip: integer array
debug(ae_unittest) unittest
{
    auto original = [10, 20, 30];
    auto packed = toMsgpack(original);
    auto result = parseMsgpack!(int[])(packed);
    assert(result == [10, 20, 30]);
}

// bin 8 — binary data as array of numeric bytes
debug(ae_unittest) unittest
{
    // bin8, length 3, bytes [0xDE, 0xAD, 0xFF]
    auto result = parseMsgpack!(ubyte[])([0xC4, 0x03, 0xDE, 0xAD, 0xFF]);
    assert(result == [0xDE, 0xAD, 0xFF]);
}
