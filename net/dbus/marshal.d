/**
 * D-Bus wire marshaling and complete message framing.
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

module ae.net.dbus.marshal;

import ae.sys.data : Data;

import ae.net.dbus.common;
import ae.net.dbus.signature;
import ae.net.dbus.value;

package(ae.net.dbus) enum ulong dbusMaxArrayDataBytes = 1UL << 26;
package(ae.net.dbus) enum ulong dbusMaxMessageBytes = 1UL << 27;

/**
 * Performs the cursor arithmetic shared by the wire reader, writer and
 * incremental frame decoder without allocating storage.
 */
package(ae.net.dbus) bool dbusCheckedCursorEnd(ulong offset, ulong length,
	ulong limit, out size_t end) pure
{
	if (offset > limit || length > limit - offset || limit > cast(ulong) size_t.max)
		return false;
	end = cast(size_t) (offset + length);
	return true;
}

package(ae.net.dbus) bool dbusCheckedAlignedOffset(ulong offset,
	size_t alignment, ulong limit, out size_t aligned) pure
{
	assert(alignment == 1 || alignment == 2 || alignment == 4 || alignment == 8);
	auto remainder = offset % alignment;
	auto padding = remainder ? alignment - remainder : 0;
	return dbusCheckedCursorEnd(offset, padding, limit, aligned);
}

package(ae.net.dbus) bool dbusArrayDataLengthIsValid(ulong length) pure
{
	return length <= dbusMaxArrayDataBytes;
}

/**
 * Validates a fixed-header pair of lengths and returns the exact complete
 * message length.  The header array is itself an ARRAY and consequently has
 * the same 2^26-byte data limit as every other D-Bus array.
 */
package(ae.net.dbus) bool dbusCheckedMessageLength(ulong headerDataLength,
	ulong bodyLength, out size_t length) pure
{
	if (!dbusArrayDataLengthIsValid(headerDataLength))
		return false;

	size_t headerEnd;
	if (!dbusCheckedCursorEnd(16, headerDataLength, dbusMaxMessageBytes, headerEnd))
		return false;

	size_t bodyStart;
	if (!dbusCheckedAlignedOffset(headerEnd, 8, dbusMaxMessageBytes, bodyStart))
		return false;

	return dbusCheckedCursorEnd(bodyStart, bodyLength, dbusMaxMessageBytes, length);
}

private DbusByteOrder parseDbusByteOrder(ubyte value)
{
	if (value == DbusByteOrder.littleEndian)
		return DbusByteOrder.littleEndian;
	if (value == DbusByteOrder.bigEndian)
		return DbusByteOrder.bigEndian;
	throw new DbusProtocolException("D-Bus messages must begin with byte order 'l' or 'B'");
}

private uint readFixedUInt32(scope const(ubyte)[] bytes, size_t offset,
	DbusByteOrder order)
{
	assert(offset <= bytes.length && bytes.length - offset >= uint.sizeof);
	if (order == DbusByteOrder.littleEndian)
		return cast(uint) bytes[offset] |
			(cast(uint) bytes[offset + 1] << 8) |
			(cast(uint) bytes[offset + 2] << 16) |
			(cast(uint) bytes[offset + 3] << 24);
	return cast(uint) bytes[offset + 3] |
		(cast(uint) bytes[offset + 2] << 8) |
		(cast(uint) bytes[offset + 1] << 16) |
		(cast(uint) bytes[offset] << 24);
}

private struct DbusFixedHeader
{
	DbusByteOrder order;
	uint bodyLength;
	uint serial;
	uint headerDataLength;
	size_t completeLength;
}

/**
 * Validates the fixed portion which is available to both complete-message and
 * incremental decoding before either reader may retain more peer bytes.
 */
private DbusFixedHeader validateDbusFixedHeader(
	scope const(ubyte)[] fixedHeader)
{
	if (fixedHeader.length < 16)
		throw new DbusProtocolException("truncated D-Bus fixed header");

	DbusFixedHeader result;
	result.order = parseDbusByteOrder(fixedHeader[0]);
	if (fixedHeader[1] == DbusMessageType.invalid)
		throw new DbusProtocolException("D-Bus message type zero is invalid");
	if (fixedHeader[3] != 1)
		throw new DbusProtocolException("unsupported D-Bus major protocol version");
	result.bodyLength = readFixedUInt32(fixedHeader, 4, result.order);
	result.serial = readFixedUInt32(fixedHeader, 8, result.order);
	result.headerDataLength = readFixedUInt32(fixedHeader, 12, result.order);
	if (result.serial == 0)
		throw new DbusProtocolException("D-Bus sender serial must be nonzero");
	if (!dbusCheckedMessageLength(result.headerDataLength, result.bodyLength,
		result.completeLength))
		throw new DbusProtocolException("D-Bus message exceeds protocol size limits");
	return result;
}

/**
 * Validates just enough of an available fixed header for an incremental
 * decoder to determine the bounded frame length.
 */
package(ae.net.dbus) size_t dbusMessageLengthFromFixedHeader(
	scope const(ubyte)[] fixedHeader)
{
	return validateDbusFixedHeader(fixedHeader).completeLength;
}

private class DbusOutgoingValidationException : DbusValidationException
{
	this(string message)
	{
		super(message);
	}
}

private struct DbusWriter
{
	DbusByteOrder order;
	Data output;
	size_t writeLimit;

	this(DbusByteOrder order)
	{
		if (order != DbusByteOrder.littleEndian && order != DbusByteOrder.bigEndian)
			throw new DbusOutgoingValidationException("D-Bus output requires byte order 'l' or 'B'");
		this.order = order;
		writeLimit = cast(size_t) dbusMaxMessageBytes;
	}

	@property size_t position() const
	{
		return output.length;
	}

	private void reserve(size_t amount)
	{
		size_t end;
		if (!dbusCheckedCursorEnd(position, amount, writeLimit, end))
			throw new DbusOutgoingValidationException("D-Bus message exceeds protocol size limits");
	}

	void writeByte(ubyte value)
	{
		reserve(1);
		output ~= value;
	}

	void writeBytes(scope const(ubyte)[] values)
	{
		reserve(values.length);
		output ~= values;
	}

	void alignTo(size_t alignment)
	{
		size_t aligned;
		if (!dbusCheckedAlignedOffset(position, alignment, writeLimit, aligned))
			throw new DbusOutgoingValidationException("D-Bus message alignment exceeds protocol size limits");
		while (position < aligned)
			writeByte(0);
	}

	void writeUInt16(ushort value)
	{
		if (order == DbusByteOrder.littleEndian)
		{
			writeByte(cast(ubyte) value);
			writeByte(cast(ubyte) (value >> 8));
		}
		else
		{
			writeByte(cast(ubyte) (value >> 8));
			writeByte(cast(ubyte) value);
		}
	}

	void writeUInt32(uint value)
	{
		if (order == DbusByteOrder.littleEndian)
		{
			foreach (index; 0 .. 4)
				writeByte(cast(ubyte) (value >> (index * 8)));
		}
		else
		{
			foreach_reverse (index; 0 .. 4)
				writeByte(cast(ubyte) (value >> (index * 8)));
		}
	}

	void writeUInt64(ulong value)
	{
		if (order == DbusByteOrder.littleEndian)
		{
			foreach (index; 0 .. 8)
				writeByte(cast(ubyte) (value >> (index * 8)));
		}
		else
		{
			foreach_reverse (index; 0 .. 8)
				writeByte(cast(ubyte) (value >> (index * 8)));
		}
	}

	void patchUInt32(size_t offset, uint value)
	{
		if (offset > output.length || output.length - offset < uint.sizeof)
			throw new DbusOutgoingValidationException("invalid D-Bus fixed-header patch");
		if (order == DbusByteOrder.littleEndian)
		{
			foreach (index; 0 .. 4)
				output[offset + index] = cast(ubyte) (value >> (index * 8));
		}
		else
		{
			foreach (index; 0 .. 4)
				output[offset + index] = cast(ubyte) (value >> ((3 - index) * 8));
		}
	}

	void patchByte(size_t offset, ubyte value)
	{
		if (offset >= output.length)
			throw new DbusOutgoingValidationException("invalid D-Bus fixed-header patch");
		output[offset] = value;
	}

	void writeText32(string value)
	{
		auto bytes = cast(const(ubyte)[]) value;
		if (bytes.length > uint.max)
			throw new DbusOutgoingValidationException("D-Bus string exceeds UINT32 length");
		writeUInt32(cast(uint) bytes.length);
		writeBytes(bytes);
		writeByte(0);
	}

	void writeSignatureText(string value)
	{
		auto bytes = cast(const(ubyte)[]) value;
		if (bytes.length > ubyte.max)
			throw new DbusOutgoingValidationException("D-Bus signature exceeds UINT8 length");
		writeByte(cast(ubyte) bytes.length);
		writeBytes(bytes);
		writeByte(0);
	}

	private size_t limitArrayData()
	{
		auto previous = writeLimit;
		size_t arrayEnd;
		if (dbusCheckedCursorEnd(position, dbusMaxArrayDataBytes, writeLimit,
			arrayEnd))
			writeLimit = arrayEnd;
		return previous;
	}

	private void restoreLimit(size_t previous)
	{
		assert(previous >= position);
		writeLimit = previous;
	}

	void writeValue(const(DbusSignatureType) type, const(DbusValue) value)
	{
		if (!type.isByteOnlySupported)
			throw new DbusUnsupportedException("UNIX_FD values are not supported");
		if (value.wireSignature != type.text)
			throw new DbusOutgoingValidationException("D-Bus value does not match its wire signature");

		alignTo(type.alignment);
		switch (type.kind)
		{
			case DbusSignatureKind.byte_:
				writeByte(value.byteValue);
				return;

			case DbusSignatureKind.boolean_:
				writeUInt32(value.booleanValue ? 1 : 0);
				return;

			case DbusSignatureKind.int16_:
				writeUInt16(cast(ushort) value.int16Value);
				return;

			case DbusSignatureKind.uint16_:
				writeUInt16(value.uint16Value);
				return;

			case DbusSignatureKind.int32_:
				writeUInt32(cast(uint) value.int32Value);
				return;

			case DbusSignatureKind.uint32_:
				writeUInt32(value.uint32Value);
				return;

			case DbusSignatureKind.int64_:
				writeUInt64(cast(ulong) value.int64Value);
				return;

			case DbusSignatureKind.uint64_:
				writeUInt64(value.uint64Value);
				return;

			case DbusSignatureKind.double_:
				DbusDoubleBits doubleBits;
				doubleBits.value = value.doubleValue;
				writeUInt64(doubleBits.bits);
				return;

			case DbusSignatureKind.string_:
			case DbusSignatureKind.objectPath_:
				writeText32(value.textValue);
				return;

			case DbusSignatureKind.signature_:
				writeSignatureText(value.textValue);
				return;

			case DbusSignatureKind.array_:
				writeArray(type, value);
				return;

			case DbusSignatureKind.struct_:
				writeStruct(type, value);
				return;

			case DbusSignatureKind.variant_:
				writeVariant(value);
				return;

			case DbusSignatureKind.dictionaryEntry_:
				throw new DbusOutgoingValidationException("D-Bus dictionary entries are only valid as array elements");

			case DbusSignatureKind.unixFd_:
				throw new DbusUnsupportedException("UNIX_FD values are not supported");

			default:
				assert(0, "unknown D-Bus signature kind");
		}
	}

	private void writeArray(const(DbusSignatureType) type, const(DbusValue) value)
	{
		auto types = type.children;
		assert(types.length == 1);
		auto element = types[0];
		auto lengthOffset = position;
		writeUInt32(0);
		alignTo(element.alignment);
		auto dataStart = position;
		auto previousLimit = limitArrayData();

		if (element.kind == DbusSignatureKind.byte_)
		{
			if (value.arrayStorage != DbusArrayStorage.bytes)
				throw new DbusOutgoingValidationException("D-Bus byte arrays require compact byte storage");
			writeBytes(value.byteValues);
		}
		else if (element.kind == DbusSignatureKind.dictionaryEntry_)
		{
			if (value.arrayStorage != DbusArrayStorage.dictionary)
				throw new DbusOutgoingValidationException("D-Bus dictionaries require dictionary storage");
			auto entryTypes = element.children;
			assert(entryTypes.length == 2);
			foreach (entry; value.childValues)
			{
				if (entry.kind != DbusValueKind.dictionaryEntry_)
					throw new DbusOutgoingValidationException("D-Bus dictionary storage contains a non-entry value");
				alignTo(8);
				writeValue(entryTypes[0], entry.dictionaryKey);
				writeValue(entryTypes[1], entry.dictionaryValue);
			}
		}
		else
		{
			if (value.arrayStorage != DbusArrayStorage.values)
				throw new DbusOutgoingValidationException("D-Bus arrays require value storage");
			foreach (child; value.childValues)
				writeValue(element, child);
		}
		restoreLimit(previousLimit);

		auto dataLength = position - dataStart;
		if (!dbusArrayDataLengthIsValid(dataLength) || dataLength > uint.max)
			throw new DbusOutgoingValidationException("D-Bus array data exceeds protocol size limits");
		patchUInt32(lengthOffset, cast(uint) dataLength);
	}

	private void writeStruct(const(DbusSignatureType) type, const(DbusValue) value)
	{
		auto types = type.children;
		auto values = value.childValues;
		if (values.length != types.length)
			throw new DbusOutgoingValidationException("D-Bus struct field count does not match its signature");
		foreach (index, childType; types)
			writeValue(childType, values[index]);
	}

	private void writeVariant(const(DbusValue) value)
	{
		auto signature = value.variantSignature;
		auto type = parseDbusVariantSignature(signature.text);
		if (!type.isByteOnlySupported)
			throw new DbusUnsupportedException("UNIX_FD values are not supported");
		writeSignatureText(signature.text);
		const(DbusValue) containedValue = value.variantValue;
		writeValue(type, containedValue);
	}
}

private union DbusDoubleBits
{
	double value;
	ulong bits;
}

private struct DbusReader
{
	const(ubyte)[] input;
	size_t cursor;
	size_t limit;
	DbusByteOrder order;

	this(scope const(ubyte)[] input, size_t cursor, size_t limit,
		DbusByteOrder order)
	{
		assert(cursor <= limit && limit <= input.length);
		this.input = input;
		this.cursor = cursor;
		this.limit = limit;
		this.order = order;
	}

	private void requireBytes(ulong amount)
	{
		size_t end;
		if (!dbusCheckedCursorEnd(cursor, amount, limit, end))
			throw new DbusProtocolException("truncated D-Bus value");
	}

	private scope const(ubyte)[] take(size_t amount) return
	{
		requireBytes(amount);
		auto start = cursor;
		cursor += amount;
		return input[start .. cursor];
	}

	void alignTo(size_t alignment)
	{
		size_t aligned;
		if (!dbusCheckedAlignedOffset(cursor, alignment, limit, aligned))
			throw new DbusProtocolException("truncated D-Bus alignment padding");
		foreach (octet; input[cursor .. aligned])
			if (octet != 0)
				throw new DbusProtocolException("D-Bus alignment padding must be zero");
		cursor = aligned;
	}

	ubyte readByte()
	{
		return take(1)[0];
	}

	ushort readUInt16()
	{
		auto bytes = take(2);
		if (order == DbusByteOrder.littleEndian)
			return cast(ushort) (bytes[0] | (cast(ushort) bytes[1] << 8));
		return cast(ushort) (bytes[1] | (cast(ushort) bytes[0] << 8));
	}

	uint readUInt32()
	{
		auto bytes = take(4);
		if (order == DbusByteOrder.littleEndian)
			return cast(uint) bytes[0] |
				(cast(uint) bytes[1] << 8) |
				(cast(uint) bytes[2] << 16) |
				(cast(uint) bytes[3] << 24);
		return cast(uint) bytes[3] |
			(cast(uint) bytes[2] << 8) |
			(cast(uint) bytes[1] << 16) |
			(cast(uint) bytes[0] << 24);
	}

	ulong readUInt64()
	{
		auto bytes = take(8);
		ulong result;
		if (order == DbusByteOrder.littleEndian)
			foreach (index; 0 .. 8)
				result |= cast(ulong) bytes[index] << (index * 8);
		else
			foreach (index; 0 .. 8)
				result |= cast(ulong) bytes[index] << ((7 - index) * 8);
		return result;
	}

	private string readText32()
	{
		auto length = readUInt32();
		auto text = take(cast(size_t) length);
		if (readByte() != 0)
			throw new DbusProtocolException("D-Bus strings must end in NUL");
		return cast(string) text;
	}

	private string readSignatureText()
	{
		auto length = readByte();
		auto text = take(length);
		if (readByte() != 0)
			throw new DbusProtocolException("D-Bus signatures must end in NUL");
		return cast(string) text;
	}

	private void validateNesting(DbusNesting active,
		const(DbusSignatureType) type)
	{
		// The immutable summary records maxima across every child branch, so it
		// cannot be added component-wise to an active wire path.  Retain the
		// shared summary check, then compose every static branch through the
		// same shared nesting rules before reading its first byte.
		dbusNesting(DbusSignatureKind.byte_, [active, type.nesting]);
		switch (type.kind)
		{
			case DbusSignatureKind.array_:
				validateNesting(dbusNesting(DbusSignatureKind.array_, [active]),
					type.children[0]);
				return;

			case DbusSignatureKind.struct_:
				{
					auto nested = dbusNesting(DbusSignatureKind.struct_, [active]);
					foreach (child; type.children)
						validateNesting(nested, child);
					return;
				}

			case DbusSignatureKind.dictionaryEntry_:
				{
					auto nested = dbusNesting(DbusSignatureKind.dictionaryEntry_,
						[active]);
					foreach (child; type.children)
						validateNesting(nested, child);
					return;
				}

			case DbusSignatureKind.variant_:
				dbusNesting(DbusSignatureKind.variant_, [active]);
				return;

			default:
				return;
		}
	}

	DbusValue readValue(const(DbusSignatureType) type,
		DbusNesting active = DbusNesting.init)
	{
		if (!type.isByteOnlySupported)
			throw new DbusProtocolException("UNIX_FD values are not supported by this transport");
		validateNesting(active, type);
		return readValidatedValue(type, active);
	}

	private DbusValue readValidatedValue(const(DbusSignatureType) type,
		DbusNesting active)
	{
		alignTo(type.alignment);

		switch (type.kind)
		{
			case DbusSignatureKind.byte_:
				return DbusValue.fromByte(readByte());

			case DbusSignatureKind.boolean_:
				{
					auto value = readUInt32();
					if (value != 0 && value != 1)
						throw new DbusProtocolException("D-Bus booleans must be encoded as zero or one");
					return DbusValue.fromBoolean(value != 0);
				}

			case DbusSignatureKind.int16_:
				return DbusValue.fromInt16(cast(short) readUInt16());

			case DbusSignatureKind.uint16_:
				return DbusValue.fromUInt16(readUInt16());

			case DbusSignatureKind.int32_:
				return DbusValue.fromInt32(cast(int) readUInt32());

			case DbusSignatureKind.uint32_:
				return DbusValue.fromUInt32(readUInt32());

			case DbusSignatureKind.int64_:
				return DbusValue.fromInt64(cast(long) readUInt64());

			case DbusSignatureKind.uint64_:
				return DbusValue.fromUInt64(readUInt64());

			case DbusSignatureKind.double_:
				DbusDoubleBits doubleBits;
				doubleBits.bits = readUInt64();
				return DbusValue.fromDouble(doubleBits.value);

			case DbusSignatureKind.string_:
				return DbusValue.fromString(readText32());

			case DbusSignatureKind.objectPath_:
				return DbusValue.fromObjectPath(DbusObjectPath.parse(readText32()));

			case DbusSignatureKind.signature_:
				return DbusValue.fromSignature(DbusSignature.parse(readSignatureText()));

			case DbusSignatureKind.array_:
				return readArray(type, active);

			case DbusSignatureKind.struct_:
				return readStruct(type, active);

			case DbusSignatureKind.variant_:
				return readVariant(active);

			case DbusSignatureKind.dictionaryEntry_:
				throw new DbusProtocolException("D-Bus dictionary entries are only valid as array elements");

			case DbusSignatureKind.unixFd_:
				throw new DbusProtocolException("UNIX_FD values are not supported by this transport");

			default:
				assert(0, "unknown D-Bus signature kind");
		}
	}

	private DbusValue readArray(const(DbusSignatureType) type,
		DbusNesting active)
	{
		auto arrayNesting = dbusNesting(DbusSignatureKind.array_, [active]);
		auto dataLength = readUInt32();
		if (!dbusArrayDataLengthIsValid(dataLength))
			throw new DbusProtocolException("D-Bus array data exceeds protocol size limits");
		auto types = type.children;
		assert(types.length == 1);
		auto element = types[0];
		alignTo(element.alignment);

		size_t dataEnd;
		if (!dbusCheckedCursorEnd(cursor, dataLength, limit, dataEnd))
			throw new DbusProtocolException("truncated D-Bus array data");
		auto outerLimit = limit;
		limit = dataEnd;
		DbusValue result;

		if (element.kind == DbusSignatureKind.byte_)
		{
			result = DbusValue.fromByteArray(take(cast(size_t) dataLength));
		}
		else if (element.kind == DbusSignatureKind.dictionaryEntry_)
		{
			DbusValue[] keys;
			DbusValue[] values;
			while (cursor < limit)
			{
				alignTo(8);
				if (cursor == limit)
					throw new DbusProtocolException("D-Bus dictionary data ends in alignment padding");
				readDictionaryEntry(element, arrayNesting, keys, values);
			}
			result = DbusValue.fromDictionaryEntries(DbusSignature.parse(type.text),
				keys, values);
		}
		else
		{
			DbusValue[] values;
			while (cursor < limit)
				values ~= readValidatedValue(element, arrayNesting);
			result = DbusValue.fromArray(DbusSignature.parse(type.text), values);
		}

		if (cursor != limit)
			throw new DbusProtocolException("D-Bus array data was not consumed exactly");
		limit = outerLimit;
		return result;
	}

	private void readDictionaryEntry(const(DbusSignatureType) type,
		DbusNesting active, ref DbusValue[] keys, ref DbusValue[] values)
	{
		auto entryNesting = dbusNesting(DbusSignatureKind.dictionaryEntry_, [active]);
		auto types = type.children;
		assert(types.length == 2);
		keys ~= readValidatedValue(types[0], entryNesting);
		values ~= readValidatedValue(types[1], entryNesting);
	}

	private DbusValue readStruct(const(DbusSignatureType) type,
		DbusNesting active)
	{
		auto structNesting = dbusNesting(DbusSignatureKind.struct_, [active]);
		auto types = type.children;
		DbusValue[] values;
		foreach (child; types)
			values ~= readValidatedValue(child, structNesting);
		return DbusValue.fromStruct(values);
	}

	private DbusValue readVariant(DbusNesting active)
	{
		auto signatureText = readSignatureText();
		auto type = parseDbusVariantSignature(signatureText);
		if (!type.isByteOnlySupported)
			throw new DbusProtocolException("UNIX_FD values are not supported by this transport");
		auto variantNesting = dbusNesting(DbusSignatureKind.variant_, [active]);
		auto value = readValue(type, variantNesting);
		auto variant = DbusVariant.fromValue(DbusSignature.parse(signatureText), value);
		return DbusValue.fromVariant(variant);
	}
}

private bool isKnownMessageType(ubyte value)
{
	return value >= DbusMessageType.methodCall && value <= DbusMessageType.signal;
}

private bool headerIsApplicable(ubyte messageType, ubyte field)
{
	switch (field)
	{
		case DbusHeaderField.path:
		case DbusHeaderField.interfaceName:
		case DbusHeaderField.member:
			return messageType == DbusMessageType.methodCall ||
				messageType == DbusMessageType.signal;

		case DbusHeaderField.errorName:
			return messageType == DbusMessageType.error;

		case DbusHeaderField.replySerial:
			return messageType == DbusMessageType.methodReturn ||
				messageType == DbusMessageType.error;

		case DbusHeaderField.destination:
		case DbusHeaderField.sender:
		case DbusHeaderField.signature:
		case DbusHeaderField.unixFds:
			return true;

		default:
			return false;
	}
}

private string expectedHeaderVariantSignature(ubyte field)
{
	switch (field)
	{
		case DbusHeaderField.path: return "o";
		case DbusHeaderField.interfaceName:
		case DbusHeaderField.member:
		case DbusHeaderField.errorName:
		case DbusHeaderField.destination:
		case DbusHeaderField.sender:
			return "s";
		case DbusHeaderField.replySerial:
		case DbusHeaderField.unixFds:
			return "u";
		case DbusHeaderField.signature: return "g";
		default: assert(0, "unknown D-Bus header field");
	}
}

private void requireOutgoingMessageHeaders(const ref DbusMessage message)
{
	if (message.messageType == DbusMessageType.invalid)
		throw new DbusOutgoingValidationException("D-Bus message type zero is invalid");
	if (message.serial == 0)
		throw new DbusOutgoingValidationException("D-Bus sender serial must be nonzero");
	if (message.headers.unixFds != 0)
		throw new DbusUnsupportedException("UNIX_FD values are not supported");

	switch (message.messageType)
	{
		case DbusMessageType.methodCall:
			if (!message.headers.path.text.length || !message.headers.member.text.length)
				throw new DbusOutgoingValidationException("D-Bus method calls require PATH and MEMBER headers");
			break;

		case DbusMessageType.methodReturn:
			if (message.headers.replySerial == 0)
				throw new DbusOutgoingValidationException("D-Bus method returns require a nonzero REPLY_SERIAL header");
			break;

		case DbusMessageType.error:
			if (!message.headers.errorName.text.length || message.headers.replySerial == 0)
				throw new DbusOutgoingValidationException("D-Bus errors require ERROR_NAME and nonzero REPLY_SERIAL headers");
			break;

		case DbusMessageType.signal:
			if (!message.headers.path.text.length || !message.headers.interfaceName.text.length ||
				!message.headers.member.text.length)
				throw new DbusOutgoingValidationException("D-Bus signals require PATH, INTERFACE, and MEMBER headers");
			break;

		default:
			break;
	}
}

private void writeHeaderField(ref DbusWriter writer, ubyte field,
	const(DbusValue) value)
{
	writer.alignTo(8);
	writer.writeByte(field);
	writer.writeSignatureText(value.wireSignature);
	auto type = parseDbusVariantSignature(value.wireSignature);
	writer.writeValue(type, value);
}

private void writeOutgoingHeaders(ref DbusWriter writer,
	const ref DbusMessage message, string bodySignature)
{
	auto headers = message.headers;
	if (headers.path.text.length)
		writeHeaderField(writer, DbusHeaderField.path,
			DbusValue.fromObjectPath(headers.path));
	if (headers.interfaceName.text.length)
		writeHeaderField(writer, DbusHeaderField.interfaceName,
			DbusValue.fromString(headers.interfaceName.text));
	if (headers.member.text.length)
		writeHeaderField(writer, DbusHeaderField.member,
			DbusValue.fromString(headers.member.text));
	if (headers.errorName.text.length)
		writeHeaderField(writer, DbusHeaderField.errorName,
			DbusValue.fromString(headers.errorName.text));
	if (headers.replySerial)
		writeHeaderField(writer, DbusHeaderField.replySerial,
			DbusValue.fromUInt32(headers.replySerial));
	if (headers.destination.text.length)
		writeHeaderField(writer, DbusHeaderField.destination,
			DbusValue.fromString(headers.destination.text));
	if (headers.sender.text.length)
		writeHeaderField(writer, DbusHeaderField.sender,
			DbusValue.fromString(headers.sender.text));

	if (headers.signature.text !is null && headers.signature.text != bodySignature)
		throw new DbusOutgoingValidationException("D-Bus header and body signatures disagree");
	if (bodySignature.length || headers.signature.text !is null)
		writeHeaderField(writer, DbusHeaderField.signature,
			DbusValue.fromSignature(DbusSignature.parse(bodySignature)));
}

Data encodeDbusMessage(const ref DbusMessage message,
	DbusByteOrder order = DbusByteOrder.littleEndian)
{
	requireOutgoingMessageHeaders(message);
	auto bodySignature = message.body.signature.text;
	if (bodySignature is null)
		bodySignature = "";
	auto parsedBodySignature = parseDbusBodySignature(bodySignature);
	if (!parsedBodySignature.isByteOnlySupported)
		throw new DbusUnsupportedException("UNIX_FD values are not supported");
	auto bodyValues = message.body.values;
	if (bodyValues.length != parsedBodySignature.types.length)
		throw new DbusOutgoingValidationException("D-Bus body values do not match the body signature");
	foreach (index, type; parsedBodySignature.types)
		if (bodyValues[index].wireSignature != type.text)
			throw new DbusOutgoingValidationException("D-Bus body values do not match the body signature");

	DbusWriter writer = DbusWriter(order);
	foreach (index; 0 .. 16)
		writer.writeByte(0);
	auto headerLimit = writer.limitArrayData();
	writeOutgoingHeaders(writer, message, bodySignature);
	writer.restoreLimit(headerLimit);
	auto headerDataLength = writer.position - 16;
	if (!dbusArrayDataLengthIsValid(headerDataLength) || headerDataLength > uint.max)
		throw new DbusOutgoingValidationException("D-Bus header fields exceed protocol size limits");
	writer.alignTo(8);
	auto bodyStart = writer.position;
	foreach (index, type; parsedBodySignature.types)
		writer.writeValue(type, bodyValues[index]);
	auto bodyLength = writer.position - bodyStart;
	if (bodyLength > uint.max)
		throw new DbusOutgoingValidationException("D-Bus body exceeds UINT32 length");

	size_t completeLength;
	if (!dbusCheckedMessageLength(headerDataLength, bodyLength, completeLength) ||
		completeLength != writer.position)
		throw new DbusOutgoingValidationException("D-Bus message exceeds protocol size limits");

	writer.patchByte(0, cast(ubyte) order);
	writer.patchByte(1, message.messageType);
	writer.patchByte(2, message.flags);
	writer.patchByte(3, 1);
	writer.patchUInt32(4, cast(uint) bodyLength);
	writer.patchUInt32(8, message.serial);
	writer.patchUInt32(12, cast(uint) headerDataLength);
	return writer.output;
}

private void storeHeaderField(ref DbusMessageHeaders headers, ubyte field,
	const ref DbusValue value)
{
	switch (field)
	{
		case DbusHeaderField.path:
			headers.path = DbusObjectPath.parse(value.textValue);
			return;
		case DbusHeaderField.interfaceName:
			headers.interfaceName = DbusInterfaceName.parse(value.textValue);
			return;
		case DbusHeaderField.member:
			headers.member = DbusMemberName.parse(value.textValue);
			return;
		case DbusHeaderField.errorName:
			headers.errorName = DbusErrorName.parse(value.textValue);
			return;
		case DbusHeaderField.replySerial:
			headers.replySerial = value.uint32Value;
			return;
		case DbusHeaderField.destination:
			headers.destination = DbusBusName.parse(value.textValue);
			return;
		case DbusHeaderField.sender:
			headers.sender = DbusBusName.parse(value.textValue);
			return;
		case DbusHeaderField.signature:
			headers.signature = DbusSignature.parse(value.textValue);
			return;
		case DbusHeaderField.unixFds:
			headers.unixFds = value.uint32Value;
			if (headers.unixFds != 0)
				throw new DbusProtocolException("UNIX_FD values are not supported by this transport");
			return;
		default:
			assert(0, "unknown D-Bus header field");
	}
}

private void requireIncomingMessageHeaders(ubyte messageType,
	const ref DbusMessageHeaders headers)
{
	switch (messageType)
	{
		case DbusMessageType.methodCall:
			if (!headers.path.text.length || !headers.member.text.length)
				throw new DbusProtocolException("D-Bus method calls require PATH and MEMBER headers");
			break;

		case DbusMessageType.methodReturn:
			if (headers.replySerial == 0)
				throw new DbusProtocolException("D-Bus method returns require a nonzero REPLY_SERIAL header");
			break;

		case DbusMessageType.error:
			if (!headers.errorName.text.length || headers.replySerial == 0)
				throw new DbusProtocolException("D-Bus errors require ERROR_NAME and nonzero REPLY_SERIAL headers");
			break;

		case DbusMessageType.signal:
			if (!headers.path.text.length || !headers.interfaceName.text.length ||
				!headers.member.text.length)
				throw new DbusProtocolException("D-Bus signals require PATH, INTERFACE, and MEMBER headers");
			break;

		default:
			break;
	}
}

private DbusMessage decodeDbusMessageImpl(scope const(ubyte)[] completeFrame)
{
	auto fixedHeader = validateDbusFixedHeader(completeFrame);
	if (fixedHeader.completeLength != completeFrame.length)
		throw new DbusProtocolException("D-Bus frame has truncation or trailing bytes");

	size_t headerEnd;
	if (!dbusCheckedCursorEnd(16, fixedHeader.headerDataLength,
		completeFrame.length, headerEnd))
		throw new DbusProtocolException("truncated D-Bus header fields");
	DbusReader headerReader = DbusReader(completeFrame, 16, headerEnd,
		fixedHeader.order);
	DbusMessageHeaders headers;
	bool[10] seen;
	auto messageType = completeFrame[1];
	auto headerArrayNesting = dbusNesting(DbusSignatureKind.array_);
	auto headerStructNesting = dbusNesting(DbusSignatureKind.struct_,
		[headerArrayNesting]);
	while (headerReader.cursor < headerReader.limit)
	{
		headerReader.alignTo(8);
		if (headerReader.cursor == headerReader.limit)
			throw new DbusProtocolException("D-Bus header fields end in alignment padding");
		auto field = headerReader.readByte();
		if (field == DbusHeaderField.invalid)
			throw new DbusProtocolException("D-Bus header field zero is invalid");
		auto variantText = headerReader.readSignatureText();
		auto variantType = parseDbusVariantSignature(variantText);
		if (!variantType.isByteOnlySupported)
			throw new DbusProtocolException("UNIX_FD values are not supported by this transport");
		bool applicable;
		if (field <= DbusHeaderField.unixFds)
		{
			if (variantText != expectedHeaderVariantSignature(field))
				throw new DbusProtocolException("known D-Bus header field has the wrong variant type");
			applicable = headerIsApplicable(messageType, field);
			if (applicable && seen[field])
				throw new DbusProtocolException("duplicate applicable D-Bus header field");
		}

		auto headerVariantNesting = dbusNesting(DbusSignatureKind.variant_,
			[headerStructNesting]);
		auto value = headerReader.readValue(variantType, headerVariantNesting);
		DbusVariant.fromValue(DbusSignature.parse(variantText), value);
		if (field <= DbusHeaderField.unixFds && applicable)
		{
			storeHeaderField(headers, field, value);
			seen[field] = true;
		}
	}
	if (headerReader.cursor != headerReader.limit)
		throw new DbusProtocolException("D-Bus header field array was not consumed exactly");

	DbusReader bodyReader = DbusReader(completeFrame, headerEnd, completeFrame.length,
		fixedHeader.order);
	bodyReader.alignTo(8);
	auto bodyStart = bodyReader.cursor;
	size_t bodyEnd;
	if (!dbusCheckedCursorEnd(bodyStart, fixedHeader.bodyLength,
		completeFrame.length, bodyEnd))
		throw new DbusProtocolException("truncated D-Bus body");
	bodyReader.limit = bodyEnd;

	auto signatureText = headers.signature.text;
	if (signatureText is null)
		signatureText = "";
	if (!signatureText.length && fixedHeader.bodyLength != 0)
		throw new DbusProtocolException("nonempty D-Bus body lacks a signature");
	auto bodySignature = parseDbusBodySignature(signatureText);
	if (!bodySignature.isByteOnlySupported)
		throw new DbusProtocolException("UNIX_FD values are not supported by this transport");
	DbusValue[] values;
	foreach (type; bodySignature.types)
		values ~= bodyReader.readValue(type);
	if (bodyReader.cursor != bodyReader.limit)
		throw new DbusProtocolException("D-Bus body was not consumed exactly");

	requireIncomingMessageHeaders(messageType, headers);
	DbusMessage result;
	result.byteOrder = fixedHeader.order;
	result.messageType = messageType;
	result.flags = completeFrame[2];
	result.serial = fixedHeader.serial;
	result.headers = headers;
	result.body = DbusBody.fromValues(values);
	return result;
}

DbusMessage decodeDbusMessage(scope const(ubyte)[] completeFrame)
{
	try
		return decodeDbusMessageImpl(completeFrame);
	catch (DbusProtocolException exception)
		throw exception;
	catch (DbusException exception)
		throw new DbusProtocolException(exception.msg);
}

debug(ae_unittest)
private void expectDbusProtocol(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusProtocolException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private void expectDbusProtocolMessage(string expected, void delegate() action)
{
	string actual;
	try
		action();
	catch (DbusProtocolException exception)
		actual = exception.msg;
	assert(actual == expected);
}

debug(ae_unittest)
private void expectDbusRawProtocol(string signature, scope const(ubyte)[] bytes)
{
	auto type = parseDbusVariantSignature(signature);
	DbusReader reader = DbusReader(bytes, 0, bytes.length,
		DbusByteOrder.littleEndian);
	expectDbusProtocol({ reader.readValue(type); });
}

debug(ae_unittest)
private DbusMessage dbusTestMethodCall(DbusBody body = DbusBody.init)
{
	DbusMessage result;
	result.messageType = DbusMessageType.methodCall;
	result.serial = 1;
	result.headers.path = DbusObjectPath.parse("/org/example/Test");
	result.headers.interfaceName = DbusInterfaceName.parse("org.example.Test");
	result.headers.member = DbusMemberName.parse("Call");
	result.body = body.signature.text is null ? DbusBody.from() : body;
	return result;
}

debug(ae_unittest) @DbusStruct
private struct DbusMarshalFixtureStruct
{
	ubyte first;
	uint second;
}

debug(ae_unittest)
private immutable ubyte[] dbusHelloFixture = [
	0x6c, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x6d, 0x00, 0x00, 0x00,
	0x01, 0x01, 0x6f, 0x00, 0x15, 0x00, 0x00, 0x00,
	0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
	0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70,
	0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
	0x02, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00,
	0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
	0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
	0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
	0x03, 0x01, 0x73, 0x00, 0x05, 0x00, 0x00, 0x00,
	0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00,
	0x06, 0x01, 0x73, 0x00, 0x14, 0x00, 0x00, 0x00,
	0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
	0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
	0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
];

debug(ae_unittest)
private immutable ubyte[] dbusBigEndianHelloFixture = [
	0x42, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x6d,
	0x01, 0x01, 0x6f, 0x00, 0x00, 0x00, 0x00, 0x15,
	0x2f, 0x6f, 0x72, 0x67, 0x2f, 0x66, 0x72, 0x65,
	0x65, 0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70,
	0x2f, 0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00,
	0x02, 0x01, 0x73, 0x00, 0x00, 0x00, 0x00, 0x14,
	0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
	0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
	0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
	0x03, 0x01, 0x73, 0x00, 0x00, 0x00, 0x00, 0x05,
	0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x00, 0x00, 0x00,
	0x06, 0x01, 0x73, 0x00, 0x00, 0x00, 0x00, 0x14,
	0x6f, 0x72, 0x67, 0x2e, 0x66, 0x72, 0x65, 0x65,
	0x64, 0x65, 0x73, 0x6b, 0x74, 0x6f, 0x70, 0x2e,
	0x44, 0x42, 0x75, 0x73, 0x00, 0x00, 0x00, 0x00,
];

debug(ae_unittest)
private immutable ubyte[] dbusLittleEndianScalarFixture = [
	0x6c, 0x02, 0x00, 0x01, 0x30, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x17, 0x00, 0x00, 0x00,
	0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x08, 0x01, 0x67, 0x00, 0x09, 0x79, 0x62, 0x6e,
	0x71, 0x69, 0x75, 0x78, 0x74, 0x64, 0x00, 0x00,
	0xa5, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x2e, 0xfb, 0x2e, 0x16, 0xb2, 0x9e, 0x43, 0xff,
	0x4e, 0x61, 0xbc, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x35, 0xfb, 0x04, 0x8e, 0xe0, 0xfe, 0xff, 0xff,
	0xcb, 0x04, 0xfb, 0x71, 0x1f, 0x01, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0xe0, 0x5e, 0xc0,
];

debug(ae_unittest)
private immutable ubyte[] dbusBigEndianScalarFixture = [
	0x42, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x30,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x17,
	0x05, 0x01, 0x75, 0x00, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x01, 0x67, 0x00, 0x09, 0x79, 0x62, 0x6e,
	0x71, 0x69, 0x75, 0x78, 0x74, 0x64, 0x00, 0x00,
	0xa5, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
	0xfb, 0x2e, 0x16, 0x2e, 0xff, 0x43, 0x9e, 0xb2,
	0x00, 0xbc, 0x61, 0x4e, 0x00, 0x00, 0x00, 0x00,
	0xff, 0xff, 0xfe, 0xe0, 0x8e, 0x04, 0xfb, 0x35,
	0x00, 0x00, 0x01, 0x1f, 0x71, 0xfb, 0x04, 0xcb,
	0xc0, 0x5e, 0xe0, 0x00, 0x00, 0x00, 0x00, 0x00,
];

debug(ae_unittest)
private immutable ubyte[] dbusLittleEndianContainerFixture = [
	0x6c, 0x02, 0x00, 0x01, 0x3c, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x00, 0x00, 0x1d, 0x00, 0x00, 0x00,
	0x05, 0x01, 0x75, 0x00, 0x01, 0x00, 0x00, 0x00,
	0x08, 0x01, 0x67, 0x00, 0x0f, 0x61, 0x79, 0x61,
	0x79, 0x79, 0x28, 0x79, 0x75, 0x29, 0x76, 0x61,
	0x7b, 0x73, 0x76, 0x7d, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00,
	0x01, 0x02, 0x03, 0x11, 0x00, 0x00, 0x00, 0x00,
	0x22, 0x00, 0x00, 0x00, 0x66, 0x55, 0x44, 0x33,
	0x01, 0x75, 0x00, 0x00, 0x44, 0x33, 0x22, 0x11,
	0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x04, 0x00, 0x00, 0x00, 0x64, 0x65, 0x65, 0x70,
	0x00, 0x01, 0x76, 0x00, 0x01, 0x75, 0x00, 0x00,
	0x09, 0x00, 0x00, 0x00,
];

debug(ae_unittest)
private immutable ubyte[] dbusBigEndianContainerFixture = [
	0x42, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x3c,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1d,
	0x05, 0x01, 0x75, 0x00, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x01, 0x67, 0x00, 0x0f, 0x61, 0x79, 0x61,
	0x79, 0x79, 0x28, 0x79, 0x75, 0x29, 0x76, 0x61,
	0x7b, 0x73, 0x76, 0x7d, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
	0x01, 0x02, 0x03, 0x11, 0x00, 0x00, 0x00, 0x00,
	0x22, 0x00, 0x00, 0x00, 0x33, 0x44, 0x55, 0x66,
	0x01, 0x75, 0x00, 0x00, 0x11, 0x22, 0x33, 0x44,
	0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x04, 0x64, 0x65, 0x65, 0x70,
	0x00, 0x01, 0x76, 0x00, 0x01, 0x75, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x09,
];

debug(ae_unittest)
private immutable ubyte[] dbusEmptyDictionaryFixture = [
	'l', 2, 0, 1, 8, 0, 0, 0, 1, 0, 0, 0, 19, 0, 0, 0,
	5, 1, 'u', 0, 1, 0, 0, 0, 8, 1, 'g', 0, 5, 'a', '{', 's', 'v', '}', 0,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

debug(ae_unittest)
private void dbusFixtureWriteLittleUInt32(ref ubyte[] bytes, size_t offset,
	uint value)
{
	bytes[offset] = cast(ubyte) value;
	bytes[offset + 1] = cast(ubyte) (value >> 8);
	bytes[offset + 2] = cast(ubyte) (value >> 16);
	bytes[offset + 3] = cast(ubyte) (value >> 24);
}

debug(ae_unittest)
private void dbusFixtureAppendLittleUInt32(ref ubyte[] bytes, uint value)
{
	bytes ~= cast(ubyte) value;
	bytes ~= cast(ubyte) (value >> 8);
	bytes ~= cast(ubyte) (value >> 16);
	bytes ~= cast(ubyte) (value >> 24);
}

debug(ae_unittest)
private size_t dbusFixtureNestingAlignment(char kind)
{
	switch (kind)
	{
		case 'a': return 4;
		case '(': return 8;
		default: return 1;
	}
}

debug(ae_unittest)
private string dbusFixtureRepeated(char value, size_t count)
{
	string result;
	foreach (index; 0 .. count)
		result ~= value;
	return result;
}

debug(ae_unittest)
private ubyte[] dbusFixtureNestedValue(string shape, size_t offset)
{
	assert(shape.length);
	if (shape[0] == 'y')
	{
		assert(shape.length == 1);
		return [cast(ubyte) 9];
	}
	if (shape[0] == 'v')
	{
		assert(shape.length == 1);
		return [cast(ubyte) 1, 'y', 0, 9];
	}

	auto childShape = shape[1 .. $];
	auto alignment = dbusFixtureNestingAlignment(childShape[0]);
	if (shape[0] == 'a')
	{
		auto childOffset = offset + 4;
		while (childOffset % alignment)
			childOffset++;
		auto child = dbusFixtureNestedValue(childShape, childOffset);
		assert(child.length <= uint.max);
		ubyte[] result;
		dbusFixtureAppendLittleUInt32(result, cast(uint) child.length);
		while (offset + result.length < childOffset)
			result ~= 0;
		result ~= child;
		return result;
	}

	assert(shape[0] == '(');
	auto childOffset = offset;
	while (childOffset % alignment)
		childOffset++;
	ubyte[] result;
	while (offset + result.length < childOffset)
		result ~= 0;
	result ~= dbusFixtureNestedValue(childShape, childOffset);
	return result;
}

debug(ae_unittest)
private ubyte[] dbusBodyNestingFixture(string signature, string shape)
{
	assert(signature.length <= ubyte.max);
	ubyte[] frame = [
		cast(ubyte) 'l', 42, 0, 1, 0, 0, 0, 0,
		1, 0, 0, 0, 0, 0, 0, 0,
		8, 1, 'g', 0, cast(ubyte) signature.length,
	];
	foreach (ubyte octet; cast(const(ubyte)[]) signature)
		frame ~= octet;
	frame ~= 0;
	dbusFixtureWriteLittleUInt32(frame, 12, cast(uint) (frame.length - 16));
	while (frame.length % 8)
		frame ~= 0;
	auto bodyStart = frame.length;
	frame ~= dbusFixtureNestedValue(shape, bodyStart);
	dbusFixtureWriteLittleUInt32(frame, 4, cast(uint) (frame.length - bodyStart));
	return frame;
}

debug(ae_unittest)
private ubyte[] dbusUnknownHeaderNestingFixture(string signature, string shape)
{
	assert(signature.length <= ubyte.max);
	ubyte[] frame = [
		cast(ubyte) 'l', 42, 0, 1, 0, 0, 0, 0,
		1, 0, 0, 0, 0, 0, 0, 0,
		42, cast(ubyte) signature.length,
	];
	foreach (ubyte octet; cast(const(ubyte)[]) signature)
		frame ~= octet;
	frame ~= 0;
	while (frame.length % dbusFixtureNestingAlignment(shape[0]))
		frame ~= 0;
	frame ~= dbusFixtureNestedValue(shape, frame.length);
	dbusFixtureWriteLittleUInt32(frame, 12, cast(uint) (frame.length - 16));
	while (frame.length % 8)
		frame ~= 0;
	return frame;
}

debug(ae_unittest)
private ubyte[] dbusBodyVariantChainFixture(size_t depth)
{
	assert(depth);
	ubyte[] frame = [
		cast(ubyte) 'l', 42, 0, 1, 0, 0, 0, 0,
		1, 0, 0, 0, 7, 0, 0, 0,
		8, 1, 'g', 0, 1, 'v', 0,
	];
	while (frame.length % 8)
		frame ~= 0;
	auto bodyStart = frame.length;
	foreach (index; 1 .. depth)
		frame ~= [cast(ubyte) 1, 'v', 0];
	frame ~= [cast(ubyte) 1, 'u', 0];
	while (frame.length % 4)
		frame ~= 0;
	frame ~= [cast(ubyte) 9, 0, 0, 0];
	dbusFixtureWriteLittleUInt32(frame, 4, cast(uint) (frame.length - bodyStart));
	return frame;
}

debug(ae_unittest)
private ubyte[] dbusUnknownHeaderVariantChainFixture(size_t depth)
{
	assert(depth);
	ubyte[] frame = [
		cast(ubyte) 'l', 42, 0, 1, 0, 0, 0, 0,
		1, 0, 0, 0, 0, 0, 0, 0,
		42, 1, 'v', 0,
	];
	foreach (index; 0 .. depth)
		frame ~= [cast(ubyte) 1, 'v', 0];
	frame ~= [cast(ubyte) 1, 'u', 0];
	while (frame.length % 4)
		frame ~= 0;
	frame ~= [cast(ubyte) 9, 0, 0, 0];
	auto headerDataLength = frame.length - 16;
	dbusFixtureWriteLittleUInt32(frame, 12, cast(uint) headerDataLength);
	while (frame.length % 8)
		frame ~= 0;
	return frame;
}

debug(ae_unittest)
private immutable ubyte[] dbusWrongReplySerialLargeArrayFixture = [
	'l', 2, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 12, 0, 0, 0,
	5, 2, 'a', 'y', 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0, 0,
];

debug(ae_unittest)
private immutable ubyte[] dbusUnknownNestedUnixFdFixture = [
	'l', 42, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 12, 0, 0, 0,
	10, 1, 'v', 0, 1, 'h', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

debug(ae_unittest)
private immutable ubyte[] dbusDuplicateUnknownHeaderFixture = [
	'l', 42, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0,
	42, 1, 'u', 0, 9, 0, 0, 0,
	42, 1, 'u', 0, 10, 0, 0, 0,
];

debug(ae_unittest) unittest
{
	size_t length;
	assert(dbusArrayDataLengthIsValid(dbusMaxArrayDataBytes));
	assert(!dbusArrayDataLengthIsValid(dbusMaxArrayDataBytes + 1));
	assert(dbusCheckedMessageLength(dbusMaxArrayDataBytes, 0, length));
	assert(length == 16 + dbusMaxArrayDataBytes);
	assert(dbusCheckedMessageLength(0, dbusMaxMessageBytes - 16, length));
	assert(length == dbusMaxMessageBytes);
	assert(!dbusCheckedMessageLength(0, dbusMaxMessageBytes - 15, length));
	assert(!dbusCheckedCursorEnd(ulong.max - 1, 2, ulong.max, length));
	assert(!dbusCheckedAlignedOffset(ulong.max, 8, ulong.max, length));
}

debug(ae_unittest) unittest
{
	assert(dbusLittleEndianScalarFixture.length == 88);
	assert(dbusBigEndianScalarFixture.length == 88);
	DbusValue[] values = [
		DbusValue.of!ubyte(0xa5), DbusValue.of!bool(true),
		DbusValue.of!short(-1234), DbusValue.of!ushort(5678),
		DbusValue.of!int(-12345678), DbusValue.of!uint(12345678),
		DbusValue.of!long(-1234567890123L),
		DbusValue.of!ulong(1234567890123UL), DbusValue.of!double(-123.5),
	];
	DbusMessage reply;
	reply.messageType = DbusMessageType.methodReturn;
	reply.serial = 1;
	reply.headers.replySerial = 1;
	reply.headers.signature = DbusSignature.parse("ybnqiuxtd");
	reply.body = DbusBody.fromValues(values);
	assert(encodeDbusMessage(reply).toGC == dbusLittleEndianScalarFixture);
	assert(encodeDbusMessage(reply, DbusByteOrder.bigEndian).toGC ==
		dbusBigEndianScalarFixture);
	foreach (fixture; [dbusLittleEndianScalarFixture, dbusBigEndianScalarFixture])
	{
		auto decoded = decodeDbusMessage(fixture);
		auto decodedValues = decoded.body.values;
		assert(decoded.headers.replySerial == 1);
		assert(decodedValues[0].get!ubyte() == 0xa5);
		assert(decodedValues[1].get!bool());
		assert(decodedValues[2].get!short() == -1234);
		assert(decodedValues[3].get!ushort() == 5678);
		assert(decodedValues[4].get!int() == -12345678);
		assert(decodedValues[5].get!uint() == 12345678);
		assert(decodedValues[6].get!long() == -1234567890123L);
		assert(decodedValues[7].get!ulong() == 1234567890123UL);
		assert(decodedValues[8].get!double() == -123.5);
	}
}

debug(ae_unittest) unittest
{
	assert(dbusLittleEndianContainerFixture.length == 108);
	assert(dbusBigEndianContainerFixture.length == 108);
	assert(dbusLittleEndianContainerFixture[45 .. 48] == [0, 0, 0]);
	assert(dbusLittleEndianContainerFixture[48 .. 52] == [0, 0, 0, 0]);
	assert(dbusLittleEndianContainerFixture[52 .. 56] == [3, 0, 0, 0]);
	assert(dbusLittleEndianContainerFixture[60 .. 64] == [0, 0, 0, 0]);
	assert(dbusLittleEndianContainerFixture[65 .. 68] == [0, 0, 0]);
	assert(dbusLittleEndianContainerFixture[75] == 0);

	DbusVariant[string] dictionary;
	dictionary["deep"] = DbusVariant.of!DbusVariant(DbusVariant.of!uint(9));
	DbusValue[] values = [
		DbusValue.of!(ubyte[])([]),
		DbusValue.of!(ubyte[])([cast(ubyte) 1, 2, 3]),
		DbusValue.of!ubyte(0x11),
		DbusValue.of!DbusMarshalFixtureStruct(DbusMarshalFixtureStruct(0x22,
			0x33445566)),
		DbusValue.of!DbusVariant(DbusVariant.of!uint(0x11223344)),
		DbusValue.of!(DbusVariant[string])(dictionary),
	];
	DbusMessage reply;
	reply.messageType = DbusMessageType.methodReturn;
	reply.serial = 1;
	reply.headers.replySerial = 1;
	reply.body = DbusBody.fromValues(values);
	assert(encodeDbusMessage(reply).toGC == dbusLittleEndianContainerFixture);
	assert(encodeDbusMessage(reply, DbusByteOrder.bigEndian).toGC ==
		dbusBigEndianContainerFixture);
	foreach (fixture; [dbusLittleEndianContainerFixture,
		dbusBigEndianContainerFixture])
	{
		auto decoded = decodeDbusMessage(fixture);
		auto decodedValues = decoded.body.values;
		assert(decodedValues[0].get!(ubyte[])().length == 0);
		assert(decodedValues[1].get!(ubyte[])() == [1, 2, 3]);
		assert(decodedValues[2].get!ubyte() == 0x11);
		auto structure = decodedValues[3].get!DbusMarshalFixtureStruct();
		assert(structure.first == 0x22 && structure.second == 0x33445566);
		assert(decodedValues[4].get!DbusVariant().get!uint() == 0x11223344);
		auto decodedDictionary = decodedValues[5].get!(DbusVariant[string])();
		assert(decodedDictionary["deep"].get!DbusVariant().get!uint() == 9);
	}
}

debug(ae_unittest) unittest
{
	assert(dbusEmptyDictionaryFixture.length == 48);
	assert(dbusEmptyDictionaryFixture[35 .. 40] == [0, 0, 0, 0, 0]);
	assert(dbusEmptyDictionaryFixture[40 .. 48] == [0, 0, 0, 0, 0, 0, 0, 0]);
	auto decoded = decodeDbusMessage(dbusEmptyDictionaryFixture);
	assert(decoded.body.signature.text == "a{sv}");
	assert(decoded.body.values[0].get!(DbusVariant[string])().length == 0);
	DbusVariant[string] empty;
	DbusMessage reply;
	reply.messageType = DbusMessageType.methodReturn;
	reply.serial = 1;
	reply.headers.replySerial = 1;
	reply.body = DbusBody.from(empty);
	assert(encodeDbusMessage(reply).toGC == dbusEmptyDictionaryFixture);
}

debug(ae_unittest) unittest
{
	auto bodyAtLimit = dbusBodyVariantChainFixture(64);
	assert(bodyAtLimit[16 .. 23] == [cast(ubyte) 8, 1, 'g', 0, 1, 'v', 0]);
	assert(decodeDbusMessage(bodyAtLimit).body.values[0].get!DbusVariant()
		.get!DbusVariant().containedSignature.text == "v");
	expectDbusProtocol({ decodeDbusMessage(dbusBodyVariantChainFixture(65)); });
	expectDbusProtocol({ decodeDbusMessage(dbusBodyVariantChainFixture(1024)); });

	auto headerAtLimit = dbusUnknownHeaderVariantChainFixture(60);
	assert(headerAtLimit[16 .. 20] == [cast(ubyte) 42, 1, 'v', 0]);
	assert(decodeDbusMessage(headerAtLimit).messageType == 42);
	expectDbusProtocol({ decodeDbusMessage(dbusUnknownHeaderVariantChainFixture(61)); });
}

debug(ae_unittest) unittest
{
	auto arrayShape = dbusFixtureRepeated('a', 32) ~ "y";
	auto arraySignature = arrayShape;
	assert(decodeDbusMessage(dbusBodyNestingFixture(arraySignature, arrayShape))
		.body.signature.text == arraySignature);
	auto oneOverArrayShape = dbusFixtureRepeated('a', 33) ~ "y";
	expectDbusProtocol({
		decodeDbusMessage(dbusBodyNestingFixture(oneOverArrayShape,
			oneOverArrayShape));
	});

	auto structShape = dbusFixtureRepeated('(', 32) ~ "y";
	auto structSignature = structShape ~ dbusFixtureRepeated(')', 32);
	assert(decodeDbusMessage(dbusBodyNestingFixture(structSignature, structShape))
		.body.signature.text == structSignature);
	auto oneOverStructShape = dbusFixtureRepeated('(', 33) ~ "y";
	auto oneOverStructSignature = oneOverStructShape ~ dbusFixtureRepeated(')', 33);
	expectDbusProtocol({
		decodeDbusMessage(dbusBodyNestingFixture(oneOverStructSignature,
			oneOverStructShape));
	});

	auto mixedShape = dbusFixtureRepeated('a', 32) ~
		dbusFixtureRepeated('(', 32) ~ "y";
	auto mixedSignature = mixedShape ~ dbusFixtureRepeated(')', 32);
	assert(decodeDbusMessage(dbusBodyNestingFixture(mixedSignature, mixedShape))
		.body.signature.text == mixedSignature);
	auto oneOverMixedShape = dbusFixtureRepeated('a', 32) ~
		dbusFixtureRepeated('(', 32) ~ "v";
	auto oneOverMixedSignature = oneOverMixedShape ~ dbusFixtureRepeated(')', 32);
	expectDbusProtocol({
		decodeDbusMessage(dbusBodyNestingFixture(oneOverMixedSignature,
			oneOverMixedShape));
	});

	auto headerArrayShape = dbusFixtureRepeated('a', 31) ~ "y";
	assert(decodeDbusMessage(dbusUnknownHeaderNestingFixture(headerArrayShape,
		headerArrayShape)).messageType == 42);
	auto oneOverHeaderArrayShape = dbusFixtureRepeated('a', 32) ~ "y";
	expectDbusProtocol({
		decodeDbusMessage(dbusUnknownHeaderNestingFixture(oneOverHeaderArrayShape,
			oneOverHeaderArrayShape));
	});

	auto headerStructShape = dbusFixtureRepeated('(', 31) ~ "y";
	auto headerStructSignature = headerStructShape ~ dbusFixtureRepeated(')', 31);
	assert(decodeDbusMessage(dbusUnknownHeaderNestingFixture(headerStructSignature,
		headerStructShape)).messageType == 42);
	auto oneOverHeaderStructShape = dbusFixtureRepeated('(', 32) ~ "y";
	auto oneOverHeaderStructSignature = oneOverHeaderStructShape ~
		dbusFixtureRepeated(')', 32);
	expectDbusProtocol({
		decodeDbusMessage(dbusUnknownHeaderNestingFixture(
			oneOverHeaderStructSignature, oneOverHeaderStructShape));
	});
}

debug(ae_unittest) unittest
{
	expectDbusProtocolMessage("known D-Bus header field has the wrong variant type", {
		decodeDbusMessage(dbusWrongReplySerialLargeArrayFixture);
	});
}

debug(ae_unittest) unittest
{
	assert(dbusHelloFixture.length == 128);
	auto decoded = decodeDbusMessage(dbusHelloFixture);
	assert(decoded.byteOrder == DbusByteOrder.littleEndian);
	assert(decoded.messageType == DbusMessageType.methodCall);
	assert(decoded.serial == 1);
	assert(decoded.headers.path.text == "/org/freedesktop/DBus");
	assert(decoded.headers.interfaceName.text == "org.freedesktop.DBus");
	assert(decoded.headers.member.text == "Hello");
	assert(decoded.headers.destination.text == "org.freedesktop.DBus");
	assert(decoded.body.signature.text == "");

	DbusMessage hello;
	hello.messageType = DbusMessageType.methodCall;
	hello.serial = 1;
	hello.headers.path = DbusObjectPath.parse("/org/freedesktop/DBus");
	hello.headers.interfaceName = DbusInterfaceName.parse("org.freedesktop.DBus");
	hello.headers.member = DbusMemberName.parse("Hello");
	hello.headers.destination = DbusBusName.parse("org.freedesktop.DBus");
	hello.body = DbusBody.from();
	assert(encodeDbusMessage(hello).toGC == dbusHelloFixture);
	assert(dbusBigEndianHelloFixture.length == 128);
	assert(decodeDbusMessage(dbusBigEndianHelloFixture).byteOrder ==
		DbusByteOrder.bigEndian);
	assert(encodeDbusMessage(hello, DbusByteOrder.bigEndian).toGC ==
		dbusBigEndianHelloFixture);
}

debug(ae_unittest) unittest
{
	DbusValue[] structFields = [DbusValue.of!uint(0x11223344),
		DbusValue.of!ushort(0x5566)];
	auto structure = DbusValue.fromStruct(structFields);
	auto innerVariant = DbusVariant.of!uint(0x778899aa);
	auto variant = DbusValue.fromVariant(innerVariant);
	auto negativeVariant = DbusVariant.of!int(-7);
	auto nestedVariant = DbusVariant.of!DbusVariant(innerVariant);
	DbusValue[] dictionaryKeys = [DbusValue.of!string("number"),
		DbusValue.of!string("nested")];
	DbusValue[] dictionaryValues = [DbusValue.fromVariant(negativeVariant),
		DbusValue.fromVariant(nestedVariant)];
	auto dictionary = DbusValue.fromDictionaryEntries(DbusSignature.parse("a{sv}"),
		dictionaryKeys, dictionaryValues);
	DbusValue[] values = [
		DbusValue.of!ubyte(0x5a),
		DbusValue.of!bool(true),
		DbusValue.of!short(-1234),
		DbusValue.of!ushort(5678),
		DbusValue.of!int(-12345678),
		DbusValue.of!uint(12345678),
		DbusValue.of!long(-1234567890123L),
		DbusValue.of!ulong(1234567890123UL),
		DbusValue.of!double(-123.5),
		DbusValue.of!string("text"),
		DbusValue.of!DbusObjectPath(DbusObjectPath.parse("/org/example/Object")),
		DbusValue.of!DbusSignature(DbusSignature.parse("a{sv}")),
		DbusValue.of!(ubyte[])([1, 2, 3]),
		DbusValue.of!(uint[])([0x11223344, 0x55667788]),
		structure,
		variant,
		dictionary,
	];
	auto message = dbusTestMethodCall(DbusBody.fromValues(values));
	foreach (order; [DbusByteOrder.littleEndian, DbusByteOrder.bigEndian])
	{
		auto encoded = encodeDbusMessage(message, order);
		auto decoded = decodeDbusMessage(encoded.toGC);
		assert(decoded.byteOrder == order);
		assert(decoded.body.signature.text == message.body.signature.text);
		auto decodedValues = decoded.body.values;
		assert(decodedValues.length == values.length);
		assert(decodedValues[0].get!ubyte() == 0x5a);
		assert(decodedValues[1].get!bool());
		assert(decodedValues[2].get!short() == -1234);
		assert(decodedValues[3].get!ushort() == 5678);
		assert(decodedValues[4].get!int() == -12345678);
		assert(decodedValues[5].get!uint() == 12345678);
		assert(decodedValues[6].get!long() == -1234567890123L);
		assert(decodedValues[7].get!ulong() == 1234567890123UL);
		assert(decodedValues[8].get!double() == -123.5);
		assert(decodedValues[12].get!(ubyte[])() == [1, 2, 3]);
		assert(decodedValues[13].get!(uint[])() == [0x11223344, 0x55667788]);
		assert(decodedValues[14].signature.text == "(uq)");
		assert(decodedValues[15].get!DbusVariant().get!uint() == 0x778899aa);
		auto decodedDictionary = decodedValues[16].get!(DbusVariant[string])();
		assert(decodedDictionary["number"].get!int() == -7);
		assert(decodedDictionary["nested"].get!DbusVariant().get!uint() == 0x778899aa);
	}
}

debug(ae_unittest) unittest
{
	auto badByteOrder = dbusHelloFixture.dup;
	badByteOrder[0] = 'x';
	expectDbusProtocol({ decodeDbusMessage(badByteOrder); });

	auto badType = dbusHelloFixture.dup;
	badType[1] = 0;
	expectDbusProtocol({ decodeDbusMessage(badType); });

	auto badVersion = dbusHelloFixture.dup;
	badVersion[3] = 2;
	expectDbusProtocol({ decodeDbusMessage(badVersion); });

	auto zeroSerial = dbusHelloFixture.dup;
	zeroSerial[8 .. 12] = 0;
	expectDbusProtocol({ decodeDbusMessage(zeroSerial); });

	auto nonzeroHeaderPadding = dbusHelloFixture.dup;
	nonzeroHeaderPadding[46] = 1;
	expectDbusProtocol({ decodeDbusMessage(nonzeroHeaderPadding); });

	auto nonzeroBodyPadding = dbusHelloFixture.dup;
	nonzeroBodyPadding[125] = 1;
	expectDbusProtocol({ decodeDbusMessage(nonzeroBodyPadding); });

	auto wrongPathType = dbusHelloFixture.dup;
	wrongPathType[18] = 's';
	expectDbusProtocol({ decodeDbusMessage(wrongPathType); });

	auto invalidPath = dbusHelloFixture.dup;
	invalidPath[24] = 'x';
	expectDbusProtocol({ decodeDbusMessage(invalidPath); });

	auto missingMember = dbusHelloFixture.dup;
	missingMember[80] = 10;
	expectDbusProtocol({ decodeDbusMessage(missingMember); });

	auto unknownHeader = dbusHelloFixture.dup;
	unknownHeader[96] = 10;
	assert(decodeDbusMessage(unknownHeader).headers.destination.text is null);
	auto duplicateUnknown = decodeDbusMessage(dbusDuplicateUnknownHeaderFixture);
	assert(duplicateUnknown.messageType == 42);
	assert(duplicateUnknown.headers.path.text is null);
	assert(duplicateUnknown.headers.interfaceName.text is null);
	assert(duplicateUnknown.headers.member.text is null);
	assert(duplicateUnknown.headers.errorName.text is null);
	assert(duplicateUnknown.headers.replySerial == 0);
	assert(duplicateUnknown.headers.destination.text is null);
	assert(duplicateUnknown.headers.sender.text is null);
	assert(duplicateUnknown.headers.signature.text is null);
	assert(duplicateUnknown.headers.unixFds == 0);

	auto duplicateIgnored = dbusHelloFixture.dup;
	duplicateIgnored[48] = DbusHeaderField.errorName;
	duplicateIgnored[96] = DbusHeaderField.errorName;
	assert(decodeDbusMessage(duplicateIgnored).headers.errorName.text is null);

	auto duplicateApplicable = dbusHelloFixture.dup;
	duplicateApplicable[96] = DbusHeaderField.interfaceName;
	expectDbusProtocol({ decodeDbusMessage(duplicateApplicable); });

	auto missingBodySignature = dbusLittleEndianScalarFixture.dup;
	missingBodySignature[24] = 10;
	expectDbusProtocol({ decodeDbusMessage(missingBodySignature); });

	auto zeroReplySerial = dbusLittleEndianScalarFixture.dup;
	zeroReplySerial[20 .. 24] = [0, 0, 0, 0];
	expectDbusProtocol({ decodeDbusMessage(zeroReplySerial); });

	auto invalidBoolean = dbusLittleEndianScalarFixture.dup;
	invalidBoolean[44] = 2;
	expectDbusProtocol({ decodeDbusMessage(invalidBoolean); });

	auto bodyUnixFd = dbusLittleEndianScalarFixture.dup;
	bodyUnixFd[37] = 'h';
	expectDbusProtocol({ decodeDbusMessage(bodyUnixFd); });

	auto invalidUtf8 = dbusLittleEndianContainerFixture.dup;
	invalidUtf8[92] = 0xff;
	expectDbusProtocol({ decodeDbusMessage(invalidUtf8); });

	auto missingStringNul = dbusLittleEndianContainerFixture.dup;
	missingStringNul[96] = 1;
	expectDbusProtocol({ decodeDbusMessage(missingStringNul); });

	ubyte[] oversizedFixedHeader = [cast(ubyte) 'l', 1, 0, 1,
		0xff, 0xff, 0xff, 0xff, 1, 0, 0, 0, 0, 0, 0, 0];
	expectDbusProtocol({ dbusMessageLengthFromFixedHeader(oversizedFixedHeader); });

	auto unknownFlags = dbusHelloFixture.dup;
	unknownFlags[2] = 0x80;
	assert(decodeDbusMessage(unknownFlags).flags == 0x80);

	auto unknownMessage = dbusHelloFixture.dup;
	unknownMessage[1] = 42;
	assert(decodeDbusMessage(unknownMessage).messageType == 42);

	auto truncated = dbusHelloFixture[0 .. $ - 1];
	expectDbusProtocol({ decodeDbusMessage(truncated); });
	auto trailing = dbusHelloFixture ~ [cast(ubyte) 0];
	expectDbusProtocol({ decodeDbusMessage(trailing); });
}

debug(ae_unittest) unittest
{
	foreach (offset; [cast(size_t) 41, 42, 43, 60, 61, 62, 63])
	{
		auto nonzeroPadding = dbusLittleEndianScalarFixture.dup;
		nonzeroPadding[offset] = 1;
		expectDbusProtocol({ decodeDbusMessage(nonzeroPadding); });
	}
	foreach (offset; [cast(size_t) 45, 46, 47, 77, 78, 79, 94, 95, 125, 126,
		127])
	{
		auto nonzeroPadding = dbusHelloFixture.dup;
		nonzeroPadding[offset] = 1;
		expectDbusProtocol({ decodeDbusMessage(nonzeroPadding); });
	}
	foreach (offset; [cast(size_t) 60, 61, 62, 63, 65, 66, 67, 75, 84, 85,
		86, 87])
	{
		auto nonzeroPadding = dbusLittleEndianContainerFixture.dup;
		nonzeroPadding[offset] = 1;
		expectDbusProtocol({ decodeDbusMessage(nonzeroPadding); });
	}

	foreach (length; 0 .. dbusHelloFixture.length)
		expectDbusProtocol({ decodeDbusMessage(dbusHelloFixture[0 .. length]); });
	foreach (length; 16 .. dbusLittleEndianContainerFixture.length)
		expectDbusProtocol({
		decodeDbusMessage(dbusLittleEndianContainerFixture[0 .. length]);
	});
	expectDbusRawProtocol("u", [cast(ubyte) 0, 0, 0]);
	expectDbusRawProtocol("s", [cast(ubyte) 0, 0, 0, 0]);
	expectDbusRawProtocol("g", [cast(ubyte) 1, 'u']);
	expectDbusRawProtocol("ay", [cast(ubyte) 1, 0, 0, 0]);
	expectDbusRawProtocol("au", [cast(ubyte) 3, 0, 0, 0, 1, 0, 0]);
	expectDbusRawProtocol("au", [cast(ubyte) 5, 0, 0, 0, 1, 0, 0, 0, 0]);

	auto invalidMember = dbusHelloFixture.dup;
	invalidMember[88] = '1';
	expectDbusProtocol({ decodeDbusMessage(invalidMember); });
	auto malformedBodySignature = dbusLittleEndianScalarFixture.dup;
	malformedBodySignature[37] = 'z';
	expectDbusProtocol({ decodeDbusMessage(malformedBodySignature); });
	auto missingSignatureNul = dbusLittleEndianScalarFixture.dup;
	missingSignatureNul[38] = 1;
	expectDbusProtocol({ decodeDbusMessage(missingSignatureNul); });

	auto bodyUnderConsumption = dbusLittleEndianContainerFixture.dup;
	foreach (offset; 29 .. 44)
		bodyUnderConsumption[offset] = 'y';
	expectDbusProtocol({ decodeDbusMessage(bodyUnderConsumption); });
	auto bodyOverConsumption = dbusLittleEndianContainerFixture.dup;
	foreach (offset; 29 .. 44)
		bodyOverConsumption[offset] = 't';
	expectDbusProtocol({ decodeDbusMessage(bodyOverConsumption); });

	foreach (field; cast(ubyte) 1 .. DbusHeaderField.unixFds + 1)
	{
		auto wrongKnownType = dbusLittleEndianScalarFixture.dup;
		wrongKnownType[16] = cast(ubyte) field;
		if (field == DbusHeaderField.replySerial)
			wrongKnownType[18] = 's';
		expectDbusProtocol({ decodeDbusMessage(wrongKnownType); });
	}

	auto missingPath = dbusHelloFixture.dup;
	missingPath[16] = 10;
	expectDbusProtocol({ decodeDbusMessage(missingPath); });
	auto missingMember = dbusHelloFixture.dup;
	missingMember[80] = 10;
	expectDbusProtocol({ decodeDbusMessage(missingMember); });
	auto missingReply = dbusHelloFixture.dup;
	missingReply[1] = DbusMessageType.methodReturn;
	expectDbusProtocol({ decodeDbusMessage(missingReply); });
	auto missingErrorName = dbusLittleEndianScalarFixture.dup;
	missingErrorName[1] = DbusMessageType.error;
	expectDbusProtocol({ decodeDbusMessage(missingErrorName); });
	auto missingErrorReply = dbusHelloFixture.dup;
	missingErrorReply[1] = DbusMessageType.error;
	missingErrorReply[48] = DbusHeaderField.errorName;
	expectDbusProtocol({ decodeDbusMessage(missingErrorReply); });
	foreach (offset; [cast(size_t) 16, 48, 80])
	{
		auto missingSignalHeader = dbusHelloFixture.dup;
		missingSignalHeader[1] = DbusMessageType.signal;
		missingSignalHeader[offset] = 10;
		expectDbusProtocol({ decodeDbusMessage(missingSignalHeader); });
	}

	auto ineffectiveFlags = dbusLittleEndianScalarFixture.dup;
	ineffectiveFlags[2] = DbusMessageFlag.noReplyExpected |
		DbusMessageFlag.allowInteractiveAuthorization;
	assert(decodeDbusMessage(ineffectiveFlags).flags == ineffectiveFlags[2]);
	auto unknownWithBody = dbusLittleEndianScalarFixture.dup;
	unknownWithBody[1] = 42;
	auto unknownDecoded = decodeDbusMessage(unknownWithBody);
	assert(unknownDecoded.messageType == 42);
	assert(unknownDecoded.body.values.length == 9);
}

debug(ae_unittest) unittest
{
	auto ownedFrame = dbusLittleEndianContainerFixture.dup;
	auto decoded = decodeDbusMessage(ownedFrame);
	foreach (index; 0 .. ownedFrame.length)
		ownedFrame[index] = 0;
	ownedFrame = null;
	assert(decoded.headers.replySerial == 1);
	auto values = decoded.body.values;
	assert(values[1].get!(ubyte[])() == [1, 2, 3]);
	assert(values[4].get!DbusVariant().get!uint() == 0x11223344);
	assert(values[5].get!(DbusVariant[string])()["deep"].get!DbusVariant()
		.get!uint() == 9);
}

debug(ae_unittest) unittest
{
	auto duplicatePath = dbusHelloFixture.dup;
	duplicatePath[48] = DbusHeaderField.path;
	duplicatePath[50] = 'o';
	expectDbusProtocol({ decodeDbusMessage(duplicatePath); });
	auto duplicateInterface = dbusHelloFixture.dup;
	duplicateInterface[96] = DbusHeaderField.interfaceName;
	expectDbusProtocol({ decodeDbusMessage(duplicateInterface); });
	auto duplicateMember = dbusHelloFixture.dup;
	duplicateMember[96] = DbusHeaderField.member;
	expectDbusProtocol({ decodeDbusMessage(duplicateMember); });
	auto duplicateErrorName = dbusHelloFixture.dup;
	duplicateErrorName[1] = DbusMessageType.error;
	duplicateErrorName[48] = DbusHeaderField.errorName;
	duplicateErrorName[96] = DbusHeaderField.errorName;
	expectDbusProtocol({ decodeDbusMessage(duplicateErrorName); });

	auto duplicateReplySerial = dbusLittleEndianScalarFixture.dup;
	duplicateReplySerial[24] = DbusHeaderField.replySerial;
	duplicateReplySerial[26] = 'u';
	expectDbusProtocol({ decodeDbusMessage(duplicateReplySerial); });
	auto duplicateDestination = dbusHelloFixture.dup;
	duplicateDestination[48] = DbusHeaderField.destination;
	expectDbusProtocol({ decodeDbusMessage(duplicateDestination); });
	auto duplicateSender = dbusHelloFixture.dup;
	duplicateSender[48] = DbusHeaderField.sender;
	duplicateSender[96] = DbusHeaderField.sender;
	expectDbusProtocol({ decodeDbusMessage(duplicateSender); });

	auto duplicateSignature = dbusLittleEndianScalarFixture.dup;
	duplicateSignature[16] = DbusHeaderField.signature;
	duplicateSignature[18] = 'g';
	duplicateSignature[20 .. 24] = [cast(ubyte) 1, 'y', 0, 0];
	expectDbusProtocol({ decodeDbusMessage(duplicateSignature); });
	auto duplicateUnixFds = dbusLittleEndianScalarFixture.dup;
	duplicateUnixFds[16] = DbusHeaderField.unixFds;
	duplicateUnixFds[20 .. 24] = 0;
	duplicateUnixFds[24] = DbusHeaderField.unixFds;
	duplicateUnixFds[26] = 'u';
	expectDbusProtocol({ decodeDbusMessage(duplicateUnixFds); });
}

debug(ae_unittest) unittest
{
	immutable ubyte[] unixFdsZero = [
		'l', 2, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0,
		5, 1, 'u', 0, 1, 0, 0, 0, 9, 1, 'u', 0, 0, 0, 0, 0,
	];
	auto decoded = decodeDbusMessage(unixFdsZero);
	assert(decoded.headers.replySerial == 1);
	assert(decoded.headers.unixFds == 0);
	auto unixFdsOne = unixFdsZero.dup;
	unixFdsOne[28] = 1;
	expectDbusProtocol({ decodeDbusMessage(unixFdsOne); });

	immutable ubyte[] unknownHeaderUnixFd = [
		'l', 2, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0,
		5, 1, 'u', 0, 1, 0, 0, 0, 10, 1, 'h', 0, 0, 0, 0, 0,
	];
	expectDbusProtocol({ decodeDbusMessage(unknownHeaderUnixFd); });
	expectDbusProtocol({ decodeDbusMessage(dbusUnknownNestedUnixFdFixture); });

	immutable ubyte[] emptySignatureWithBody = [
		'l', 2, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 14, 0, 0, 0,
		5, 1, 'u', 0, 1, 0, 0, 0, 8, 1, 'g', 0, 0, 0, 0, 0, 0,
	];
	expectDbusProtocol({ decodeDbusMessage(emptySignatureWithBody); });
}
