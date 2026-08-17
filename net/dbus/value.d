/**
 * Immutable D-Bus dynamic values and message bodies.
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

module ae.net.dbus.value;

import std.range.primitives : ElementType;
import std.traits : FieldNameTuple, KeyType, OriginalType, ValueType,
	isAssociativeArray, isDynamicArray;

import ae.net.dbus.common;
import ae.net.dbus.signature;

package(ae.net.dbus) enum DbusValueKind
{
	byte_,
	boolean_,
	int16_,
	uint16_,
	int32_,
	uint32_,
	int64_,
	uint64_,
	double_,
	string_,
	objectPath_,
	signature_,
	array_,
	dictionaryEntry_,
	struct_,
	variant_,
}

package(ae.net.dbus) enum DbusArrayStorage
{
	values,
	bytes,
	dictionary,
}

private final class DbusValueNode
{
	DbusValueKind kind;
	string signatureText;

	ubyte byteValue;
	bool booleanValue;
	short int16Value;
	ushort uint16Value;
	int int32Value;
	uint uint32Value;
	long int64Value;
	ulong uint64Value;
	double doubleValue;
	string textValue;

	DbusArrayStorage arrayStorage;
	string elementSignature;
	ubyte[] byteValues;
	DbusValueNode[] children;
	DbusValueNode first;
	DbusValueNode second;
	DbusSignature variantSignature;
	DbusValueNode variantValue;
	DbusNesting nesting;
}

private DbusValueNode makeNode(DbusValueKind kind, string signatureText)
{
	auto node = new DbusValueNode;
	node.kind = kind;
	node.signatureText = signatureText.idup;
	return node;
}

private DbusValue wrap(const(DbusValueNode) node)
{
	assert(node !is null, "invalid D-Bus value node");
	DbusValue result;
	result.node = cast(DbusValueNode) node;
	return result;
}

private DbusValueNode[] childNodes(scope const(DbusValue)[] values)
{
	DbusValueNode[] result;
	foreach (value; values)
	{
		if (value.node is null)
			throw new DbusValidationException("D-Bus values must be initialized");
		result ~= cast(DbusValueNode) value.node;
	}
	return result;
}

private DbusNesting[] childNestings(scope const(DbusValueNode)[] values)
{
	DbusNesting[] result;
	result.length = values.length;
	foreach (index, value; values)
	{
		assert(value !is null, "invalid D-Bus value child");
		result[index] = value.nesting;
	}
	return result;
}

private DbusValue[] copyValues(scope const(DbusValue)[] values)
{
	DbusValue[] result;
	result.length = values.length;
	foreach (index, value; values)
		result[index].node = cast(DbusValueNode) value.node;
	return result;
}

private DbusValue[] wrapNodes(scope const(DbusValueNode)[] nodes)
{
	DbusValue[] result;
	result.length = nodes.length;
	foreach (index, node; nodes)
		result[index] = wrap(node);
	return result;
}

private string joinedSignatures(scope const(DbusValue)[] values,
	string prefix = null, string suffix = null)
{
	string result = prefix;
	foreach (value; values)
	{
		if (value.node is null)
			throw new DbusValidationException("D-Bus values must be initialized");
		result ~= value.node.signatureText;
	}
	return result ~ suffix;
}

private void requireValueSignature(const(DbusValueNode) node, string expected)
{
	if (node is null || node.signatureText != expected)
	{
		auto actual = node is null ? "<uninitialized>" : node.signatureText;
		throw new DbusTypeMismatchException("D-Bus value has signature " ~ actual ~
			" but " ~ expected ~ " was requested");
	}
}

private union DbusDoubleBits
{
	double value;
	ulong bits;
}

private bool dictionaryKeysEqual(const(DbusValueNode) left,
	const(DbusValueNode) right)
{
	assert(left !is null && right !is null);
	if (left.kind != right.kind)
		return false;

	switch (left.kind)
	{
		case DbusValueKind.byte_:
			return left.byteValue == right.byteValue;
		case DbusValueKind.boolean_:
			return left.booleanValue == right.booleanValue;
		case DbusValueKind.int16_:
			return left.int16Value == right.int16Value;
		case DbusValueKind.uint16_:
			return left.uint16Value == right.uint16Value;
		case DbusValueKind.int32_:
			return left.int32Value == right.int32Value;
		case DbusValueKind.uint32_:
			return left.uint32Value == right.uint32Value;
		case DbusValueKind.int64_:
			return left.int64Value == right.int64Value;
		case DbusValueKind.uint64_:
			return left.uint64Value == right.uint64Value;
		case DbusValueKind.double_:
			DbusDoubleBits leftBits;
			DbusDoubleBits rightBits;
			leftBits.value = left.doubleValue;
			rightBits.value = right.doubleValue;
			return leftBits.bits == rightBits.bits;
		case DbusValueKind.string_:
		case DbusValueKind.objectPath_:
		case DbusValueKind.signature_:
			return left.textValue == right.textValue;
		default:
			assert(0, "D-Bus dictionary keys must be basic values");
	}
}

struct DbusValue
{
	private DbusValueNode node;

	package(ae.net.dbus) @property DbusValueKind kind() const
	{
		if (node is null)
			throw new DbusValidationException("D-Bus values must be initialized");
		return node.kind;
	}

	package(ae.net.dbus) @property string wireSignature() const
	{
		if (node is null)
			throw new DbusValidationException("D-Bus values must be initialized");
		return node.signatureText;
	}

	package(ae.net.dbus) @property ubyte byteValue() const
	{
		assert(kind == DbusValueKind.byte_);
		return node.byteValue;
	}

	package(ae.net.dbus) @property bool booleanValue() const
	{
		assert(kind == DbusValueKind.boolean_);
		return node.booleanValue;
	}

	package(ae.net.dbus) @property short int16Value() const
	{
		assert(kind == DbusValueKind.int16_);
		return node.int16Value;
	}

	package(ae.net.dbus) @property ushort uint16Value() const
	{
		assert(kind == DbusValueKind.uint16_);
		return node.uint16Value;
	}

	package(ae.net.dbus) @property int int32Value() const
	{
		assert(kind == DbusValueKind.int32_);
		return node.int32Value;
	}

	package(ae.net.dbus) @property uint uint32Value() const
	{
		assert(kind == DbusValueKind.uint32_);
		return node.uint32Value;
	}

	package(ae.net.dbus) @property long int64Value() const
	{
		assert(kind == DbusValueKind.int64_);
		return node.int64Value;
	}

	package(ae.net.dbus) @property ulong uint64Value() const
	{
		assert(kind == DbusValueKind.uint64_);
		return node.uint64Value;
	}

	package(ae.net.dbus) @property double doubleValue() const
	{
		assert(kind == DbusValueKind.double_);
		return node.doubleValue;
	}

	package(ae.net.dbus) @property string textValue() const
	{
		assert(kind == DbusValueKind.string_ || kind == DbusValueKind.objectPath_ ||
			kind == DbusValueKind.signature_);
		return node.textValue;
	}

	package(ae.net.dbus) @property DbusArrayStorage arrayStorage() const
	{
		assert(kind == DbusValueKind.array_);
		return node.arrayStorage;
	}

	package(ae.net.dbus) @property string elementSignature() const
	{
		assert(kind == DbusValueKind.array_);
		return node.elementSignature;
	}

	package(ae.net.dbus) @property ubyte[] byteValues() const
	{
		assert(kind == DbusValueKind.array_ && arrayStorage == DbusArrayStorage.bytes);
		return node.byteValues.dup;
	}

	package(ae.net.dbus) @property const(DbusValue)[] childValues() const
	{
		assert(kind == DbusValueKind.array_ || kind == DbusValueKind.struct_);
		return wrapNodes(node.children);
	}

	package(ae.net.dbus) @property DbusValue dictionaryKey() const
	{
		assert(kind == DbusValueKind.dictionaryEntry_);
		return wrap(node.first);
	}

	package(ae.net.dbus) @property DbusValue dictionaryValue() const
	{
		assert(kind == DbusValueKind.dictionaryEntry_);
		return wrap(node.second);
	}

	package(ae.net.dbus) @property DbusSignature variantSignature() const
	{
		assert(kind == DbusValueKind.variant_);
		return node.variantSignature;
	}

	package(ae.net.dbus) @property DbusValue variantValue() const
	{
		assert(kind == DbusValueKind.variant_);
		return wrap(node.variantValue);
	}

	@property DbusSignature signature() const
	{
		if (node is null)
			throw new DbusValidationException("D-Bus values must be initialized");
		assert(node.kind != DbusValueKind.dictionaryEntry_,
			"dictionary entries are internal D-Bus array elements");
		return DbusSignature.parse(node.signatureText);
	}

	static DbusValue of(T)(auto ref T value)
	{
		enum expectedSignature = dbusSignature!T;
		static assert(expectedSignature.length > 0);

		static if (is(T == ubyte))
			return fromByte(value);
		else static if (is(T == bool))
			return fromBoolean(value);
		else static if (is(T == short))
			return fromInt16(value);
		else static if (is(T == ushort))
			return fromUInt16(value);
		else static if (is(T == int))
			return fromInt32(value);
		else static if (is(T == uint))
			return fromUInt32(value);
		else static if (is(T == long))
			return fromInt64(value);
		else static if (is(T == ulong))
			return fromUInt64(value);
		else static if (is(T == double))
			return fromDouble(value);
		else static if (is(T == string))
			return fromString(value);
		else static if (is(T == DbusObjectPath))
			return fromObjectPath(value);
		else static if (is(T == DbusSignature))
			return fromSignature(value);
		else static if (is(T == DbusVariant))
			return fromVariant(value);
		else static if (is(T == enum))
		{
			alias Base = OriginalType!T;
			return of!Base(cast(Base) value);
		}
		else static if (isDynamicArray!T)
		{
			alias Element = ElementType!T;
			static if (is(Element == ubyte))
				return fromByteArray(value);
			else
			{
				enum arraySignature = dbusSignature!T;
				DbusValue[] children;
				foreach (element; value)
					children ~= of!Element(element);
				return fromArray(DbusSignature.parse(arraySignature), children);
			}
		}
		else static if (isAssociativeArray!T)
		{
			alias Key = KeyType!T;
			alias Value = ValueType!T;
			enum dictionarySignature = dbusSignature!T;
			DbusValue[] keys;
			DbusValue[] values;
			foreach (key, item; value)
			{
				keys ~= of!Key(key);
				values ~= of!Value(item);
			}
			return fromDictionaryEntries(DbusSignature.parse(dictionarySignature), keys, values);
		}
		else static if (is(T == struct))
		{
			enum structSignature = dbusSignature!T;
			DbusValue[] fields;
			static foreach (field; FieldNameTuple!T)
				fields ~= of!(typeof(__traits(getMember, value, field)))(
					__traits(getMember, value, field));
			auto result = fromStruct(fields);
			assert(result.node.signatureText == structSignature);
			return result;
		}
		else
			static assert(0, "this D type cannot be converted to DbusValue");
	}

	T get(T)() const
	{
		enum expectedSignature = dbusSignature!T;
		requireValueSignature(node, expectedSignature);

		static if (is(T == ubyte))
			return node.byteValue;
		else static if (is(T == bool))
			return node.booleanValue;
		else static if (is(T == short))
			return node.int16Value;
		else static if (is(T == ushort))
			return node.uint16Value;
		else static if (is(T == int))
			return node.int32Value;
		else static if (is(T == uint))
			return node.uint32Value;
		else static if (is(T == long))
			return node.int64Value;
		else static if (is(T == ulong))
			return node.uint64Value;
		else static if (is(T == double))
			return node.doubleValue;
		else static if (is(T == string))
			return node.textValue.idup;
		else static if (is(T == DbusObjectPath))
			return DbusObjectPath.parse(node.textValue);
		else static if (is(T == DbusSignature))
			return DbusSignature.parse(node.textValue);
		else static if (is(T == DbusVariant))
			return DbusVariant.fromValue(node.variantSignature, wrap(node.variantValue));
		else static if (is(T == enum))
		{
			alias Base = OriginalType!T;
			return cast(T) wrap(node).get!Base;
		}
		else static if (isDynamicArray!T)
		{
			alias Element = ElementType!T;
			static if (is(Element == ubyte))
			{
				assert(node.arrayStorage == DbusArrayStorage.bytes);
				return node.byteValues.dup;
			}
			else
			{
				assert(node.arrayStorage == DbusArrayStorage.values);
				T result;
				result.length = node.children.length;
				foreach (index, child; node.children)
					result[index] = wrap(child).get!Element;
				return result;
			}
		}
		else static if (isAssociativeArray!T)
		{
			alias Key = KeyType!T;
			alias Value = ValueType!T;
			assert(node.arrayStorage == DbusArrayStorage.dictionary);
			T result;
			foreach (index, entry; node.children)
			{
				assert(entry.kind == DbusValueKind.dictionaryEntry_);
				foreach (previous; node.children[0 .. index])
				{
					assert(previous.kind == DbusValueKind.dictionaryEntry_);
					if (dictionaryKeysEqual(previous.first, entry.first))
						throw new DbusValidationException("D-Bus dictionaries must not contain duplicate keys");
				}
				auto key = wrap(entry.first).get!Key;
				if ((key in result) !is null)
					throw new DbusValidationException("D-Bus dictionaries must not contain duplicate keys");
				result[key] = wrap(entry.second).get!Value;
			}
			return result;
		}
		else static if (is(T == struct))
		{
			assert(node.kind == DbusValueKind.struct_);
			alias Fields = FieldNameTuple!T;
			assert(node.children.length == Fields.length);
			T result;
			static foreach (index, field; Fields)
				__traits(getMember, result, field) = wrap(node.children[index]).get!(
					typeof(__traits(getMember, result, field)));
			return result;
		}
		else
			static assert(0, "this D type cannot be extracted from DbusValue");
	}

	package(ae.net.dbus) static DbusValue fromByte(ubyte value)
	{
		auto node = makeNode(DbusValueKind.byte_, "y");
		node.byteValue = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromBoolean(bool value)
	{
		auto node = makeNode(DbusValueKind.boolean_, "b");
		node.booleanValue = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromInt16(short value)
	{
		auto node = makeNode(DbusValueKind.int16_, "n");
		node.int16Value = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromUInt16(ushort value)
	{
		auto node = makeNode(DbusValueKind.uint16_, "q");
		node.uint16Value = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromInt32(int value)
	{
		auto node = makeNode(DbusValueKind.int32_, "i");
		node.int32Value = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromUInt32(uint value)
	{
		auto node = makeNode(DbusValueKind.uint32_, "u");
		node.uint32Value = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromInt64(long value)
	{
		auto node = makeNode(DbusValueKind.int64_, "x");
		node.int64Value = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromUInt64(ulong value)
	{
		auto node = makeNode(DbusValueKind.uint64_, "t");
		node.uint64Value = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromDouble(double value)
	{
		auto node = makeNode(DbusValueKind.double_, "d");
		node.doubleValue = value;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromString(string value)
	{
		auto node = makeNode(DbusValueKind.string_, "s");
		node.textValue = copyDbusText(value, "D-Bus string");
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromObjectPath(DbusObjectPath value)
	{
		auto path = DbusObjectPath.parse(value.text);
		auto node = makeNode(DbusValueKind.objectPath_, "o");
		node.textValue = path.text;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromSignature(DbusSignature value)
	{
		auto signature = DbusSignature.parse(value.text);
		auto node = makeNode(DbusValueKind.signature_, "g");
		node.textValue = signature.text;
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromByteArray(scope const(ubyte)[] values)
	{
		auto node = makeNode(DbusValueKind.array_, "ay");
		node.arrayStorage = DbusArrayStorage.bytes;
		node.elementSignature = "y";
		node.byteValues = values.dup;
		node.nesting = dbusNesting(DbusSignatureKind.array_);
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromArray(DbusSignature signature,
		scope const(DbusValue)[] values)
	{
	auto parsed = parseDbusVariantSignature(signature.text);
	if (parsed.kind != DbusSignatureKind.array_)
		throw new DbusValidationException("D-Bus array values require an array signature");
	auto element = parsed.children[0];
	if (element.kind == DbusSignatureKind.dictionaryEntry_)
		throw new DbusValidationException("D-Bus dictionaries must use fromDictionaryEntries");
	if (!parsed.isByteOnlySupported)
		throw new DbusUnsupportedException("UNIX_FD values are not supported");
		foreach (value; values)
		{
			if (value.node is null || value.node.signatureText != element.text)
				throw new DbusValidationException("D-Bus array elements must share the array element signature");
		}
		if (element.kind == DbusSignatureKind.byte_)
		{
			ubyte[] bytes;
			bytes.length = values.length;
			foreach (index, value; values)
				bytes[index] = value.get!ubyte;
			return fromByteArray(bytes);
		}

		auto node = makeNode(DbusValueKind.array_, signature.text);
		node.arrayStorage = DbusArrayStorage.values;
		node.elementSignature = element.text.idup;
		node.children = childNodes(values);
		auto nestings = childNestings(node.children);
		nestings ~= element.nesting;
		node.nesting = dbusNesting(DbusSignatureKind.array_, nestings);
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromDictionaryEntries(DbusSignature signature,
		scope const(DbusValue)[] keys, scope const(DbusValue)[] values)
	{
		if (keys.length != values.length)
			throw new DbusValidationException("D-Bus dictionary keys and values must have equal lengths");
		auto parsed = parseDbusVariantSignature(signature.text);
		if (parsed.kind != DbusSignatureKind.array_ ||
			parsed.children[0].kind != DbusSignatureKind.dictionaryEntry_)
			throw new DbusValidationException("D-Bus dictionaries require an array-of-dictionary-entry signature");
		if (!parsed.isByteOnlySupported)
			throw new DbusUnsupportedException("UNIX_FD values are not supported");

		auto entryType = parsed.children[0];
		auto keyType = entryType.children[0];
		auto valueType = entryType.children[1];
		DbusValue[] entries;
		foreach (index; 0 .. keys.length)
		{
			if (keys[index].node is null || keys[index].node.signatureText != keyType.text ||
				values[index].node is null || values[index].node.signatureText != valueType.text)
				throw new DbusValidationException("D-Bus dictionary entries must match their signature");
			entries ~= fromDictionaryEntry(keys[index], values[index]);
		}

		auto node = makeNode(DbusValueKind.array_, signature.text);
		node.arrayStorage = DbusArrayStorage.dictionary;
		node.elementSignature = entryType.text.idup;
		node.children = childNodes(entries);
		auto nestings = childNestings(node.children);
		nestings ~= entryType.nesting;
		node.nesting = dbusNesting(DbusSignatureKind.array_, nestings);
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromStruct(scope const(DbusValue)[] values)
	{
		if (!values.length)
			throw new DbusValidationException("D-Bus structs must not be empty");
		auto signature = joinedSignatures(values, "(", ")");
		auto parsed = parseDbusVariantSignature(signature);
		if (!parsed.isByteOnlySupported)
			throw new DbusUnsupportedException("UNIX_FD values are not supported");

		auto node = makeNode(DbusValueKind.struct_, signature);
		node.children = childNodes(values);
		node.nesting = dbusNesting(DbusSignatureKind.struct_,
			childNestings(node.children));
		return wrap(node);
	}

	package(ae.net.dbus) static DbusValue fromVariant(const ref DbusVariant value)
	{
		if (!value.initialized)
			throw new DbusValidationException("D-Bus variants must be initialized");
		auto node = makeNode(DbusValueKind.variant_, "v");
		node.variantSignature = value.signature_;
		node.variantValue = cast(DbusValueNode) value.value_.node;
		node.nesting = value.nesting_;
		return wrap(node);
	}

	private static DbusValue fromDictionaryEntry(const ref DbusValue key,
		const ref DbusValue value)
	{
		assert(key.node !is null && value.node !is null);
		auto node = makeNode(DbusValueKind.dictionaryEntry_,
			"{" ~ key.node.signatureText ~ value.node.signatureText ~ "}");
		node.first = cast(DbusValueNode) key.node;
		node.second = cast(DbusValueNode) value.node;
		node.nesting = dbusNesting(DbusSignatureKind.dictionaryEntry_,
			[key.node.nesting, value.node.nesting]);
		return wrap(node);
	}
}

struct DbusVariant
{
	private DbusSignature signature_;
	private DbusValue value_;
	private DbusNesting nesting_;

	private @property bool initialized() const
	{
		return value_.node !is null;
	}

	static DbusVariant of(T)(auto ref T value)
	{
		auto stored = DbusValue.of!T(value);
		return fromValue(stored.signature, stored);
	}

	T get(T)() const
	{
		enum expected = dbusSignature!T;
		if (!initialized || signature_.text != expected)
		{
			auto actual = initialized ? signature_.text : "<uninitialized>";
			throw new DbusTypeMismatchException("D-Bus variant contains " ~ actual ~
				" but " ~ expected ~ " was requested");
		}
		return value_.get!T;
	}

	@property DbusSignature containedSignature() const
	{
		if (!initialized)
			throw new DbusValidationException("D-Bus variants must be initialized");
		return signature_;
	}

	package(ae.net.dbus) static DbusVariant fromValue(DbusSignature signature,
		DbusValue value)
	{
		auto parsed = parseDbusVariantSignature(signature.text);
		if (!parsed.isByteOnlySupported)
			throw new DbusUnsupportedException("UNIX_FD values are not supported");
		if (value.node is null || value.node.signatureText != signature.text)
			throw new DbusValidationException("D-Bus variant signatures must match their values");

		DbusVariant result;
		result.signature_ = DbusSignature.parse(signature.text);
		result.value_ = value;
		result.nesting_ = dbusNesting(DbusSignatureKind.variant_,
			[value.node.nesting]);
		return result;
	}
}

struct DbusBody
{
	private DbusValue[] bodyValues;
	private DbusSignature bodySignature;

	static DbusBody from(Args...)(auto ref Args args)
	{
		DbusValue[] values;
		static foreach (index, Arg; Args)
			values ~= DbusValue.of!Arg(args[index]);
		return fromValues(values);
	}

	static DbusBody fromValues(scope const(DbusValue)[] values)
	{
		DbusBody result;
		result.bodyValues = copyValues(values);
		result.bodySignature = DbusSignature.parse(joinedSignatures(values));
		return result;
	}

	@property const(DbusValue)[] values() const
	{
		return copyValues(bodyValues);
	}

	@property DbusSignature signature() const
	{
		return bodySignature;
	}
}

debug(ae_unittest)
private void expectDbusTypeMismatch(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusTypeMismatchException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private void expectDbusValidation(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusValidationException)
		caught = true;
	assert(caught);
}

debug(ae_unittest) unittest
{
	void assertRoundTrip(T)(T original)
	{
		auto stored = DbusValue.of!T(original);
		assert(stored.signature.text == dbusSignature!T);
		assert(stored.get!T() == original);
	}

	ubyte byteValue = 0xA5;
	bool booleanValue = true;
	short int16Value = -1234;
	ushort uint16Value = 5678;
	int int32Value = -12345678;
	uint uint32Value = 12345678;
	long int64Value = -1234567890123L;
	ulong uint64Value = 1234567890123UL;
	double doubleValue = -123.5;
	string stringValue = "D-Bus \u2713";
	auto pathValue = DbusObjectPath.parse("/org/example/Object");
	auto signatureValue = DbusSignature.parse("a{sv}");

	assertRoundTrip(byteValue);
	assertRoundTrip(booleanValue);
	assertRoundTrip(int16Value);
	assertRoundTrip(uint16Value);
	assertRoundTrip(int32Value);
	assertRoundTrip(uint32Value);
	assertRoundTrip(int64Value);
	assertRoundTrip(uint64Value);
	assertRoundTrip(doubleValue);
	assertRoundTrip(stringValue);
	assertRoundTrip(pathValue);
	assertRoundTrip(signatureValue);
}

debug(ae_unittest) unittest
{
	char[] textSource = "value".dup;
	auto storedText = DbusValue.of!string(cast(string) textSource);
	textSource[0] = 'X';
	textSource = null;
	assert(storedText.get!string() == "value");

	ubyte[] bytes = [1, 2, 3];
	auto storedBytes = DbusValue.of!(ubyte[])(bytes);
	bytes[0] = 9;
	bytes = null;
	assert(storedBytes.signature.text == "ay");
	assert(storedBytes.arrayStorage == DbusArrayStorage.bytes);
	assert(storedBytes.get!(ubyte[])() == [1, 2, 3]);
	DbusValue[] byteElements = [DbusValue.of!ubyte(1), DbusValue.of!ubyte(2)];
	auto compactArray = DbusValue.fromArray(DbusSignature.parse("ay"), byteElements);
	assert(compactArray.arrayStorage == DbusArrayStorage.bytes);
	assert(compactArray.get!(ubyte[])() == [1, 2]);

	int[] numbers = [1, -2, 3];
	auto storedNumbers = DbusValue.of!(int[])(numbers);
	numbers[0] = 99;
	numbers = null;
	assert(storedNumbers.signature.text == "ai");
	assert(storedNumbers.get!(int[])() == [1, -2, 3]);

	string[int] names;
	names[1] = "one";
	names[2] = "two";
	auto storedNames = DbusValue.of!(string[int])(names);
	names[1] = "changed";
	names = null;
	auto restoredNames = storedNames.get!(string[int])();
	assert(storedNames.signature.text == "a{is}");
	assert(restoredNames.length == 2);
	assert(restoredNames[1] == "one");
	assert(restoredNames[2] == "two");
}

debug(ae_unittest) unittest
{
	int count = 7;
	string name = "example";
	DbusVariant[string] properties;
	properties["count"] = DbusVariant.of!int(count);
	properties["name"] = DbusVariant.of!string(name);
	auto storedProperties = DbusValue.of!(DbusVariant[string])(properties);
	auto restoredProperties = storedProperties.get!(DbusVariant[string])();
	assert(storedProperties.signature.text == "a{sv}");
	assert(restoredProperties.length == 2);
	assert(restoredProperties["count"].get!int() == count);
	assert(restoredProperties["name"].get!string() == name);

	auto inner = DbusVariant.of!int(count);
	auto outer = DbusVariant.of!DbusVariant(inner);
	assert(outer.containedSignature.text == "v");
	auto restoredInner = outer.get!DbusVariant();
	assert(restoredInner.containedSignature.text == "i");
	assert(restoredInner.get!int() == count);
	auto storedOuter = DbusValue.of!DbusVariant(outer);
	auto restoredOuter = storedOuter.get!DbusVariant();
	auto restoredNestedInner = restoredOuter.get!DbusVariant();
	assert(restoredNestedInner.get!int() == count);
}

debug(ae_unittest) unittest
{
	DbusValue nestedArrays = DbusValue.of!int(1);
	foreach (index; 0 .. 31)
	{
		DbusValue[] children = [nestedArrays];
		nestedArrays = DbusValue.fromArray(DbusSignature.parse(
			"a" ~ nestedArrays.wireSignature), children);
	}
	auto arraysAtLimit = DbusVariant.fromValue(nestedArrays.signature, nestedArrays);
	DbusValue[] arrayVariantValues = [DbusValue.fromVariant(arraysAtLimit)];
	auto outerArrayAtLimit = DbusValue.fromArray(DbusSignature.parse("av"),
		arrayVariantValues);
	assert(outerArrayAtLimit.signature.text == "av");

	auto oneMoreArrayVariant = DbusVariant.fromValue(outerArrayAtLimit.signature,
		outerArrayAtLimit);
	DbusValue[] oneMoreArrayVariantValues = [DbusValue.fromVariant(
		oneMoreArrayVariant)];
	expectDbusValidation({
		DbusValue.fromArray(DbusSignature.parse("av"),
			oneMoreArrayVariantValues);
	});

	DbusValue nestedStructs = DbusValue.of!int(1);
	foreach (index; 0 .. 31)
	{
		DbusValue[] fields = [nestedStructs];
		nestedStructs = DbusValue.fromStruct(fields);
	}
	auto structsAtLimit = DbusVariant.fromValue(nestedStructs.signature, nestedStructs);
	DbusValue[] structVariantFields = [DbusValue.fromVariant(structsAtLimit)];
	auto outerStructAtLimit = DbusValue.fromStruct(structVariantFields);
	assert(outerStructAtLimit.signature.text == "(v)");

	auto oneMoreStructVariant = DbusVariant.fromValue(outerStructAtLimit.signature,
		outerStructAtLimit);
	DbusValue[] oneMoreStructVariantFields = [DbusValue.fromVariant(
		oneMoreStructVariant)];
	expectDbusValidation({ DbusValue.fromStruct(oneMoreStructVariantFields); });

	DbusVariant nestedVariants = DbusVariant.of!int(1);
	foreach (index; 1 .. 64)
		nestedVariants = DbusVariant.of!DbusVariant(nestedVariants);
	assert(nestedVariants.containedSignature.text == "v");
	expectDbusValidation({ DbusVariant.of!DbusVariant(nestedVariants); });

	DbusValue dictionaryDepth = DbusValue.of!int(1);
	foreach (index; 0 .. 30)
	{
		DbusValue[] children = [dictionaryDepth];
		dictionaryDepth = DbusValue.fromArray(DbusSignature.parse(
			"a" ~ dictionaryDepth.wireSignature), children);
	}
	foreach (index; 0 .. 31)
	{
		DbusValue[] fields = [dictionaryDepth];
		dictionaryDepth = DbusValue.fromStruct(fields);
	}
	auto containedDictionaryVariant = DbusVariant.fromValue(
		dictionaryDepth.signature, dictionaryDepth);
	auto dictionaryVariant = DbusValue.fromVariant(containedDictionaryVariant);
	DbusValue[] dictionaryKeys = [DbusValue.of!string("key")];
	DbusValue[] dictionaryValues = [dictionaryVariant];
	auto dictionaryAtLimit = DbusValue.fromDictionaryEntries(
		DbusSignature.parse("a{sv}"), dictionaryKeys, dictionaryValues);
	assert(dictionaryAtLimit.signature.text == "a{sv}");
	DbusValue[] oneMoreDictionaryFields = [dictionaryAtLimit];
	expectDbusValidation({ DbusValue.fromStruct(oneMoreDictionaryFields); });
}

debug(ae_unittest) unittest
{
	enum UnnamedDiscriminant
	{
		first = 1,
		second = 2,
	}
	@DbusStruct struct ConsumerSettings
	{
		string service;
		uint revision;
		DbusVariant[string] properties;
	}

	UnnamedDiscriminant enumValue = cast(UnnamedDiscriminant) 37;
	auto storedEnum = DbusValue.of!UnnamedDiscriminant(enumValue);
	assert(storedEnum.signature.text == "i");
	assert(cast(int) storedEnum.get!UnnamedDiscriminant() == 37);

	uint revision = 3;
	string mode = "fast";
	ConsumerSettings original;
	original.service = "org.example.Service";
	original.revision = revision;
	original.properties["mode"] = DbusVariant.of!string(mode);
	auto storedSettings = DbusValue.of!ConsumerSettings(original);
	original.service = "changed";
	original.revision = 99;
	original.properties["mode"] = DbusVariant.of!string("changed");
	auto restoredSettings = storedSettings.get!ConsumerSettings();
	assert(storedSettings.signature.text == "(sua{sv})");
	assert(restoredSettings.service == "org.example.Service");
	assert(restoredSettings.revision == revision);
	assert(restoredSettings.properties["mode"].get!string() == mode);
}

debug(ae_unittest) unittest
{
	@DbusStruct struct Result
	{
		string text;
		uint count;
	}

	int number = 42;
	string text = "answer";
	auto emptyBody = DbusBody.from();
	assert(emptyBody.signature.text == "");
	assert(emptyBody.values.length == 0);
	Result result = Result(text, cast(uint) number);
	auto structValue = DbusValue.of!Result(result);
	DbusValue[] bodyValues = [structValue, DbusValue.of!uint(cast(uint) number)];
	auto body = DbusBody.fromValues(bodyValues);
	bodyValues[0] = DbusValue.of!string("changed");
	bodyValues = null;
	DbusValue[] fields = [DbusValue.of!int(number), DbusValue.of!string(text)];
	auto structure = DbusValue.fromStruct(fields);
	assert(body.signature.text == "(su)u");
	assert(body.values.length == 2);
	assert(body.values[0].get!Result().text == text);
	assert(body.values[1].get!uint() == number);
	assert(structure.signature.text == "(is)");

	DbusValue[] duplicateKeys = [DbusValue.of!string("same"), DbusValue.of!string("same")];
	DbusValue[] duplicateValues = [DbusValue.of!int(1), DbusValue.of!int(2)];
	auto duplicateDictionary = DbusValue.fromDictionaryEntries(
		DbusSignature.parse("a{si}"), duplicateKeys, duplicateValues);
	expectDbusValidation({ duplicateDictionary.get!(int[string])(); });

	DbusDoubleBits nanBits;
	nanBits.bits = 0x7ff8_0000_0000_0001UL;
	auto nan = nanBits.value;
	DbusValue[] singleNanKeys = [DbusValue.of!double(nan)];
	DbusValue[] singleNanValues = [DbusValue.of!int(1)];
	auto singleNanDictionary = DbusValue.fromDictionaryEntries(
		DbusSignature.parse("a{di}"), singleNanKeys, singleNanValues);
	assert(singleNanDictionary.get!(int[double])().length == 1);

	DbusValue[] duplicateNanKeys = [DbusValue.of!double(nan), DbusValue.of!double(nan)];
	DbusValue[] duplicateNanValues = [DbusValue.of!int(1), DbusValue.of!int(2)];
	auto duplicateNanDictionary = DbusValue.fromDictionaryEntries(
		DbusSignature.parse("a{di}"), duplicateNanKeys, duplicateNanValues);
	expectDbusValidation({ duplicateNanDictionary.get!(int[double])(); });

	DbusValue[] signedZeroKeys = [DbusValue.of!double(0.0), DbusValue.of!double(-0.0)];
	DbusValue[] signedZeroValues = [DbusValue.of!int(1), DbusValue.of!int(2)];
	auto signedZeroDictionary = DbusValue.fromDictionaryEntries(
		DbusSignature.parse("a{di}"), signedZeroKeys, signedZeroValues);
	expectDbusValidation({ signedZeroDictionary.get!(int[double])(); });

	auto dictionarySignature = DbusSignature.parse("a{si}");
	DbusValue[] noEntries;
	expectDbusValidation({ DbusValue.fromArray(dictionarySignature, noEntries); });
	DbusValue[] oneEntry = [DbusValue.of!int(1)];
	expectDbusValidation({ DbusValue.fromArray(dictionarySignature, oneEntry); });
	DbusValue[] dictionaryKeys = [DbusValue.of!string("one")];
	DbusValue[] dictionaryValues = [DbusValue.of!int(1)];
	auto dictionary = DbusValue.fromDictionaryEntries(dictionarySignature,
		dictionaryKeys, dictionaryValues);
	assert(dictionary.arrayStorage == DbusArrayStorage.dictionary);
	assert(dictionary.childValues.length == 1);
	assert(dictionary.childValues[0].kind == DbusValueKind.dictionaryEntry_);
	assert(dictionary.childValues[0].wireSignature == "{si}");
	assert(dictionary.get!(int[string])()["one"] == 1);

	auto integerValue = DbusValue.of!int(number);
	expectDbusTypeMismatch({ integerValue.get!string(); });
	auto integerVariant = DbusVariant.of!int(number);
	expectDbusTypeMismatch({ integerVariant.get!string(); });
}
