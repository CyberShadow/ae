/**
 * .NET Binary Format (NRBF/BinaryFormatter) serialization source.
 *
 * Source protocol adapter for .NET's BinaryFormatter serialization
 * format (MS-NRBF). Reads binary data and emits events into any sink.
 *
 * Supports the common subset: a single top-level object with primitive
 * fields (bool, integers, floats), string fields (with reference
 * deduplication), and string array fields. This covers typical .NET
 * serialized data files (game saves, config, etc.).
 *
 * The stream header, assembly name, and class name are skipped — only
 * field name/value pairs are emitted as a Map.
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

module ae.utils.serialization.nrbf;

import std.bitmanip : littleEndianToNative;
import std.conv;
import std.exception;

import ae.utils.serialization.serialization;

// ---------------------------------------------------------------------------
// .NET BinaryFormatter record/type codes
// ---------------------------------------------------------------------------

private enum RecordType : ubyte
{
    SerializedStreamHeader      = 0,
    ClassWithId                 = 1,
    SystemClassWithMembers      = 2,
    ClassWithMembers            = 3,
    SystemClassWithMembersAndTypes = 4,
    ClassWithMembersAndTypes    = 5,
    BinaryObjectString          = 6,
    BinaryArray                 = 7,
    MemberPrimitiveTyped        = 8,
    MemberReference             = 9,
    ObjectNull                  = 10,
    MessageEnd                  = 11,
    BinaryLibrary               = 12,
    ObjectNullMultiple256       = 13,
    ObjectNullMultiple          = 14,
    ArraySinglePrimitive        = 15,
    ArraySingleObject           = 16,
    ArraySingleString           = 17,
}

private enum BinaryType : ubyte
{
    Primitive       = 0,
    String          = 1,
    Object          = 2,
    SystemClass     = 3,
    Class           = 4,
    ObjectArray     = 5,
    StringArray     = 6,
    PrimitiveArray  = 7,
}

private enum PrimitiveType : ubyte
{
    Boolean  = 1,
    Byte     = 2,
    Char     = 3,
    Decimal  = 5,
    Double   = 6,
    Int16    = 7,
    Int32    = 8,
    Int64    = 9,
    SByte    = 10,
    Single   = 11,
    TimeSpan = 12,
    DateTime = 13,
    UInt16   = 14,
    UInt32   = 15,
    UInt64   = 16,
    Null     = 17,
    String   = 18,
}

// ---------------------------------------------------------------------------
// NrbfParser — source that reads .NET BinaryFormatter data
// ---------------------------------------------------------------------------

struct NrbfParser
{
    const(ubyte)[] data;
    size_t p;

    // Object tables for resolving references
    string[int] stringTable;
    const(ubyte)[][int] deferredArrays; // arrayId -> raw bytes to parse later
    int[] fieldArrayIds; // for each field: array ID if StringArray, -1 otherwise

    /// Parse the binary stream and emit the top-level object as a Map.
    void read(Sink)(Sink sink)
    {
        // SerializedStreamHeader (record type 0 + 16 bytes)
        auto recType = readByte();
        enforce(recType == RecordType.SerializedStreamHeader,
            "Expected SerializedStreamHeader, got " ~ to!string(recType));
        skip(16); // rootId, headerId, majorVersion, minorVersion

        // Read records until we find the class definition
        string[] fieldNames;
        BinaryType[] fieldBinaryTypes;
        PrimitiveType[] fieldPrimTypes;

        while (p < data.length)
        {
            recType = readByte();

            if (recType == RecordType.BinaryLibrary)
            {
                skip(4); // library ID
                readPrefixedString(); // assembly name — skip
            }
            else if (recType == RecordType.ClassWithMembersAndTypes
                  || recType == RecordType.SystemClassWithMembersAndTypes)
            {
                skip(4); // object ID

                readPrefixedString(); // class name — skip

                int fieldCount = readInt32();

                // Field names
                fieldNames.length = fieldCount;
                foreach (i; 0 .. fieldCount)
                    fieldNames[i] = readPrefixedString();

                // BinaryType for each field
                fieldBinaryTypes.length = fieldCount;
                foreach (i; 0 .. fieldCount)
                    fieldBinaryTypes[i] = cast(BinaryType) readByte();

                // Additional type info
                fieldPrimTypes.length = fieldCount;
                foreach (i; 0 .. fieldCount)
                {
                    if (fieldBinaryTypes[i] == BinaryType.Primitive
                     || fieldBinaryTypes[i] == BinaryType.PrimitiveArray)
                        fieldPrimTypes[i] = cast(PrimitiveType) readByte();
                    else if (fieldBinaryTypes[i] == BinaryType.SystemClass)
                        readPrefixedString(); // class name — skip
                    else if (fieldBinaryTypes[i] == BinaryType.Class)
                    {
                        readPrefixedString(); // class name
                        skip(4); // library ID
                    }
                }

                // Library ID reference (only for ClassWithMembersAndTypes, not System variant)
                if (recType == RecordType.ClassWithMembersAndTypes)
                    skip(4);

                // Now read field values and emit as Map
                fieldArrayIds.length = fieldCount;
                fieldArrayIds[] = -1;

                FieldsReader fr = {
                    parser: &this,
                    fieldNames: fieldNames,
                    fieldBinaryTypes: fieldBinaryTypes,
                    fieldPrimTypes: fieldPrimTypes,
                };
                sink.handle(Map!(typeof(fr))(fr));

                // After emitting the map, consume trailing records
                // (deferred arrays, strings, MessageEnd)
                consumeTrailingRecords();
                return;
            }
            else if (recType == RecordType.MessageEnd)
                return;
            else
                throw new Exception("Unexpected record type: " ~ to!string(recType));
        }
    }

    private void consumeTrailingRecords()
    {
        while (p < data.length)
        {
            auto recType = readByte();
            if (recType == RecordType.MessageEnd)
                return;
            else if (recType == RecordType.ArraySingleString)
            {
                int arrayId = readInt32();
                int length = readInt32();
                // Skip array elements
                foreach (_; 0 .. length)
                    skipArrayElement();
            }
            else if (recType == RecordType.BinaryObjectString)
            {
                skip(4); // string ID
                readPrefixedString();
            }
            else if (recType == RecordType.ObjectNull)
            {} // nothing to skip
            else if (recType == RecordType.ObjectNullMultiple256)
                skip(1);
            else if (recType == RecordType.ObjectNullMultiple)
                skip(4);
            else if (recType == RecordType.MemberReference)
                skip(4);
            else
                return; // unknown record, stop
        }
    }

    private void skipArrayElement()
    {
        auto recType = readByte();
        if (recType == RecordType.BinaryObjectString)
        {
            skip(4); // string ID
            readPrefixedString();
        }
        else if (recType == RecordType.MemberReference)
            skip(4);
        else if (recType == RecordType.ObjectNull)
        {} // nothing
        else if (recType == RecordType.ObjectNullMultiple256)
            skip(1);
        else if (recType == RecordType.ObjectNullMultiple)
            skip(4);
    }

    // -- Primitive reading ---

    private void readPrimitiveValue(Sink)(PrimitiveType pType, Sink sink)
    {
        final switch (pType)
        {
        case PrimitiveType.Boolean:
            sink.handle(Boolean(readByte() != 0));
            break;
        case PrimitiveType.Byte:
            sink.handle(Numeric!string(to!string(readByte())));
            break;
        case PrimitiveType.SByte:
            sink.handle(Numeric!string(to!string(cast(byte) readByte())));
            break;
        case PrimitiveType.Int16:
            sink.handle(Numeric!string(to!string(readVal!short())));
            break;
        case PrimitiveType.UInt16:
            sink.handle(Numeric!string(to!string(readVal!ushort())));
            break;
        case PrimitiveType.Int32:
            sink.handle(Numeric!string(to!string(readInt32())));
            break;
        case PrimitiveType.UInt32:
            sink.handle(Numeric!string(to!string(readVal!uint())));
            break;
        case PrimitiveType.Int64:
            sink.handle(Numeric!string(to!string(readVal!long())));
            break;
        case PrimitiveType.UInt64:
            sink.handle(Numeric!string(to!string(readVal!ulong())));
            break;
        case PrimitiveType.Single:
            float f = readVal!float();
            import std.math : isNaN, isInfinity;
            if (f.isNaN)
                sink.handle(String!string("NaN"));
            else if (f.isInfinity)
                sink.handle(String!string(f > 0 ? "Infinity" : "-Infinity"));
            else
                sink.handle(Numeric!string(to!string(f)));
            break;
        case PrimitiveType.Double:
            double d = readVal!double();
            import std.math : isNaN, isInfinity;
            if (d.isNaN)
                sink.handle(String!string("NaN"));
            else if (d.isInfinity)
                sink.handle(String!string(d > 0 ? "Infinity" : "-Infinity"));
            else
                sink.handle(Numeric!string(to!string(d)));
            break;
        case PrimitiveType.Char:
            // UTF-8 encoded character (1-3 bytes)
            auto ch = readByte();
            if (ch < 0x80)
            {
                char[1] buf = [cast(char) ch];
                sink.handle(String!string(buf[].idup));
            }
            else
            {
                // Multi-byte: just emit as numeric
                sink.handle(Numeric!string(to!string(ch)));
            }
            break;
        case PrimitiveType.Decimal:
            // .NET Decimal is a 16-byte type, emit as string
            auto bytes = readBytes(16);
            import std.format : format;
            sink.handle(String!string(format!"%(%02x%)"(bytes)));
            break;
        case PrimitiveType.DateTime:
            // 8 bytes (ticks + kind)
            long ticks = readVal!long();
            sink.handle(Numeric!string(to!string(ticks)));
            break;
        case PrimitiveType.TimeSpan:
            long ticks = readVal!long();
            sink.handle(Numeric!string(to!string(ticks)));
            break;
        case PrimitiveType.Null:
            sink.handle(Null());
            break;
        case PrimitiveType.String:
            auto str = readPrefixedString();
            sink.handle(String!string(str));
            break;
        }
    }

    private void readStringValue(Sink)(Sink sink)
    {
        auto recType = readByte();

        if (recType == RecordType.BinaryObjectString)
        {
            int strId = readInt32();
            auto str = readPrefixedString();
            stringTable[strId] = str;
            sink.handle(String!string(str));
        }
        else if (recType == RecordType.MemberReference)
        {
            int refId = readInt32();
            if (auto s = refId in stringTable)
                sink.handle(String!string(*s));
            else
                throw new Exception("Unresolved string reference: " ~ to!string(refId));
        }
        else if (recType == RecordType.ObjectNull)
            sink.handle(Null());
        else if (recType == RecordType.ObjectNullMultiple256)
        {
            skip(1);
            sink.handle(Null());
        }
        else if (recType == RecordType.ObjectNullMultiple)
        {
            skip(4);
            sink.handle(Null());
        }
        else
            throw new Exception("Expected string record, got " ~ to!string(recType));
    }

    private void readStringArray(Sink)(Sink sink)
    {
        auto recType = readByte();

        if (recType == RecordType.ArraySingleString)
        {
            int arrayId = readInt32();
            int length = readInt32();

            StringArrayReader sar = {parser: &this, remaining: length};
            sink.handle(Array!(typeof(sar))(sar));
        }
        else if (recType == RecordType.MemberReference)
        {
            int refId = readInt32();
            // Array references in BinaryFormatter point to arrays
            // defined later in the stream. For now, emit null.
            sink.handle(Null());
        }
        else if (recType == RecordType.ObjectNull)
            sink.handle(Null());
        else
            throw new Exception("Expected array record, got " ~ to!string(recType));
    }

    // -- Low-level reading ---

    private ubyte readByte()
    {
        enforce(p < data.length, "Unexpected end of NRBF input");
        return data[p++];
    }

    private const(ubyte)[] readBytes(size_t n)
    {
        enforce(p + n <= data.length, "Unexpected end of NRBF input");
        auto result = data[p .. p + n];
        p += n;
        return result;
    }

    private void skip(size_t n)
    {
        enforce(p + n <= data.length, "Unexpected end of NRBF input");
        p += n;
    }

    private int readInt32()
    {
        auto bytes = readBytes(4);
        return littleEndianToNative!int(bytes[0 .. 4]);
    }

    private T readVal(T)()
    {
        auto bytes = readBytes(T.sizeof);
        return littleEndianToNative!T(bytes[0 .. T.sizeof]);
    }

    private string readPrefixedString()
    {
        // 7-bit encoded length
        size_t length = 0;
        int shift = 0;
        ubyte b;
        do
        {
            b = readByte();
            length |= cast(size_t)(b & 0x7F) << shift;
            shift += 7;
        } while (b & 0x80);

        enforce(p + length <= data.length, "String extends past end of NRBF input");
        auto result = cast(string) data[p .. p + length].idup;
        p += length;
        return result;
    }
}

// ---------------------------------------------------------------------------
// Reader structs
// ---------------------------------------------------------------------------

private struct FieldsReader
{
    NrbfParser* parser;
    string[] fieldNames;
    BinaryType[] fieldBinaryTypes;
    PrimitiveType[] fieldPrimTypes;

    void opCall(Sink)(Sink sink)
    {
        foreach (i; 0 .. fieldNames.length)
        {
            FieldNameReader nr = {name: fieldNames[i]};
            FieldValueReader vr = {
                parser: parser,
                bType: fieldBinaryTypes[i],
                pType: fieldPrimTypes[i],
            };
            sink.handle(Field!(typeof(nr), typeof(vr))(nr, vr));
        }
    }
}

private struct FieldNameReader
{
    string name;
    void opCall(Sink)(Sink sink)
    {
        sink.handle(String!string(name));
    }
}

private struct FieldValueReader
{
    NrbfParser* parser;
    BinaryType bType;
    PrimitiveType pType;

    void opCall(Sink)(Sink sink)
    {
        if (bType == BinaryType.Primitive)
            parser.readPrimitiveValue(pType, sink);
        else if (bType == BinaryType.String)
            parser.readStringValue(sink);
        else if (bType == BinaryType.StringArray)
            parser.readStringArray(sink);
        else if (bType == BinaryType.ObjectArray)
            parser.readStringArray(sink); // treat as generic array
        else
            throw new Exception("Unsupported BinaryType: " ~ to!string(cast(int) bType));
    }
}

private struct StringArrayReader
{
    NrbfParser* parser;
    int remaining;

    void opCall(Sink)(Sink sink)
    {
        foreach (_; 0 .. remaining)
            parser.readStringValue(sink);
    }
}

// ---------------------------------------------------------------------------
// Convenience functions
// ---------------------------------------------------------------------------

/// Parse .NET BinaryFormatter data into a D value.
T parseNrbf(T)(const(ubyte)[] data)
{
    auto parser = NrbfParser(data, 0);
    T result;
    auto sink = deserializer(&result);
    parser.read(sink);
    return result;
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

/// Build a .NET BinaryFormatter byte stream for testing.
/// Creates: header + BinaryLibrary + ClassWithMembersAndTypes + values + MessageEnd
private ubyte[] buildNrbfStream(string className, string assemblyName,
    string[] fieldNames, BinaryType[] bTypes, PrimitiveType[] pTypes,
    ubyte[] fieldValues)
{
    ubyte[] data;

    // SerializedStreamHeader: record type 0 + 16 bytes
    data ~= 0x00;
    data ~= [0x01, 0x00, 0x00, 0x00]; // rootId = 1
    data ~= [0x00, 0x00, 0x00, 0x00]; // headerId
    data ~= [0x01, 0x00, 0x00, 0x00]; // majorVersion = 1
    data ~= [0x00, 0x00, 0x00, 0x00]; // minorVersion = 0

    // BinaryLibrary
    data ~= cast(ubyte) RecordType.BinaryLibrary;
    data ~= litEnd(2); // library ID
    data ~= prefixStr(assemblyName);

    // ClassWithMembersAndTypes
    data ~= cast(ubyte) RecordType.ClassWithMembersAndTypes;
    data ~= litEnd(1); // object ID
    data ~= prefixStr(className);
    data ~= litEnd(cast(int) fieldNames.length); // field count

    foreach (name; fieldNames)
        data ~= prefixStr(name);

    foreach (bt; bTypes)
        data ~= cast(ubyte) bt;

    // Additional type info for primitives
    foreach (i; 0 .. bTypes.length)
        if (bTypes[i] == BinaryType.Primitive)
            data ~= cast(ubyte) pTypes[i];

    data ~= litEnd(2); // library ID reference

    // Field values
    data ~= fieldValues;

    // MessageEnd
    data ~= cast(ubyte) RecordType.MessageEnd;

    return data;
}

private ubyte[4] litEnd(int val)
{
    import std.bitmanip : nativeToLittleEndian;
    return nativeToLittleEndian(val);
}

private ubyte[] prefixStr(string s)
{
    ubyte[] result;
    // 7-bit encoded length
    size_t len = s.length;
    while (len >= 0x80)
    {
        result ~= cast(ubyte)(len | 0x80);
        len >>= 7;
    }
    result ~= cast(ubyte) len;
    result ~= cast(const(ubyte)[]) s;
    return result;
}

// Int32 field
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    values ~= nativeToLittleEndian(42)[]; // Int32 value

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["score"],
        [BinaryType.Primitive],
        [PrimitiveType.Int32],
        values
    );

    static struct S { int score; }
    auto result = parseNrbf!S(stream);
    assert(result.score == 42);
}

// Boolean field
debug(ae_unittest) unittest
{
    ubyte[] values;
    values ~= 0x01; // true

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["enabled"],
        [BinaryType.Primitive],
        [PrimitiveType.Boolean],
        values
    );

    static struct S { bool enabled; }
    auto result = parseNrbf!S(stream);
    assert(result.enabled == true);
}

// String field (inline BinaryObjectString)
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    values ~= cast(ubyte) RecordType.BinaryObjectString;
    values ~= nativeToLittleEndian(3)[]; // string ID
    values ~= prefixStr("hello");

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["name"],
        [BinaryType.String],
        [PrimitiveType.Null],
        values
    );

    static struct S { string name; }
    auto result = parseNrbf!S(stream);
    assert(result.name == "hello");
}

// Multiple fields
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    // String field
    values ~= cast(ubyte) RecordType.BinaryObjectString;
    values ~= nativeToLittleEndian(3)[];
    values ~= prefixStr("Alice");
    // Int32 field
    values ~= nativeToLittleEndian(99)[];
    // Boolean field
    values ~= 0x00; // false

    auto stream = buildNrbfStream(
        "Player", "GameAssembly",
        ["name", "score", "active"],
        [BinaryType.String, BinaryType.Primitive, BinaryType.Primitive],
        [PrimitiveType.Null, PrimitiveType.Int32, PrimitiveType.Boolean],
        values
    );

    static struct S { string name; int score; bool active; }
    auto result = parseNrbf!S(stream);
    assert(result.name == "Alice");
    assert(result.score == 99);
    assert(result.active == false);
}

// Double field
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    values ~= nativeToLittleEndian(3.14)[];

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["value"],
        [BinaryType.Primitive],
        [PrimitiveType.Double],
        values
    );

    static struct S { double value; }
    auto result = parseNrbf!S(stream);
    assert(result.value > 3.13 && result.value < 3.15);
}

// Float (Single) field
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    values ~= nativeToLittleEndian(2.5f)[];

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["value"],
        [BinaryType.Primitive],
        [PrimitiveType.Single],
        values
    );

    static struct S { float value; }
    auto result = parseNrbf!S(stream);
    assert(result.value > 2.4 && result.value < 2.6);
}

// Null string
debug(ae_unittest) unittest
{
    ubyte[] values;
    values ~= cast(ubyte) RecordType.ObjectNull;

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["name"],
        [BinaryType.String],
        [PrimitiveType.Null],
        values
    );

    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));
    auto result = parseNrbf!SO(stream);
    assert(result.type == SO.Type.object);
}

// String reference (MemberReference to previously defined string)
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    // First string: inline
    values ~= cast(ubyte) RecordType.BinaryObjectString;
    values ~= nativeToLittleEndian(3)[];
    values ~= prefixStr("shared");
    // Second string: reference to first
    values ~= cast(ubyte) RecordType.MemberReference;
    values ~= nativeToLittleEndian(3)[];

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["first", "second"],
        [BinaryType.String, BinaryType.String],
        [PrimitiveType.Null, PrimitiveType.Null],
        values
    );

    static struct S { string first; string second; }
    auto result = parseNrbf!S(stream);
    assert(result.first == "shared");
    assert(result.second == "shared");
}

// Inline string array (ArraySingleString)
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    // ArraySingleString record
    values ~= cast(ubyte) RecordType.ArraySingleString;
    values ~= nativeToLittleEndian(4)[]; // array ID
    values ~= nativeToLittleEndian(2)[]; // length = 2
    // Element 0: inline string
    values ~= cast(ubyte) RecordType.BinaryObjectString;
    values ~= nativeToLittleEndian(5)[];
    values ~= prefixStr("alpha");
    // Element 1: inline string
    values ~= cast(ubyte) RecordType.BinaryObjectString;
    values ~= nativeToLittleEndian(6)[];
    values ~= prefixStr("beta");

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["items"],
        [BinaryType.StringArray],
        [PrimitiveType.Null],
        values
    );

    static struct S { string[] items; }
    auto result = parseNrbf!S(stream);
    assert(result.items == ["alpha", "beta"]);
}

// Int64 field
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    values ~= nativeToLittleEndian(long(9876543210))[];

    auto stream = buildNrbfStream(
        "TestClass", "TestAssembly",
        ["bignum"],
        [BinaryType.Primitive],
        [PrimitiveType.Int64],
        values
    );

    static struct S { long bignum; }
    auto result = parseNrbf!S(stream);
    assert(result.bignum == 9876543210L);
}

// Parse into SerializedObject
debug(ae_unittest) unittest
{
    import std.bitmanip : nativeToLittleEndian;

    ubyte[] values;
    values ~= cast(ubyte) RecordType.BinaryObjectString;
    values ~= nativeToLittleEndian(3)[];
    values ~= prefixStr("test");
    values ~= nativeToLittleEndian(42)[];

    auto stream = buildNrbfStream(
        "Config", "App",
        ["name", "value"],
        [BinaryType.String, BinaryType.Primitive],
        [PrimitiveType.Null, PrimitiveType.Int32],
        values
    );

    import ae.utils.serialization.store : SerializedObject;
    alias SO = SerializedObject!(immutable(char));
    auto result = parseNrbf!SO(stream);
    assert(result.type == SO.Type.object);
}
