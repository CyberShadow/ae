/**
 * BSON serialization source and sink.
 *
 * Source/sink protocol adapters for BSON (Binary JSON), the binary
 * format used by MongoDB. The parser (source) reads BSON bytes and
 * emits events into any sink; the writer (sink) accepts events and
 * produces BSON bytes.
 *
 * BSON spec: https://bsonspec.org/spec.html
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

module ae.utils.serialization.bson;

import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.conv;
import std.exception;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// BSON type tags
// ---------------------------------------------------------------------------

private enum BsonType : ubyte
{
    double_     = 0x01,
    string_     = 0x02,
    document    = 0x03,
    array       = 0x04,
    binary      = 0x05,
    // 0x06 undefined (deprecated)
    objectId    = 0x07,
    boolean     = 0x08,
    datetime    = 0x09,
    null_       = 0x0A,
    regex       = 0x0B,
    // 0x0C dbPointer (deprecated)
    javascript  = 0x0D,
    // 0x0E symbol (deprecated)
    // 0x0F javascriptWithScope (deprecated)
    int32       = 0x10,
    timestamp   = 0x11,
    int64       = 0x12,
    decimal128  = 0x13,
    minKey      = 0xFF,
    maxKey      = 0x7F,
}

// ---------------------------------------------------------------------------
// BsonParser — source that reads BSON bytes
// ---------------------------------------------------------------------------

struct BsonParser
{
    const(ubyte)[] data;
    size_t p;

    /// Parse a BSON document and emit events into sink.
    void read(Sink)(Sink sink)
    {
        readDocument(sink);
    }

    private void readDocument(Sink)(Sink sink)
    {
        auto docSize = readInt32();
        auto docEnd = p - 4 + docSize;
        enforce(docEnd <= data.length, "BSON document extends past end of input");

        DocReader reader = {parser: &this, docEnd: docEnd};
        sink.handle(Map!(typeof(reader))(reader));
    }

    private void readArray(Sink)(Sink sink)
    {
        auto docSize = readInt32();
        auto docEnd = p - 4 + docSize;
        enforce(docEnd <= data.length, "BSON array extends past end of input");

        ArrayReader reader = {parser: &this, docEnd: docEnd};
        sink.handle(Array!(typeof(reader))(reader));
    }

    private void readValue(Sink)(BsonType type, Sink sink)
    {
        final switch (type)
        {
        case BsonType.double_:
            auto bits = readBytes(8);
            double val = *cast(const(double)*) bits.ptr;
            sink.handle(Numeric!string(to!string(val)));
            break;

        case BsonType.string_:
            auto str = readBsonString();
            sink.handle(String!(const(char)[])(str));
            break;

        case BsonType.document:
            readDocument(sink);
            break;

        case BsonType.array:
            readArray(sink);
            break;

        case BsonType.binary:
            auto len = readInt32();
            p++; // skip subtype byte
            auto bytes = readBytes(len);
            BinaryArrayReader bar = {bytes: bytes};
            sink.handle(Array!(typeof(bar))(bar));
            break;

        case BsonType.objectId:
            auto bytes = readBytes(12);
            import std.format : format;
            auto hex = format!"%(%02x%)"(bytes);
            sink.handle(String!string(hex));
            break;

        case BsonType.boolean:
            auto val = readByte();
            sink.handle(Boolean(val != 0));
            break;

        case BsonType.datetime:
            auto millis = readInt64();
            sink.handle(Numeric!string(to!string(millis)));
            break;

        case BsonType.null_:
            sink.handle(Null());
            break;

        case BsonType.regex:
            auto pattern = readCString();
            auto options = readCString();
            sink.handle(String!string("/" ~ pattern ~ "/" ~ options));
            break;

        case BsonType.javascript:
            auto str = readBsonString();
            sink.handle(String!(const(char)[])(str));
            break;

        case BsonType.int32:
            auto val = readInt32();
            sink.handle(Numeric!string(to!string(val)));
            break;

        case BsonType.timestamp:
            auto val = readInt64();
            sink.handle(Numeric!string(to!string(val)));
            break;

        case BsonType.int64:
            auto val = readInt64();
            sink.handle(Numeric!string(to!string(val)));
            break;

        case BsonType.decimal128:
            auto bytes = readBytes(16);
            auto str = decodeDecimal128(bytes[0 .. 16]);
            sink.handle(Numeric!string(str));
            break;

        case BsonType.minKey:
        case BsonType.maxKey:
            sink.handle(Null());
            break;
        }
    }

    private ubyte readByte()
    {
        enforce(p < data.length, "Unexpected end of BSON input");
        return data[p++];
    }

    private const(ubyte)[] readBytes(size_t n)
    {
        enforce(p + n <= data.length, "Unexpected end of BSON input");
        auto result = data[p .. p + n];
        p += n;
        return result;
    }

    private int readInt32()
    {
        auto bytes = readBytes(4);
        return littleEndianToNative!int(bytes[0 .. 4]);
    }

    private long readInt64()
    {
        auto bytes = readBytes(8);
        return littleEndianToNative!long(bytes[0 .. 8]);
    }

    private string readCString()
    {
        auto start = p;
        while (p < data.length && data[p] != 0)
            p++;
        enforce(p < data.length, "Unterminated BSON cstring");
        auto result = cast(const(char)[]) data[start .. p];
        p++; // skip null terminator
        return result.idup;
    }

    private const(char)[] readBsonString()
    {
        auto len = readInt32();
        enforce(len >= 1, "Invalid BSON string length");
        enforce(p + len <= data.length, "BSON string extends past end of input");
        auto result = cast(const(char)[]) data[p .. p + len - 1];
        p += len; // includes null terminator
        return result;
    }
}

private struct DocReader
{
    BsonParser* parser;
    size_t docEnd;

    void opCall(Sink)(Sink sink)
    {
        while (parser.p < docEnd - 1)
        {
            auto type = cast(BsonType) parser.readByte();
            if (type == 0) break; // end marker

            auto name = parser.readCString();
            ConstStringReader nr = {s: name};
            ValueReader vr = {parser: parser, type: type};
            sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
        }
        parser.p = docEnd; // skip to document end
    }
}

private struct ArrayReader
{
    BsonParser* parser;
    size_t docEnd;

    void opCall(Sink)(Sink sink)
    {
        while (parser.p < docEnd - 1)
        {
            auto type = cast(BsonType) parser.readByte();
            if (type == 0) break;

            parser.readCString(); // skip array index name ("0", "1", ...)
            parser.readValue(type, sink);
        }
        parser.p = docEnd;
    }
}

private struct BinaryArrayReader
{
    const(ubyte)[] bytes;

    void opCall(Sink)(Sink sink)
    {
        foreach (b; bytes)
            sink.handle(Numeric!string(to!string(b)));
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

private struct ValueReader
{
    BsonParser* parser;
    BsonType type;

    void opCall(Sink)(Sink sink)
    {
        parser.readValue(type, sink);
    }
}

// ---------------------------------------------------------------------------
// IEEE 754 decimal128 decoder
// ---------------------------------------------------------------------------

/// Decode a 16-byte IEEE 754 decimal128 value to its string representation.
/// Format: (-1)^sign × coefficient × 10^(exponent - bias)
/// Bias is 6176. Coefficient is up to 34 decimal digits.
private string decodeDecimal128(const(ubyte)[16] bytes)
{
    // Decimal128 is stored little-endian in BSON.
    // High 64 bits are in bytes[8..16], low 64 bits in bytes[0..8].
    ulong low  = littleEndianToNative!ulong(bytes[0 .. 8]);
    ulong high = littleEndianToNative!ulong(bytes[8 .. 16]);

    // Special values encoded in high bits
    enum ulong POSITIVE_INFINITY = 0x7800000000000000UL;
    enum ulong NEGATIVE_INFINITY = 0xF800000000000000UL;
    enum ulong NAN_MASK          = 0x7C00000000000000UL;

    bool sign = (high & (1UL << 63)) != 0;

    if ((high & NAN_MASK) == NAN_MASK)
        return sign ? "-NaN" : "NaN";
    if (high == POSITIVE_INFINITY && low == 0)
        return "Infinity";
    if (high == NEGATIVE_INFINITY && low == 0)
        return "-Infinity";

    // Extract exponent and coefficient.
    // Two encoding forms based on bits 61-62 of high word:
    int exponent;
    ulong coeffHigh; // high bits of coefficient (beyond what fits in low)

    if ((high & (3UL << 61)) == (3UL << 61))
    {
        // Form 2: bits 61-62 are both set.
        // Exponent in bits 47-60 (14 bits), coefficient high in bits 0-46.
        // Implicit leading 100 in coefficient (adds 8 + significand).
        exponent = cast(int)((high >> 47) & 0x3FFF);
        coeffHigh = (high & ((1UL << 47) - 1)) | (1UL << 49);
    }
    else
    {
        // Form 1 (common): exponent in bits 49-62 (14 bits),
        // coefficient high in bits 0-48.
        exponent = cast(int)((high >> 49) & 0x3FFF);
        coeffHigh = high & ((1UL << 49) - 1);
    }

    exponent -= 6176; // subtract bias

    // Combine into full 34-digit coefficient.
    // coefficient = coeffHigh * 2^64 + low
    // We need to convert this 113-bit integer to decimal digits.
    // Use repeated division by 10 on two 64-bit halves.
    char[34] digits = void;
    int nDigits = 0;

    ulong hi = coeffHigh;
    ulong lo = low;

    if (hi == 0 && lo == 0)
    {
        digits[0] = '0';
        nDigits = 1;
    }
    else
    {
        // Extract digits from least significant to most significant.
        char[34] revBuf = void;
        int revLen = 0;
        while (hi != 0 || lo != 0)
        {
            // Divide (hi:lo) by 10, get remainder.
            ulong rem = hi % 10;
            hi /= 10;
            // Now divide (rem * 2^64 + lo) by 10.
            // rem < 10, so rem * 2^64 fits conceptually; we need
            // to propagate the remainder through lo.
            ulong combined_hi = rem;
            // (combined_hi * 2^64 + lo) / 10:
            // Split: q = (combined_hi * 2^64 + lo) / 10
            //        r = (combined_hi * 2^64 + lo) % 10
            // Use: combined_hi * 2^64 = combined_hi * (10 * 1844674407370955161 + 6)
            ulong q2 = lo / 10;
            ulong r2 = lo % 10;
            // Add contribution from combined_hi * 2^64
            // 2^64 / 10 = 1844674407370955161 remainder 6
            q2 += combined_hi * 1844674407370955161UL;
            r2 += combined_hi * 6;
            q2 += r2 / 10;
            r2 %= 10;
            lo = q2;
            revBuf[revLen++] = cast(char)('0' + r2);
        }
        // Reverse
        foreach (i; 0 .. revLen)
            digits[i] = revBuf[revLen - 1 - i];
        nDigits = revLen;
    }

    // Build the string: sign + digits with decimal point placed by exponent.
    // adjusted exponent = exponent + (nDigits - 1)
    // Use scientific notation if exponent would create very long strings.
    auto dslice = digits[0 .. nDigits];
    int adjExp = exponent + nDigits - 1;

    char[] result;
    if (sign)
        result ~= '-';

    if (exponent >= 0)
    {
        // No decimal point needed, just append zeros
        result ~= dslice;
        foreach (_; 0 .. exponent)
            result ~= '0';
    }
    else if (adjExp >= 0)
    {
        // Decimal point falls within the digits
        int pointPos = adjExp + 1;
        result ~= dslice[0 .. pointPos];
        result ~= '.';
        result ~= dslice[pointPos .. $];
    }
    else
    {
        // Need leading "0.000..."
        result ~= "0.";
        foreach (_; 0 .. -adjExp - 1)
            result ~= '0';
        result ~= dslice;
    }

    return cast(string) result;
}

// ---------------------------------------------------------------------------
// BsonWriter — sink that produces BSON bytes
// ---------------------------------------------------------------------------

struct BsonWriter
{
    ubyte[] result;

    void handle(V)(V v)
    {
        static if (isProtocolMap!V)
        {
            auto doc = writeDocument(v);
            result = doc;
        }
        else static if (isProtocolArray!V)
        {
            auto doc = writeArray(v);
            result = doc;
        }
        else
            static assert(false, "BsonWriter: top-level must be Map or Array, got " ~ V.stringof);
    }

    static ubyte[] writeDocument(V)(V v)
    {
        BsonDocSink ds;
        v.reader(&ds);

        // Build document: int32 size + elements + 0x00
        auto bodyLen = ds.buf.length;
        auto docSize = cast(int)(4 + bodyLen + 1);
        ubyte[] doc;
        doc ~= nativeToLittleEndian(docSize)[];
        doc ~= ds.buf;
        doc ~= 0x00;
        return doc;
    }

    static ubyte[] writeArray(V)(V v)
    {
        BsonArraySink as;
        v.reader(&as);

        auto bodyLen = as.buf.length;
        auto docSize = cast(int)(4 + bodyLen + 1);
        ubyte[] doc;
        doc ~= nativeToLittleEndian(docSize)[];
        doc ~= as.buf;
        doc ~= 0x00;
        return doc;
    }
}

private struct BsonDocSink
{
    ubyte[] buf;

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

            BsonValueCapture vc;
            v.valueReader(&vc);

            buf ~= vc.typeTag;
            buf ~= cast(const(ubyte)[]) nc.name;
            buf ~= 0x00; // cstring terminator
            buf ~= vc.data;
        }
        else
            static assert(false, "BsonDocSink: expected Field, got " ~ V.stringof);
    }
}

private struct BsonArraySink
{
    ubyte[] buf;
    int index;

    void handle(V)(V v)
    {
        BsonValueCapture vc;
        vc.handle(v);

        auto name = to!string(index);
        buf ~= vc.typeTag;
        buf ~= cast(const(ubyte)[]) name;
        buf ~= 0x00;
        buf ~= vc.data;
        index++;
    }
}

private struct BsonValueCapture
{
    ubyte typeTag;
    ubyte[] data;

    void handle(V)(V v)
    {
        static if (isProtocolNull!V)
        {
            typeTag = BsonType.null_;
        }
        else static if (isProtocolBoolean!V)
        {
            typeTag = BsonType.boolean;
            data = [v.value ? 0x01 : 0x00];
        }
        else static if (isProtocolNumeric!V)
        {
            auto text = to!string(v.text);
            // Try integer first
            try
            {
                auto ival = to!long(text);
                if (ival >= int.min && ival <= int.max)
                {
                    typeTag = BsonType.int32;
                    data = nativeToLittleEndian(cast(int) ival)[].dup;
                }
                else
                {
                    typeTag = BsonType.int64;
                    data = nativeToLittleEndian(ival)[].dup;
                }
                return;
            }
            catch (ConvException) {}

            // Fall back to double
            try
            {
                auto dval = to!double(text);
                typeTag = BsonType.double_;
                data = nativeToLittleEndian(dval)[].dup;
                return;
            }
            catch (ConvException) {}

            // Last resort: store as string
            typeTag = BsonType.string_;
            data = writeBsonString(text);
        }
        else static if (isProtocolString!V)
        {
            typeTag = BsonType.string_;
            data = writeBsonString(to!string(v.text));
        }
        else static if (isProtocolArray!V)
        {
            typeTag = BsonType.array;
            data = BsonWriter.writeArray(v);
        }
        else static if (isProtocolMap!V)
        {
            typeTag = BsonType.document;
            data = BsonWriter.writeDocument(v);
        }
        else
            static assert(false, "BsonValueCapture: unsupported type " ~ V.stringof);
    }

    static ubyte[] writeBsonString(string s)
    {
        auto len = cast(int)(s.length + 1);
        ubyte[] result;
        result ~= nativeToLittleEndian(len)[];
        result ~= cast(const(ubyte)[]) s;
        result ~= 0x00;
        return result;
    }
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse BSON bytes into a D value.
T parseBson(T)(const(ubyte)[] data)
{
    auto parser = BsonParser(data, 0);
    T result;
    auto sink = deserializer(&result);
    parser.read(sink);
    return result;
}

/// Serialize a D value to BSON bytes.
ubyte[] toBson(T)(auto ref T value)
{
    BsonWriter writer;
    Serializer.Impl!Object.read(&writer, value);
    return writer.result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

// Simple document with string
debug(ae_unittest) unittest
{
    // {"hello": "world"}
    auto bson = cast(immutable(ubyte)[]) hexToBytes(
        "16000000" ~        // document size: 22
        "02"       ~        // type: string
        "68656c6c6f00" ~    // "hello\0"
        "06000000" ~        // string size: 6
        "776f726c6400" ~    // "world\0"
        "00"                // document terminator
    );

    static struct S { string hello; }
    auto result = parseBson!S(bson);
    assert(result.hello == "world");
}

// Int32 value
debug(ae_unittest) unittest
{
    // {"x": 42}
    auto bson = cast(immutable(ubyte)[]) hexToBytes(
        "0c000000" ~        // size: 12
        "10"       ~        // type: int32
        "7800"     ~        // "x\0"
        "2a000000" ~        // 42
        "00"
    );

    static struct S { int x; }
    auto result = parseBson!S(bson);
    assert(result.x == 42);
}

// Boolean value
debug(ae_unittest) unittest
{
    // {"flag": true}
    auto bson = cast(immutable(ubyte)[]) hexToBytes(
        "0c000000" ~        // size: 12
        "08"       ~        // type: boolean
        "666c616700" ~      // "flag\0"
        "01"       ~        // true
        "00"
    );

    static struct S { bool flag; }
    auto result = parseBson!S(bson);
    assert(result.flag == true);
}

// Int64 value
debug(ae_unittest) unittest
{
    // {"big": 2^40}
    auto bson = cast(immutable(ubyte)[]) hexToBytes(
        "12000000" ~            // size: 18
        "12"       ~            // type: int64
        "62696700" ~            // "big\0"
        "0000000001000000" ~    // 2^32 = 4294967296
        "00"
    );

    static struct S { long big; }
    auto result = parseBson!S(bson);
    assert(result.big == 4294967296L);
}

// Double value
debug(ae_unittest) unittest
{
    // {"pi": 3.14}
    auto bson = cast(immutable(ubyte)[]) hexToBytes(
        "11000000" ~        // size: 17
        "01"       ~        // type: double
        "706900"   ~        // "pi\0"
        "1f85eb51b81e0940" ~ // 3.14 as little-endian double
        "00"
    );

    static struct S { double pi; }
    auto result = parseBson!S(bson);
    assert(result.pi > 3.13 && result.pi < 3.15);
}

// Null value
debug(ae_unittest) unittest
{
    // {"n": null}
    auto bson = cast(immutable(ubyte)[]) hexToBytes(
        "08000000" ~        // size: 8
        "0a"       ~        // type: null
        "6e00"     ~        // "n\0"
        "00"
    );

    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));
    auto result = parseBson!(SO)(bson);
    assert(result.type == SO.Type.object);
}

// Nested document
debug(ae_unittest) unittest
{
    static struct Inner { string host; int port; }
    static struct Outer { Inner server; }

    auto original = Outer(Inner("localhost", 8080));
    auto bson = toBson(original);
    auto result = parseBson!Outer(bson);
    assert(result.server.host == "localhost");
    assert(result.server.port == 8080);
}

// Array
debug(ae_unittest) unittest
{
    static struct S { int[] values; }

    auto original = S([1, 2, 3]);
    auto bson = toBson(original);
    auto result = parseBson!S(bson);
    assert(result.values == [1, 2, 3]);
}

// Round-trip
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
    auto bson = toBson(original);
    auto result = parseBson!Config(bson);
    assert(result.name == "test");
    assert(result.port == 8080);
    assert(result.enabled == true);
    assert(result.tags == ["web", "api"]);
}

// Empty document
debug(ae_unittest) unittest
{
    static struct S {}
    auto bson = toBson(S());
    auto result = parseBson!S(bson);
}

// Decimal128: 0.1 (exact representation)
debug(ae_unittest) unittest
{
    // 0.1 as decimal128: coefficient=1, exponent=-1 (biased: 6175=0x181F)
    // Form 1: exponent in bits 49-62, coefficient in bits 0-48 of high word
    // high = 0x303E000000000000 (exponent 6175 << 49, no sign)
    // Actually: biased exp 6175 = 0x181F, shifted left 49 = 0x303E000000000000
    // low = 1
    ubyte[16] dec128bytes;
    // Little-endian: low 8 bytes first
    dec128bytes[0 .. 8] = nativeToLittleEndian(cast(ulong) 1)[];
    dec128bytes[8 .. 16] = nativeToLittleEndian(cast(ulong) 0x303E000000000000UL)[];

    // Build BSON document: {"v": <decimal128>}
    ubyte[] bson;
    ubyte[] body_;
    body_ ~= 0x13; // type: decimal128
    body_ ~= cast(ubyte[]) "v" ~ 0x00;
    body_ ~= dec128bytes[];
    auto docSize = cast(int)(4 + body_.length + 1);
    bson ~= nativeToLittleEndian(docSize)[];
    bson ~= body_;
    bson ~= 0x00;

    static struct S { string v; }
    auto result = parseBson!S(bson);
    assert(result.v == "0.1", "got: " ~ result.v);
}

// Decimal128: 1234567890.12345
debug(ae_unittest) unittest
{
    // coefficient = 123456789012345, exponent = -5 (biased: 6171 = 0x181B)
    // high = 6171 << 49 = 0x3036000000000000
    // low = 123456789012345
    ubyte[16] dec128bytes;
    dec128bytes[0 .. 8] = nativeToLittleEndian(cast(ulong) 123456789012345UL)[];
    dec128bytes[8 .. 16] = nativeToLittleEndian(cast(ulong) 0x3036000000000000UL)[];

    ubyte[] bson;
    ubyte[] body_;
    body_ ~= 0x13;
    body_ ~= cast(ubyte[]) "v" ~ 0x00;
    body_ ~= dec128bytes[];
    auto docSize = cast(int)(4 + body_.length + 1);
    bson ~= nativeToLittleEndian(docSize)[];
    bson ~= body_;
    bson ~= 0x00;

    static struct S { string v; }
    auto result = parseBson!S(bson);
    assert(result.v == "1234567890.12345", "got: " ~ result.v);
}

// Decimal128: zero
debug(ae_unittest) unittest
{
    // coefficient=0, exponent=0 (biased: 6176=0x1820)
    // high = 6176 << 49 = 0x3040000000000000
    ubyte[16] dec128bytes;
    dec128bytes[0 .. 8] = nativeToLittleEndian(cast(ulong) 0)[];
    dec128bytes[8 .. 16] = nativeToLittleEndian(cast(ulong) 0x3040000000000000UL)[];

    ubyte[] bson;
    ubyte[] body_;
    body_ ~= 0x13;
    body_ ~= cast(ubyte[]) "v" ~ 0x00;
    body_ ~= dec128bytes[];
    auto docSize = cast(int)(4 + body_.length + 1);
    bson ~= nativeToLittleEndian(docSize)[];
    bson ~= body_;
    bson ~= 0x00;

    static struct S { string v; }
    auto result = parseBson!S(bson);
    assert(result.v == "0", "got: " ~ result.v);
}

// Decimal128: negative value
debug(ae_unittest) unittest
{
    // -0.1: same as 0.1 but with sign bit set
    // high = 0x303E000000000000 | (1 << 63) = 0xB03E000000000000
    ubyte[16] dec128bytes;
    dec128bytes[0 .. 8] = nativeToLittleEndian(cast(ulong) 1)[];
    dec128bytes[8 .. 16] = nativeToLittleEndian(cast(ulong) 0xB03E000000000000UL)[];

    ubyte[] bson;
    ubyte[] body_;
    body_ ~= 0x13;
    body_ ~= cast(ubyte[]) "v" ~ 0x00;
    body_ ~= dec128bytes[];
    auto docSize = cast(int)(4 + body_.length + 1);
    bson ~= nativeToLittleEndian(docSize)[];
    bson ~= body_;
    bson ~= 0x00;

    static struct S { string v; }
    auto result = parseBson!S(bson);
    assert(result.v == "-0.1", "got: " ~ result.v);
}

// ---------------------------------------------------------------------------
// Helper
// ---------------------------------------------------------------------------

private ubyte[] hexToBytes(string hex)
{
    ubyte[] result;
    result.length = hex.length / 2;
    foreach (i; 0 .. result.length)
        result[i] = to!ubyte(hex[i * 2 .. i * 2 + 2], 16);
    return result;
}
