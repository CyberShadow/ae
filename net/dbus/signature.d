/**
 * D-Bus signature grammar and D type mappings.
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

module ae.net.dbus.signature;

import std.range.primitives : ElementType;
import std.traits : FieldNameTuple, KeyType, OriginalType, Unqual, ValueType,
	isAssociativeArray, isDynamicArray, isStaticArray;
import std.typecons : Tuple;

import ae.net.dbus.common;
import ae.net.dbus.value : DbusVariant;

debug(ae_unittest) import std.typecons : Nullable;
debug(ae_unittest) import std.variant : Algebraic;
debug(ae_unittest) import ae.sys.data : Data;

enum DbusSignatureMode
{
	body,
	variant,
}

enum DbusSignatureKind : char
{
	byte_ = 'y',
	boolean_ = 'b',
	int16_ = 'n',
	uint16_ = 'q',
	int32_ = 'i',
	uint32_ = 'u',
	int64_ = 'x',
	uint64_ = 't',
	double_ = 'd',
	string_ = 's',
	objectPath_ = 'o',
	signature_ = 'g',
	unixFd_ = 'h',
	array_ = 'a',
	struct_ = '(',
	dictionaryEntry_ = '{',
	variant_ = 'v',
}

package(ae.net.dbus) struct DbusNesting
{
	size_t arrayDepth;
	size_t structDepth;
	size_t containerDepth;
}

private DbusNesting maximumDbusNesting(scope const(DbusNesting)[] children)
{
	DbusNesting result;
	foreach (child; children)
	{
		if (child.arrayDepth > result.arrayDepth)
			result.arrayDepth = child.arrayDepth;
		if (child.structDepth > result.structDepth)
			result.structDepth = child.structDepth;
		if (child.containerDepth > result.containerDepth)
			result.containerDepth = child.containerDepth;
	}
	return result;
}

package(ae.net.dbus) DbusNesting dbusNesting(DbusSignatureKind kind,
	scope const(DbusNesting)[] children = null)
{
	auto result = maximumDbusNesting(children);
	switch (kind)
	{
		case DbusSignatureKind.array_:
			result.arrayDepth++;
			result.containerDepth++;
			break;

		case DbusSignatureKind.struct_:
			result.structDepth++;
			result.containerDepth++;
			break;

		case DbusSignatureKind.dictionaryEntry_:
		case DbusSignatureKind.variant_:
			result.containerDepth++;
			break;

		default:
			break;
	}

	if (result.arrayDepth > 32)
		throw new DbusValidationException("D-Bus signatures may nest at most 32 arrays");
	if (result.structDepth > 32)
		throw new DbusValidationException("D-Bus signatures may nest at most 32 structs");
	if (result.containerDepth > 64)
		throw new DbusValidationException("D-Bus signatures may nest at most 64 containers and variants");
	return result;
}

private final class DbusSignatureNode
{
	DbusSignatureKind kind;
	string text;
	DbusSignatureNode[] children;
	bool containsUnixFd;
	DbusNesting nesting;
}

struct DbusSignatureType
{
	private DbusSignatureNode node;

	@property DbusSignatureKind kind() const
	{
		assert(node !is null, "uninitialized D-Bus signature type");
		return node.kind;
	}

	@property char code() const
	{
		return cast(char) kind;
	}

	@property string text() const
	{
		assert(node !is null, "uninitialized D-Bus signature type");
		return node.text;
	}

	@property const(DbusSignatureType)[] children() const
	{
		assert(node !is null, "uninitialized D-Bus signature type");
		DbusSignatureType[] result;
		foreach (child; node.children)
		{
			DbusSignatureType value;
			value.node = cast(DbusSignatureNode) child;
			result ~= value;
		}
		return result;
	}

	@property size_t alignment() const
	{
		switch (kind)
		{
			case DbusSignatureKind.byte_:
			case DbusSignatureKind.signature_:
			case DbusSignatureKind.variant_:
				return 1;

			case DbusSignatureKind.int16_:
			case DbusSignatureKind.uint16_:
				return 2;

			case DbusSignatureKind.boolean_:
			case DbusSignatureKind.int32_:
			case DbusSignatureKind.uint32_:
			case DbusSignatureKind.string_:
			case DbusSignatureKind.objectPath_:
			case DbusSignatureKind.unixFd_:
			case DbusSignatureKind.array_:
				return 4;

			case DbusSignatureKind.int64_:
			case DbusSignatureKind.uint64_:
			case DbusSignatureKind.double_:
			case DbusSignatureKind.struct_:
			case DbusSignatureKind.dictionaryEntry_:
				return 8;

			default:
				assert(0, "unknown D-Bus signature kind");
		}
	}

	@property bool isBasic() const
	{
		switch (kind)
		{
			case DbusSignatureKind.byte_:
			case DbusSignatureKind.boolean_:
			case DbusSignatureKind.int16_:
			case DbusSignatureKind.uint16_:
			case DbusSignatureKind.int32_:
			case DbusSignatureKind.uint32_:
			case DbusSignatureKind.int64_:
			case DbusSignatureKind.uint64_:
			case DbusSignatureKind.double_:
			case DbusSignatureKind.string_:
			case DbusSignatureKind.objectPath_:
			case DbusSignatureKind.signature_:
			case DbusSignatureKind.unixFd_:
				return true;
			default:
				return false;
		}
	}

	@property bool isByteOnlySupported() const
	{
		assert(node !is null, "uninitialized D-Bus signature type");
		return !node.containsUnixFd;
	}

	@property bool containsUnixFd() const
	{
		assert(node !is null, "uninitialized D-Bus signature type");
		return node.containsUnixFd;
	}

	package(ae.net.dbus) @property DbusNesting nesting() const
	{
		assert(node !is null, "uninitialized D-Bus signature type");
		return node.nesting;
	}
}

struct DbusParsedSignature
{
	private string canonicalText;
	private DbusSignatureType[] parsedTypes;

	@property string text() const
	{
		return canonicalText;
	}

	@property const(DbusSignatureType)[] types() const
	{
		DbusSignatureType[] result;
		result.length = parsedTypes.length;
		foreach (index, type; parsedTypes)
		{
			result[index].node = cast(DbusSignatureNode) type.node;
		}
		return result;
	}

	@property bool isByteOnlySupported() const
	{
		foreach (type; parsedTypes)
			if (!type.isByteOnlySupported)
				return false;
		return true;
	}
}

private DbusSignatureType makeType(DbusSignatureKind kind, string text,
	DbusSignatureType[] children = null)
{
	auto node = new DbusSignatureNode;
	node.kind = kind;
	node.text = text.idup;
	node.children.length = children.length;
	DbusNesting[] childNesting;
	childNesting.length = children.length;
	foreach (index, child; children)
	{
		assert(child.node !is null, "invalid D-Bus signature child");
		node.children[index] = child.node;
		node.containsUnixFd |= child.containsUnixFd;
		childNesting[index] = child.nesting;
	}
	node.containsUnixFd |= kind == DbusSignatureKind.unixFd_;
	node.nesting = dbusNesting(kind, childNesting);

	DbusSignatureType result;
	result.node = node;
	return result;
}

private struct DbusSignatureParser
{
	string input;
	size_t offset;

	DbusSignatureType parseOne(bool allowDictionaryEntry)
	{
		if (offset == input.length)
			throw new DbusValidationException("truncated D-Bus signature");

		auto start = offset;
		auto code = input[offset++];
		switch (code)
		{
			case 'y': return makeType(DbusSignatureKind.byte_, input[start .. offset]);
			case 'b': return makeType(DbusSignatureKind.boolean_, input[start .. offset]);
			case 'n': return makeType(DbusSignatureKind.int16_, input[start .. offset]);
			case 'q': return makeType(DbusSignatureKind.uint16_, input[start .. offset]);
			case 'i': return makeType(DbusSignatureKind.int32_, input[start .. offset]);
			case 'u': return makeType(DbusSignatureKind.uint32_, input[start .. offset]);
			case 'x': return makeType(DbusSignatureKind.int64_, input[start .. offset]);
			case 't': return makeType(DbusSignatureKind.uint64_, input[start .. offset]);
			case 'd': return makeType(DbusSignatureKind.double_, input[start .. offset]);
			case 's': return makeType(DbusSignatureKind.string_, input[start .. offset]);
			case 'o': return makeType(DbusSignatureKind.objectPath_, input[start .. offset]);
			case 'g': return makeType(DbusSignatureKind.signature_, input[start .. offset]);
			case 'h': return makeType(DbusSignatureKind.unixFd_, input[start .. offset]);

			case 'v':
				return makeType(DbusSignatureKind.variant_, input[start .. offset]);

			case 'a':
				{
					auto child = parseOne(true);
					return makeType(DbusSignatureKind.array_, input[start .. offset], [child]);
				}

			case '(':
				{
					DbusSignatureType[] fields;
					while (true)
					{
						if (offset == input.length)
							throw new DbusValidationException("unterminated D-Bus struct signature");
						if (input[offset] == ')')
						{
							offset++;
							break;
						}
						fields ~= parseOne(false);
					}
					if (!fields.length)
						throw new DbusValidationException("D-Bus structs must not be empty");
					return makeType(DbusSignatureKind.struct_, input[start .. offset], fields);
				}

			case '{':
				if (!allowDictionaryEntry)
					throw new DbusValidationException("D-Bus dictionary entries are only valid as array elements");
				{
					auto key = parseDictionaryKey();
					auto value = parseOne(false);
					if (offset == input.length || input[offset] != '}')
						throw new DbusValidationException("unterminated D-Bus dictionary entry signature");
					offset++;
					return makeType(DbusSignatureKind.dictionaryEntry_, input[start .. offset], [key, value]);
				}

			default:
				throw new DbusValidationException("invalid or reserved D-Bus signature code");
		}
	}

	private DbusSignatureType parseDictionaryKey()
	{
		if (offset == input.length)
			throw new DbusValidationException("truncated D-Bus dictionary key signature");

		auto start = offset;
		auto code = input[offset++];
		switch (code)
		{
			case 'y': return makeType(DbusSignatureKind.byte_, input[start .. offset]);
			case 'b': return makeType(DbusSignatureKind.boolean_, input[start .. offset]);
			case 'n': return makeType(DbusSignatureKind.int16_, input[start .. offset]);
			case 'q': return makeType(DbusSignatureKind.uint16_, input[start .. offset]);
			case 'i': return makeType(DbusSignatureKind.int32_, input[start .. offset]);
			case 'u': return makeType(DbusSignatureKind.uint32_, input[start .. offset]);
			case 'x': return makeType(DbusSignatureKind.int64_, input[start .. offset]);
			case 't': return makeType(DbusSignatureKind.uint64_, input[start .. offset]);
			case 'd': return makeType(DbusSignatureKind.double_, input[start .. offset]);
			case 's': return makeType(DbusSignatureKind.string_, input[start .. offset]);
			case 'o': return makeType(DbusSignatureKind.objectPath_, input[start .. offset]);
			case 'g': return makeType(DbusSignatureKind.signature_, input[start .. offset]);
			case 'h': return makeType(DbusSignatureKind.unixFd_, input[start .. offset]);
			default:
				throw new DbusValidationException("D-Bus dictionary keys must have a basic type");
		}
	}
}

private DbusParsedSignature parseSignature(string text, DbusSignatureMode mode)
{
	auto copied = copyDbusText(text, "D-Bus signature");
	if (copied.length > 255)
		throw new DbusValidationException("D-Bus signatures are limited to 255 bytes");

	DbusSignatureParser parser = DbusSignatureParser(copied, 0);
	DbusSignatureType[] types;
	while (parser.offset < copied.length)
		types ~= parser.parseOne(false);

	if (mode == DbusSignatureMode.variant && types.length != 1)
		throw new DbusValidationException("D-Bus variants require exactly one complete type");

	DbusParsedSignature result;
	result.canonicalText = copied;
	result.parsedTypes = types.dup;
	return result;
}

DbusParsedSignature parseDbusBodySignature(string text)
{
	return parseSignature(text, DbusSignatureMode.body);
}

DbusSignatureType parseDbusVariantSignature(string text)
{
	auto parsed = parseSignature(text, DbusSignatureMode.variant);
	return parsed.parsedTypes[0];
}

struct DbusStructAttribute
{
}

enum DbusStruct = DbusStructAttribute.init;

private template hasDbusStructAttribute(T)
{
	static if (is(T == struct))
		enum bool hasDbusStructAttribute = (()
		{
			bool found = false;
			foreach (attribute; __traits(getAttributes, T))
				static if (is(typeof(attribute) == DbusStructAttribute))
					found = true;
			return found;
		})();
	else
		enum bool hasDbusStructAttribute = false;
}

struct DbusOut(T...)
{
	static assert(T.length > 0, "DbusOut must contain at least one result type");
	static foreach (Type; T)
		static assert(__traits(compiles, dbusSignature!Type),
			"DbusOut result types must have D-Bus signatures");
	alias Types = T;
	Tuple!T values;
}

private template isDbusOut(T)
{
	static if (is(T == DbusOut!Types, Types...))
		enum bool isDbusOut = true;
	else
		enum bool isDbusOut = false;
}

private template isValidDbusStruct(T)
{
	static if (!hasDbusStructAttribute!T)
		enum bool isValidDbusStruct = false;
	else
		enum bool isValidDbusStruct = (()
		{
			alias Fields = FieldNameTuple!T;
			if (!Fields.length)
				return false;

			foreach (member; __traits(allMembers, T))
			{
				bool isInstanceField;
				foreach (field; Fields)
					if (member == field)
						isInstanceField = true;
				if (!isInstanceField)
					return false;
			}

			foreach (field; Fields)
				if (__traits(getProtection, __traits(getMember, T, field)) != "public")
					return false;
			return true;
		})();
}

private template isDbusBasicKeyType(T)
{
	static if (!is(T == Unqual!T))
		enum bool isDbusBasicKeyType = false;
	else static if (is(T == ubyte) || is(T == bool) || is(T == short) ||
		is(T == ushort) || is(T == int) || is(T == uint) || is(T == long) ||
		is(T == ulong) || is(T == double) || is(T == string) ||
		is(T == DbusObjectPath) || is(T == DbusSignature))
		enum bool isDbusBasicKeyType = true;
	else static if (is(T == enum))
		enum bool isDbusBasicKeyType = isDbusBasicKeyType!(OriginalType!T);
	else
		enum bool isDbusBasicKeyType = false;
}

private template dbusStructSignature(T)
{
	static assert(isValidDbusStruct!T,
		"@DbusStruct values must contain only public instance fields and must not be empty");
	enum dbusStructSignature = (()
	{
		string result = "(";
		static foreach (field; FieldNameTuple!T)
			result ~= rawDbusSignature!(typeof(__traits(getMember, T.init, field)));
		return result ~ ")";
	})();
}

private template rawDbusSignature(T)
{
	static if (is(T == string))
		enum rawDbusSignature = "s";
	else static if (!is(T == Unqual!T))
		static assert(0, "qualified and shared D values do not have D-Bus signatures");
	else static if (isDbusOut!T)
		static assert(0, "DbusOut is only valid as a typed method result");
	else static if (is(T == ubyte))
		enum rawDbusSignature = "y";
	else static if (is(T == bool))
		enum rawDbusSignature = "b";
	else static if (is(T == short))
		enum rawDbusSignature = "n";
	else static if (is(T == ushort))
		enum rawDbusSignature = "q";
	else static if (is(T == int))
		enum rawDbusSignature = "i";
	else static if (is(T == uint))
		enum rawDbusSignature = "u";
	else static if (is(T == long))
		enum rawDbusSignature = "x";
	else static if (is(T == ulong))
		enum rawDbusSignature = "t";
	else static if (is(T == double))
		enum rawDbusSignature = "d";
	else static if (is(T == DbusObjectPath))
		enum rawDbusSignature = "o";
	else static if (is(T == DbusSignature))
		enum rawDbusSignature = "g";
	else static if (is(T == DbusVariant))
		enum rawDbusSignature = "v";
	else static if (is(T == enum))
		enum rawDbusSignature = rawDbusSignature!(OriginalType!T);
	else static if (isStaticArray!T)
		static assert(0, "static arrays do not have D-Bus signatures");
	else static if (isDynamicArray!T)
		enum rawDbusSignature = "a" ~ rawDbusSignature!(ElementType!T);
	else static if (isAssociativeArray!T)
	{
		static assert(isDbusBasicKeyType!(KeyType!T),
			"D-Bus associative-array keys must have basic D-Bus types");
		enum rawDbusSignature = "a{" ~ rawDbusSignature!(KeyType!T) ~
			rawDbusSignature!(ValueType!T) ~ "}";
	}
	else static if (hasDbusStructAttribute!T)
		enum rawDbusSignature = dbusStructSignature!T;
	else
		static assert(0, "this D type has no D-Bus signature");
}

private string validateMappedDbusSignature(string text)
{
	parseDbusBodySignature(text);
	return text;
}

template dbusSignature(T)
{
	enum dbusSignature = validateMappedDbusSignature(rawDbusSignature!T);
}

debug(ae_unittest)
private void expectDbusSignatureValidation(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusValidationException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private string dbusTestRepeat(char value, size_t count)
{
	char[] result;
	result.length = count;
	foreach (index; 0 .. count)
		result[index] = value;
	return result.idup;
}

debug(ae_unittest)
private string dbusTestNestedSignature(size_t arrayDepth, size_t structDepth,
	char leaf)
{
	string result;
	foreach (index; 0 .. arrayDepth)
		result ~= 'a';
	foreach (index; 0 .. structDepth)
		result ~= '(';
	result ~= leaf;
	foreach (index; 0 .. structDepth)
		result ~= ')';
	return result;
}

debug(ae_unittest)
private template DbusTestNestedArray(T, size_t depth)
{
	static if (depth == 0)
		alias DbusTestNestedArray = T;
	else
		alias DbusTestNestedArray = DbusTestNestedArray!(T, depth - 1)[];
}

debug(ae_unittest) @DbusStruct
private struct DbusTestNestedStruct(T)
{
	T value;
}

debug(ae_unittest)
private template DbusTestNestedStructType(T, size_t depth)
{
	static if (depth == 0)
		alias DbusTestNestedStructType = T;
	else
		alias DbusTestNestedStructType = DbusTestNestedStruct!(
			DbusTestNestedStructType!(T, depth - 1));
}

debug(ae_unittest) unittest
{
	auto emptyBody = parseDbusBodySignature("");
	assert(emptyBody.text == "");
	assert(emptyBody.types.length == 0);

	auto parsed = parseDbusBodySignature("ybnqiuxtdsogha{sv}(is)v");
	assert(parsed.types.length == 16);
	assert(parsed.types[0].kind == DbusSignatureKind.byte_);
	assert(parsed.types[11].kind == DbusSignatureKind.signature_);
	assert(parsed.types[12].kind == DbusSignatureKind.unixFd_);
	assert(parsed.types[12].isBasic);
	assert(!parsed.types[12].isByteOnlySupported);
	assert(parsed.types[13].kind == DbusSignatureKind.array_);
	assert(parsed.types[13].children[0].kind == DbusSignatureKind.dictionaryEntry_);
	assert(parsed.types[13].children[0].children[0].kind == DbusSignatureKind.string_);
	assert(parsed.types[13].children[0].children[1].kind == DbusSignatureKind.variant_);
	assert(parsed.types[14].kind == DbusSignatureKind.struct_);
	assert(parsed.types[14].children.length == 2);
	assert(parsed.types[15].kind == DbusSignatureKind.variant_);
	assert(!parsed.isByteOnlySupported);

	auto variant = parseDbusVariantSignature("a{sv}");
	assert(variant.kind == DbusSignatureKind.array_);
	assert(variant.text == "a{sv}");
}

debug(ae_unittest) unittest
{
	assert(parseDbusBodySignature(dbusTestRepeat('y', 255)).types.length == 255);
	expectDbusSignatureValidation({ parseDbusBodySignature(dbusTestRepeat('y', 256)); });

	auto arraysAtLimit = dbusTestNestedSignature(32, 0, 's');
	assert(parseDbusVariantSignature(arraysAtLimit).text == arraysAtLimit);
	expectDbusSignatureValidation({
		parseDbusVariantSignature(dbusTestNestedSignature(33, 0, 's'));
	});

	auto structsAtLimit = dbusTestNestedSignature(0, 32, 's');
	assert(parseDbusVariantSignature(structsAtLimit).text == structsAtLimit);
	expectDbusSignatureValidation({
		parseDbusVariantSignature(dbusTestNestedSignature(0, 33, 's'));
	});

	auto containersAtLimit = dbusTestNestedSignature(32, 32, 's');
	assert(parseDbusVariantSignature(containersAtLimit).text == containersAtLimit);
	expectDbusSignatureValidation({
		parseDbusVariantSignature(dbusTestNestedSignature(32, 32, 'v'));
	});
}

debug(ae_unittest) unittest
{
	foreach (text; ["a", "(", "()", "{sv}", "a{as}", "a{sv", "(s",
		"r", "m", ")"])
		expectDbusSignatureValidation({ parseDbusBodySignature(text); });
	expectDbusSignatureValidation({ parseDbusVariantSignature(""); });
	expectDbusSignatureValidation({ parseDbusVariantSignature("ss"); });

	char[] invalidUtf8 = [cast(char) 0xFF];
	expectDbusSignatureValidation({ parseDbusBodySignature(cast(string) invalidUtf8); });
	expectDbusSignatureValidation({ parseDbusBodySignature("s\0"); });
}

debug(ae_unittest) unittest
{
	enum TestEnum : ushort { first, second }
	@DbusStruct struct TestStruct
	{
		int id;
		string label;
	}
	@DbusStruct struct EmptyStruct
	{
	}
	@DbusStruct struct PrivateFieldStruct
	{
		private int id;
	}
	@DbusStruct struct StaticFieldStruct
	{
		int id;
		static int nextId;
	}
	struct PlainStruct
	{
		int id;
	}
	struct Box(T)
	{
		T value;
	}
	class GenericOutputClass(T)
	{
	}
	union GenericOutputUnion(T)
	{
		T value;
	}
	struct NonBasicKey
	{
		int id;
	}
	class UnsupportedClass
	{
	}
	interface UnsupportedInterface
	{
	}
	alias UnsupportedDelegate = void delegate();
	alias UnsupportedFunction = void function();
	alias RawOutput = DbusOut!int;
	alias NestedOutput = RawOutput[];
	@DbusStruct struct OutputFieldStruct
	{
		RawOutput value;
	}
	alias ArraysAtLimit = DbusTestNestedArray!(int, 32);
	alias ArraysOverLimit = DbusTestNestedArray!(int, 33);
	alias StructsAtLimit = DbusTestNestedStructType!(int, 32);
	alias StructsOverLimit = DbusTestNestedStructType!(int, 33);
	alias ContainersAtLimit = DbusTestNestedArray!(
		DbusTestNestedStructType!(int, 32), 30)[string];
	alias ContainersOverLimit = DbusTestNestedArray!(
		DbusTestNestedStructType!(int, 32), 31)[string];

	static assert(__traits(compiles, dbusSignature!ubyte));
	static assert(__traits(compiles, dbusSignature!bool));
	static assert(__traits(compiles, dbusSignature!short));
	static assert(__traits(compiles, dbusSignature!ushort));
	static assert(__traits(compiles, dbusSignature!int));
	static assert(__traits(compiles, dbusSignature!uint));
	static assert(__traits(compiles, dbusSignature!long));
	static assert(__traits(compiles, dbusSignature!ulong));
	static assert(__traits(compiles, dbusSignature!double));
	static assert(__traits(compiles, dbusSignature!string));
	static assert(__traits(compiles, dbusSignature!DbusObjectPath));
	static assert(__traits(compiles, dbusSignature!DbusSignature));
	static assert(__traits(compiles, dbusSignature!DbusVariant));
	static assert(__traits(compiles, dbusSignature!TestEnum));
	static assert(__traits(compiles, dbusSignature!(int[])));
	static assert(__traits(compiles, dbusSignature!(ubyte[])));
	static assert(__traits(compiles, dbusSignature!(DbusVariant[string])));
	static assert(__traits(compiles, dbusSignature!(int[DbusObjectPath])));
	static assert(__traits(compiles, dbusSignature!TestStruct));
	static assert(__traits(compiles, dbusSignature!ArraysAtLimit));
	static assert(__traits(compiles, dbusSignature!StructsAtLimit));
	static assert(__traits(compiles, dbusSignature!ContainersAtLimit));
	static assert(__traits(compiles, DbusOut!int));
	static assert(__traits(compiles, DbusOut!(int, string)));
	static assert(__traits(compiles, DbusOut!(int[])));
	static assert(__traits(compiles, DbusOut!(DbusVariant[string])));
	static assert(__traits(compiles, DbusOut!DbusVariant));
	static assert(__traits(compiles, DbusOut!TestEnum));
	static assert(__traits(compiles, DbusOut!DbusObjectPath));
	static assert(__traits(compiles, DbusOut!DbusSignature));
	static assert(__traits(compiles, DbusOut!TestStruct));
	static assert(__traits(compiles, DbusOut!ArraysAtLimit));
	static assert(__traits(compiles, DbusOut!StructsAtLimit));
	static assert(__traits(compiles, DbusOut!ContainersAtLimit));

	static assert(dbusSignature!ubyte == "y");
	static assert(dbusSignature!bool == "b");
	static assert(dbusSignature!short == "n");
	static assert(dbusSignature!ushort == "q");
	static assert(dbusSignature!int == "i");
	static assert(dbusSignature!uint == "u");
	static assert(dbusSignature!long == "x");
	static assert(dbusSignature!ulong == "t");
	static assert(dbusSignature!double == "d");
	static assert(dbusSignature!string == "s");
	static assert(dbusSignature!DbusObjectPath == "o");
	static assert(dbusSignature!DbusSignature == "g");
	static assert(dbusSignature!DbusVariant == "v");
	static assert(dbusSignature!TestEnum == "q");
	static assert(dbusSignature!(int[]) == "ai");
	static assert(dbusSignature!(ubyte[]) == "ay");
	static assert(dbusSignature!(DbusVariant[string]) == "a{sv}");
	static assert(dbusSignature!(int[DbusObjectPath]) == "a{oi}");
	static assert(dbusSignature!TestStruct == "(is)");

	static assert(!__traits(compiles, dbusSignature!byte));
	static assert(!__traits(compiles, dbusSignature!char));
	static assert(!__traits(compiles, dbusSignature!wchar));
	static assert(!__traits(compiles, dbusSignature!dchar));
	static assert(!__traits(compiles, dbusSignature!float));
	static assert(!__traits(compiles, dbusSignature!real));
	static assert(!__traits(compiles, dbusSignature!(int[2])));
	static assert(!__traits(compiles, dbusSignature!PlainStruct));
	static assert(!__traits(compiles, dbusSignature!EmptyStruct));
	static assert(!__traits(compiles, dbusSignature!PrivateFieldStruct));
	static assert(!__traits(compiles, dbusSignature!StaticFieldStruct));
	static assert(!__traits(compiles, dbusSignature!(string[NonBasicKey])));
	static assert(!__traits(compiles, dbusSignature!(int*)));
	static assert(!__traits(compiles, dbusSignature!UnsupportedClass));
	static assert(!__traits(compiles, dbusSignature!UnsupportedInterface));
	static assert(!__traits(compiles, dbusSignature!UnsupportedDelegate));
	static assert(!__traits(compiles, dbusSignature!(Nullable!int)));
	static assert(!__traits(compiles, dbusSignature!(Algebraic!(int, string))));
	static assert(!__traits(compiles, dbusSignature!Data));
	static assert(!__traits(compiles, dbusSignature!(const(int))));
	static assert(!__traits(compiles, dbusSignature!(immutable(int))));
	static assert(!__traits(compiles, dbusSignature!(shared(int))));
	static assert(!__traits(compiles, dbusSignature!(const(int[]))));
	static assert(!__traits(compiles, dbusSignature!RawOutput));
	static assert(!__traits(compiles, dbusSignature!NestedOutput));
	static assert(!__traits(compiles, dbusSignature!ArraysOverLimit));
	static assert(!__traits(compiles, dbusSignature!StructsOverLimit));
	static assert(!__traits(compiles, dbusSignature!ContainersOverLimit));
	static assert(!__traits(compiles, DbusOut!()));
	static assert(!__traits(compiles, DbusOut!(DbusOut!int)));
	// DMD 2.096's parser cannot parse a parenthesized type immediately
	// followed by `[...]` (e.g. `(DbusOut!int)[]`), so these go through
	// the `RawOutput` alias instead.
	static assert(!__traits(compiles, DbusOut!(RawOutput[])));
	static assert(!__traits(compiles, DbusOut!(RawOutput[1])));
	static assert(!__traits(compiles, DbusOut!(int[RawOutput])));
	static assert(!__traits(compiles, DbusOut!(RawOutput[int])));
	static assert(!__traits(compiles, DbusOut!OutputFieldStruct));
	static assert(!__traits(compiles, DbusOut!(Box!(DbusOut!int))));
	static assert(!__traits(compiles, DbusOut!(Tuple!(DbusOut!int))));
	static assert(!__traits(compiles, DbusOut!(Nullable!(DbusOut!int))));
	static assert(!__traits(compiles, DbusOut!(int*)));
	static assert(!__traits(compiles, DbusOut!(GenericOutputClass!int)));
	static assert(!__traits(compiles, DbusOut!(GenericOutputUnion!int)));
	static assert(!__traits(compiles, DbusOut!(GenericOutputClass!(DbusOut!int))));
	static assert(!__traits(compiles, DbusOut!(GenericOutputUnion!(DbusOut!int))));
	static assert(!__traits(compiles, DbusOut!UnsupportedFunction));
	static assert(!__traits(compiles, DbusOut!UnsupportedDelegate));
	static assert(!__traits(compiles, DbusValue.of!RawOutput(RawOutput.init)));
	static assert(!__traits(compiles, DbusValue.of!NestedOutput(NestedOutput.init)));
}
