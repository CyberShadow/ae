/**
 * CBOR serialization source and sink.
 *
 * Source/sink protocol adapters for CBOR (Concise Binary Object
 * Representation, RFC 8949). The parser (source) reads CBOR bytes and
 * emits events into any sink; the writer (sink) accepts events and
 * produces CBOR bytes.
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

module ae.utils.serialization.cbor;

import std.bitmanip : bigEndianToNative, nativeToBigEndian;
import std.conv;
import std.exception;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// CBOR major types (high 3 bits of first byte)
// ---------------------------------------------------------------------------

private enum CborMajor : ubyte
{
    unsignedInt = 0,    // 0x00..0x1b
    negativeInt = 1,    // 0x20..0x3b
    byteString  = 2,    // 0x40..0x5b
    textString  = 3,    // 0x60..0x7b
    array       = 4,    // 0x80..0x9b
    map         = 5,    // 0xa0..0xbb
    tag         = 6,    // 0xc0..0xdb
    simple      = 7,    // 0xe0..0xfb (false, true, null, undefined, float16/32/64)
}

// ---------------------------------------------------------------------------
// CborParser — source that reads CBOR bytes
// ---------------------------------------------------------------------------

struct CborParser
{
    const(ubyte)[] data;
    size_t p;

    /// Parse a CBOR value and emit events into sink.
    void read(Sink)(Sink sink)
    {
        enforce(p < data.length, "Unexpected end of CBOR input");
        auto initial = data[p++];
        auto major = cast(CborMajor)(initial >> 5);
        auto info = initial & 0x1F;

        final switch (major)
        {
        case CborMajor.unsignedInt:
            auto val = readArgument(info);
            sink.handle(Numeric!string(to!string(val)));
            break;

        case CborMajor.negativeInt:
            auto val = readArgument(info);
            // CBOR negative: -1 - val
            long negVal = -1 - cast(long) val;
            sink.handle(Numeric!string(to!string(negVal)));
            break;

        case CborMajor.byteString:
            auto len = readArgument(info);
            auto bytes = readBytes(cast(size_t) len);
            import std.format : format;
            auto hex = format!"%(%02x%)"(bytes);
            sink.handle(String!string(hex));
            break;

        case CborMajor.textString:
            auto len = readArgument(info);
            auto bytes = readBytes(cast(size_t) len);
            auto str = cast(const(char)[]) bytes;
            sink.handle(String!(const(char)[])(str));
            break;

        case CborMajor.array:
            if (info == 31)
            {
                // Indefinite-length array
                IndefiniteArrayReader reader = {parser: &this};
                sink.handle(Array!(typeof(reader))(reader));
            }
            else
            {
                auto count = readArgument(info);
                DefiniteArrayReader reader = {parser: &this, remaining: cast(size_t) count};
                sink.handle(Array!(typeof(reader))(reader));
            }
            break;

        case CborMajor.map:
            if (info == 31)
            {
                IndefiniteMapReader reader = {parser: &this};
                sink.handle(Map!(typeof(reader))(reader));
            }
            else
            {
                auto count = readArgument(info);
                DefiniteMapReader reader = {parser: &this, remaining: cast(size_t) count};
                sink.handle(Map!(typeof(reader))(reader));
            }
            break;

        case CborMajor.tag:
            // Skip the tag number and read the tagged value
            readArgument(info);
            read(sink);
            break;

        case CborMajor.simple:
            if (info == 20)
                sink.handle(Boolean(false));
            else if (info == 21)
                sink.handle(Boolean(true));
            else if (info == 22 || info == 23)  // null, undefined
                sink.handle(Null());
            else if (info == 25)
            {
                // float16
                auto bytes = readBytes(2);
                double val = decodeFloat16(bytes[0], bytes[1]);
                sink.handle(Numeric!string(to!string(val)));
            }
            else if (info == 26)
            {
                // float32
                auto bytes = readBytes(4);
                float val = bigEndianToNative!float(bytes[0 .. 4]);
                sink.handle(Numeric!string(to!string(val)));
            }
            else if (info == 27)
            {
                // float64
                auto bytes = readBytes(8);
                double val = bigEndianToNative!double(bytes[0 .. 8]);
                sink.handle(Numeric!string(to!string(val)));
            }
            else if (info == 31)
            {
                // "break" — should not appear at top level
                throw new Exception("Unexpected CBOR break code");
            }
            else
            {
                // Simple value — emit as numeric
                sink.handle(Numeric!string(to!string(info)));
            }
            break;
        }
    }

    private ulong readArgument(int info)
    {
        if (info < 24)
            return info;
        else if (info == 24)
            return readByte();
        else if (info == 25)
        {
            auto bytes = readBytes(2);
            return bigEndianToNative!ushort(bytes[0 .. 2]);
        }
        else if (info == 26)
        {
            auto bytes = readBytes(4);
            return bigEndianToNative!uint(bytes[0 .. 4]);
        }
        else if (info == 27)
        {
            auto bytes = readBytes(8);
            return bigEndianToNative!ulong(bytes[0 .. 8]);
        }
        else
            throw new Exception("Invalid CBOR additional info: " ~ to!string(info));
    }

    private ubyte readByte()
    {
        enforce(p < data.length, "Unexpected end of CBOR input");
        return data[p++];
    }

    private const(ubyte)[] readBytes(size_t n)
    {
        enforce(p + n <= data.length, "Unexpected end of CBOR input");
        auto result = data[p .. p + n];
        p += n;
        return result;
    }

    private bool atBreak()
    {
        return p < data.length && data[p] == 0xFF;
    }
}

private struct DefiniteArrayReader
{
    CborParser* parser;
    size_t remaining;

    void opCall(Sink)(Sink sink)
    {
        foreach (_; 0 .. remaining)
            parser.read(sink);
    }
}

private struct IndefiniteArrayReader
{
    CborParser* parser;

    void opCall(Sink)(Sink sink)
    {
        while (!parser.atBreak())
            parser.read(sink);
        parser.p++; // skip break byte
    }
}

private struct DefiniteMapReader
{
    CborParser* parser;
    size_t remaining;

    void opCall(Sink)(Sink sink)
    {
        foreach (_; 0 .. remaining)
        {
            CborKeyReader kr = {parser: parser};
            CborValueReader vr = {parser: parser};
            sink.handle(Field!(typeof(kr), typeof(vr))(kr, vr));
        }
    }
}

private struct IndefiniteMapReader
{
    CborParser* parser;

    void opCall(Sink)(Sink sink)
    {
        while (!parser.atBreak())
        {
            CborKeyReader kr = {parser: parser};
            CborValueReader vr = {parser: parser};
            sink.handle(Field!(typeof(kr), typeof(vr))(kr, vr));
        }
        parser.p++; // skip break byte
    }
}

private struct CborKeyReader
{
    CborParser* parser;
    void opCall(Sink)(Sink sink)
    {
        parser.read(sink);
    }
}

private struct CborValueReader
{
    CborParser* parser;
    void opCall(Sink)(Sink sink)
    {
        parser.read(sink);
    }
}

// ---------------------------------------------------------------------------
// CborWriter — sink that produces CBOR bytes
// ---------------------------------------------------------------------------

struct CborWriter
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
            return [0xF6]; // null
        }
        else static if (isProtocolBoolean!V)
        {
            return [v.value ? cast(ubyte) 0xF5 : cast(ubyte) 0xF4];
        }
        else static if (isProtocolNumeric!V)
        {
            auto text = to!string(v.text);
            // Try integer first
            try
            {
                auto val = to!long(text);
                if (val >= 0)
                    return encodeUnsigned(CborMajor.unsignedInt, cast(ulong) val);
                else
                    return encodeUnsigned(CborMajor.negativeInt, cast(ulong)(-1 - val));
            }
            catch (ConvException) {}

            // Fall back to float64
            try
            {
                auto dval = to!double(text);
                ubyte[] result;
                result ~= cast(ubyte)(CborMajor.simple << 5 | 27);
                result ~= nativeToBigEndian(dval)[];
                return result;
            }
            catch (ConvException) {}

            // Last resort: text string
            return encodeTextString(text);
        }
        else static if (isProtocolString!V)
        {
            return encodeTextString(to!string(v.text));
        }
        else static if (isProtocolArray!V)
        {
            CborArrayCollector ac;
            v.reader(&ac);

            ubyte[] result = encodeUnsigned(CborMajor.array, ac.items.length);
            foreach (ref item; ac.items)
                result ~= item;
            return result;
        }
        else static if (isProtocolMap!V)
        {
            CborMapCollector mc;
            v.reader(&mc);

            ubyte[] result = encodeUnsigned(CborMajor.map, mc.pairs.length);
            foreach (ref pair; mc.pairs)
                result ~= pair;
            return result;
        }
        else
            static assert(false, "CborWriter: unsupported type " ~ V.stringof);
    }

    static ubyte[] encodeUnsigned(CborMajor major, ulong val)
    {
        ubyte majorBits = cast(ubyte)(major << 5);
        if (val < 24)
            return [cast(ubyte)(majorBits | val)];
        else if (val <= ubyte.max)
            return [cast(ubyte)(majorBits | 24), cast(ubyte) val];
        else if (val <= ushort.max)
        {
            ubyte[] result;
            result ~= cast(ubyte)(majorBits | 25);
            result ~= nativeToBigEndian(cast(ushort) val)[];
            return result;
        }
        else if (val <= uint.max)
        {
            ubyte[] result;
            result ~= cast(ubyte)(majorBits | 26);
            result ~= nativeToBigEndian(cast(uint) val)[];
            return result;
        }
        else
        {
            ubyte[] result;
            result ~= cast(ubyte)(majorBits | 27);
            result ~= nativeToBigEndian(val)[];
            return result;
        }
    }

    static ubyte[] encodeTextString(string s)
    {
        ubyte[] result = encodeUnsigned(CborMajor.textString, s.length);
        result ~= cast(const(ubyte)[]) s;
        return result;
    }
}

private struct CborArrayCollector
{
    ubyte[][] items;

    void handle(V)(V v)
    {
        items ~= CborWriter.encodeValue(v);
    }
}

private struct CborMapCollector
{
    ubyte[][] pairs;

    void handle(V)(V v)
    {
        static if (isProtocolField!V)
        {
            CborWriter kw, vw;
            v.nameReader(&kw);
            v.valueReader(&vw);
            // Concatenate key + value as a single pair entry
            ubyte[] pair;
            pair ~= kw.result;
            pair ~= vw.result;
            pairs ~= pair;
        }
        else
            static assert(false, "CborMapCollector: expected Field, got " ~ V.stringof);
    }
}

// ---------------------------------------------------------------------------
// Float16 decoding
// ---------------------------------------------------------------------------

private double decodeFloat16(ubyte b0, ubyte b1)
{
    int half = (b0 << 8) | b1;
    int sign = (half >> 15) & 1;
    int exp = (half >> 10) & 0x1F;
    int mant = half & 0x3FF;

    double val;
    if (exp == 0)
        val = (1.0 / (1 << 24)) * mant; // subnormal
    else if (exp == 31)
    {
        import std.math : isNaN;
        val = mant == 0 ? double.infinity : double.nan;
    }
    else
        val = (1.0 * (1 << (exp - 25))) * (1024 + mant);

    return sign ? -val : val;
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse CBOR bytes into a D value.
T parseCbor(T)(const(ubyte)[] data)
{
    auto parser = CborParser(data, 0);
    T result;
    auto sink = deserializer(&result);
    parser.read(sink);
    return result;
}

/// Serialize a D value to CBOR bytes.
ubyte[] toCbor(T)(auto ref T value)
{
    CborWriter writer;
    Serializer.Impl!Object.read(&writer, value);
    return writer.result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// Unsigned integers
debug(ae_unittest) unittest
{
    // 0
    assert(parseCbor!int([0x00]) == 0);
    // 1
    assert(parseCbor!int([0x01]) == 1);
    // 23
    assert(parseCbor!int([0x17]) == 23);
    // 24
    assert(parseCbor!int([0x18, 0x18]) == 24);
    // 256
    assert(parseCbor!int([0x19, 0x01, 0x00]) == 256);
    // 1000000
    assert(parseCbor!int([0x1A, 0x00, 0x0F, 0x42, 0x40]) == 1000000);
}

// Negative integers
debug(ae_unittest) unittest
{
    // -1
    assert(parseCbor!int([0x20]) == -1);
    // -10
    assert(parseCbor!int([0x29]) == -10);
    // -100
    assert(parseCbor!int([0x38, 0x63]) == -100);
}

// Strings
debug(ae_unittest) unittest
{
    // ""
    assert(parseCbor!string([0x60]) == "");
    // "a"
    assert(parseCbor!string([0x61, 0x61]) == "a");
    // "IETF"
    assert(parseCbor!string([0x64, 0x49, 0x45, 0x54, 0x46]) == "IETF");
}

// Boolean and null
debug(ae_unittest) unittest
{
    assert(parseCbor!bool([0xF5]) == true);
    assert(parseCbor!bool([0xF4]) == false);
}

// Float64
debug(ae_unittest) unittest
{
    // 1.1 as float64: 0xFB 3FF199999999999A
    auto result = parseCbor!double([0xFB, 0x3F, 0xF1, 0x99, 0x99, 0x99, 0x99, 0x99, 0x9A]);
    assert(result > 1.09 && result < 1.11);
}

// Array
debug(ae_unittest) unittest
{
    // [1, 2, 3]
    auto result = parseCbor!(int[])([0x83, 0x01, 0x02, 0x03]);
    assert(result == [1, 2, 3]);
}

// Empty array
debug(ae_unittest) unittest
{
    assert(parseCbor!(int[])([0x80]).length == 0);
}

// Map → struct
debug(ae_unittest) unittest
{
    static struct S { int a; int b; }

    // {"a": 1, "b": 2}
    auto cbor = cast(immutable(ubyte)[]) [
        0xA2,                   // map(2)
        0x61, 0x61,             // "a"
        0x01,                   // 1
        0x61, 0x62,             // "b"
        0x02,                   // 2
    ];

    auto result = parseCbor!S(cbor);
    assert(result.a == 1);
    assert(result.b == 2);
}

// Round-trip: struct → CBOR → struct
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
    auto cbor = toCbor(original);
    auto result = parseCbor!Config(cbor);
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
    auto cbor = toCbor(original);
    auto result = parseCbor!Outer(cbor);
    assert(result.name == "hello");
    assert(result.inner.x == 42);
    assert(result.inner.s == "world");
}

// Round-trip: integer array
debug(ae_unittest) unittest
{
    auto original = [10, 20, 30];
    auto cbor = toCbor(original);
    auto result = parseCbor!(int[])(cbor);
    assert(result == [10, 20, 30]);
}

// Negative integer round-trip
debug(ae_unittest) unittest
{
    static struct S { int x; }
    auto original = S(-42);
    auto cbor = toCbor(original);
    auto result = parseCbor!S(cbor);
    assert(result.x == -42);
}

// CBOR tag (ignored, value passed through)
debug(ae_unittest) unittest
{
    // Tag 1 (epoch-based date/time) wrapping integer 1363896240
    auto cbor = cast(immutable(ubyte)[]) [
        0xC1,                               // tag(1)
        0x1A, 0x51, 0x4B, 0x67, 0xB0,      // 1363896240
    ];
    auto result = parseCbor!long(cbor);
    assert(result == 1363896240L);
}

// Indefinite-length array
debug(ae_unittest) unittest
{
    // [_ 1, 2, 3]
    auto cbor = cast(immutable(ubyte)[]) [
        0x9F,           // array(*)
        0x01, 0x02, 0x03,
        0xFF,           // break
    ];
    auto result = parseCbor!(int[])(cbor);
    assert(result == [1, 2, 3]);
}
