/**
 * Shared D-Bus protocol types and validated identifiers.
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

module ae.net.dbus.common;

import std.utf : UTFException, validate;

import ae.net.asockets : DisconnectType;
import ae.net.dbus.signature : parseDbusBodySignature;
import ae.net.dbus.value : DbusBody;

enum DbusByteOrder : ubyte
{
	littleEndian = 'l',
	bigEndian = 'B',
}

enum DbusMessageType : ubyte
{
	invalid = 0,
	methodCall = 1,
	methodReturn = 2,
	error = 3,
	signal = 4,
}

enum DbusMessageFlag : ubyte
{
	noReplyExpected = 0x01,
	noAutoStart = 0x02,
	allowInteractiveAuthorization = 0x04,
}

enum DbusHeaderField : ubyte
{
	invalid = 0,
	path = 1,
	interfaceName = 2,
	member = 3,
	errorName = 4,
	replySerial = 5,
	destination = 6,
	sender = 7,
	signature = 8,
	unixFds = 9,
}

struct DbusCallOptions
{
	bool noAutoStart;
	bool allowInteractiveAuthorization;
}

class DbusException : Exception
{
	this(string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message.idup, file, line);
	}
}

class DbusValidationException : DbusException
{
	this(string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
	}
}

class DbusUnsupportedException : DbusException
{
	this(string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
	}
}

class DbusAuthenticationException : DbusException
{
	this(string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
	}
}

class DbusProtocolException : DbusException
{
	this(string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
	}
}

class DbusDisconnectedException : DbusException
{
	string reason;
	DisconnectType disconnectType;

	this(string reason, DisconnectType disconnectType,
		string file = __FILE__, size_t line = __LINE__)
	{
		this.reason = reason.idup;
		this.disconnectType = disconnectType;
		super(reason, file, line);
	}
}

class DbusTypeMismatchException : DbusException
{
	this(string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
	}
}

package(ae.net.dbus) string copyDbusText(string value, string description)
{
	try
		validate(value);
	catch (UTFException)
		throw new DbusValidationException(description ~ " must be valid UTF-8");

	foreach (ubyte octet; cast(const(ubyte)[]) value)
		if (octet == 0)
			throw new DbusValidationException(description ~ " must not contain NUL");

	return value.idup;
}

private struct DbusText
{
	string value;

	@property string text() const
	{
		return value;
	}

	@property ubyte[] bytes() const
	{
		return (cast(const(ubyte)[]) value).dup;
	}

	size_t toHash() const nothrow @safe
	{
		return dbusTextHash(value);
	}
}

private size_t dbusTextHash(string value) nothrow @safe
{
	size_t result = cast(size_t) 14695981039346656037UL;
	foreach (ubyte octet; cast(const(ubyte)[]) value)
		result = (result ^ octet) * cast(size_t) 1099511628211UL;
	return result;
}

private bool isAsciiLetter(ubyte octet)
{
	return octet >= 'a' && octet <= 'z' || octet >= 'A' && octet <= 'Z';
}

private bool isAsciiDigit(ubyte octet)
{
	return octet >= '0' && octet <= '9';
}

private bool isAsciiIdentifierByte(ubyte octet)
{
	return isAsciiLetter(octet) || isAsciiDigit(octet) || octet == '_';
}

private bool isAsciiBusNameByte(ubyte octet)
{
	return isAsciiIdentifierByte(octet) || octet == '-';
}

private void validateObjectPathText(string value)
{
	if (!value.length || value[0] != '/')
		throw new DbusValidationException("D-Bus object paths must start with '/'");
	if (value == "/")
		return;
	if (value == "/org/freedesktop/DBus/Local")
		throw new DbusValidationException("the local D-Bus object path is reserved");
	if (value[$ - 1] == '/')
		throw new DbusValidationException("D-Bus object paths must not end with '/'");

	bool needElement = true;
	foreach (ubyte octet; cast(const(ubyte)[]) value[1 .. $])
	{
		if (octet == '/')
		{
			if (needElement)
				throw new DbusValidationException("D-Bus object paths must not contain empty elements");
			needElement = true;
		}
		else
		{
			if (!isAsciiIdentifierByte(octet))
				throw new DbusValidationException("D-Bus object path elements must be ASCII identifiers");
			needElement = false;
		}
	}
}

private void validateInterfaceLikeText(string value, bool rejectLocal)
{
	if (value.length > 255)
		throw new DbusValidationException("D-Bus interface names are limited to 255 bytes");
	if (rejectLocal && value == "org.freedesktop.DBus.Local")
		throw new DbusValidationException("the local D-Bus interface is reserved");

	size_t elementStart;
	size_t elements;
	foreach (size_t index, ubyte octet; cast(const(ubyte)[]) value)
	{
		if (octet == '.')
		{
			if (index == elementStart)
				throw new DbusValidationException("D-Bus interface names must not contain empty elements");
			elements++;
			elementStart = index + 1;
			continue;
		}
		if (!isAsciiIdentifierByte(octet))
			throw new DbusValidationException("D-Bus interface names must use ASCII identifiers");
		if (index == elementStart && isAsciiDigit(octet))
			throw new DbusValidationException("D-Bus interface name elements must not start with a digit");
	}
	if (!value.length || elementStart == value.length)
		throw new DbusValidationException("D-Bus interface names must not contain empty elements");
	if (elements == 0)
		throw new DbusValidationException("D-Bus interface names must contain a dot");
}

private void validateBusNameText(string value, bool requireUnique)
{
	if (value.length > 255)
		throw new DbusValidationException("D-Bus bus names are limited to 255 bytes");

	auto bytes = cast(const(ubyte)[]) value;
	auto unique = bytes.length && bytes[0] == ':';
	if (requireUnique && !unique)
		throw new DbusValidationException("D-Bus unique names must start with ':'");
	if (!requireUnique && bytes.length && bytes[0] == ':')
		unique = true;
	if (!bytes.length)
		throw new DbusValidationException("D-Bus bus names must not be empty");

	size_t elementStart = unique ? 1 : 0;
	if (elementStart == bytes.length)
		throw new DbusValidationException("D-Bus bus names must contain elements");

	size_t elements;
	foreach (size_t index, ubyte octet; bytes)
	{
		if (unique && index == 0)
			continue;
		if (octet == '.')
		{
			if (index == elementStart)
				throw new DbusValidationException("D-Bus bus names must not contain empty elements");
			elements++;
			elementStart = index + 1;
			continue;
		}
		if (!isAsciiBusNameByte(octet))
			throw new DbusValidationException("D-Bus bus names must use permitted ASCII characters");
		if (!unique && index == elementStart && isAsciiDigit(octet))
			throw new DbusValidationException("well-known D-Bus name elements must not start with a digit");
	}
	if (elementStart == bytes.length)
		throw new DbusValidationException("D-Bus bus names must not contain empty elements");
	if (elements == 0)
		throw new DbusValidationException("D-Bus bus names must contain a dot");
}

private void validateMemberNameText(string value)
{
	if (!value.length || value.length > 255)
		throw new DbusValidationException("D-Bus member names must contain 1 to 255 bytes");
	foreach (size_t index, ubyte octet; cast(const(ubyte)[]) value)
	{
		if (!isAsciiIdentifierByte(octet))
			throw new DbusValidationException("D-Bus member names must use ASCII identifiers");
		if (index == 0 && isAsciiDigit(octet))
			throw new DbusValidationException("D-Bus member names must not start with a digit");
	}
}

struct DbusBusName
{
	private DbusText value;

	static DbusBusName parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus bus name");
		validateBusNameText(copied, false);
		DbusBusName result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusBusName other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

struct DbusUniqueName
{
	private DbusText value;

	static DbusUniqueName parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus unique name");
		validateBusNameText(copied, true);
		DbusUniqueName result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusUniqueName other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

struct DbusObjectPath
{
	private DbusText value;

	static DbusObjectPath parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus object path");
		validateObjectPathText(copied);
		DbusObjectPath result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusObjectPath other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

struct DbusInterfaceName
{
	private DbusText value;

	static DbusInterfaceName parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus interface name");
		validateInterfaceLikeText(copied, true);
		DbusInterfaceName result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusInterfaceName other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

struct DbusMemberName
{
	private DbusText value;

	static DbusMemberName parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus member name");
		validateMemberNameText(copied);
		DbusMemberName result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusMemberName other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

struct DbusErrorName
{
	private DbusText value;

	static DbusErrorName parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus error name");
		validateInterfaceLikeText(copied, false);
		DbusErrorName result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusErrorName other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

struct DbusSignature
{
	private DbusText value;

	static DbusSignature parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus signature");
		parseDbusBodySignature(copied);
		DbusSignature result;
		result.value.value = copied;
		return result;
	}

	@property string text() const { return value.text; }
	@property ubyte[] bytes() const { return value.bytes; }
	bool opEquals(const ref DbusSignature other) const { return value.text == other.value.text; }
	size_t toHash() const nothrow @safe { return value.toHash; }
}

private ubyte decodeHex(ubyte octet)
{
	if (octet >= '0' && octet <= '9')
		return cast(ubyte) (octet - '0');
	if (octet >= 'a' && octet <= 'f')
		return cast(ubyte) (octet - 'a' + 10);
	if (octet >= 'A' && octet <= 'F')
		return cast(ubyte) (octet - 'A' + 10);
	throw new DbusValidationException("D-Bus server GUIDs must use hexadecimal digits");
}

private char lowerHex(ubyte value)
{
	return cast(char) (value < 10 ? '0' + value : 'a' + value - 10);
}

struct DbusServerGuid
{
	private string canonicalText;
	private ubyte[16] canonicalBytes;

	static DbusServerGuid parse(string text)
	{
		auto copied = copyDbusText(text, "D-Bus server GUID");
		if (copied.length != 32)
			throw new DbusValidationException("D-Bus server GUIDs must contain 32 hexadecimal digits");

		DbusServerGuid result;
		char[] normalized = new char[32];
		foreach (size_t index; 0 .. 16)
		{
			auto high = decodeHex(cast(ubyte) copied[index * 2]);
			auto low = decodeHex(cast(ubyte) copied[index * 2 + 1]);
			result.canonicalBytes[index] = cast(ubyte) ((high << 4) | low);
			normalized[index * 2] = lowerHex(high);
			normalized[index * 2 + 1] = lowerHex(low);
		}
		result.canonicalText = normalized.idup;
		return result;
	}

	@property string text() const { return canonicalText; }
	@property ubyte[16] bytes() const { return canonicalBytes; }
	bool opEquals(const ref DbusServerGuid other) const { return canonicalText == other.canonicalText; }
	size_t toHash() const nothrow @safe { return dbusTextHash(canonicalText); }
}

struct DbusMessageHeaders
{
	DbusObjectPath path;
	DbusInterfaceName interfaceName;
	DbusMemberName member;
	DbusErrorName errorName;
	uint replySerial;
	DbusBusName destination;
	DbusBusName sender;
	DbusSignature signature;
	uint unixFds;
}

struct DbusMessage
{
	DbusByteOrder byteOrder;
	ubyte messageType;
	ubyte flags;
	uint serial;
	DbusMessageHeaders headers;
	DbusBody body;
}

struct DbusSignalMessage
{
	DbusObjectPath path;
	DbusInterfaceName interfaceName;
	DbusMemberName member;
	DbusBusName sender;
	DbusBody body;
}

class DbusRemoteError : DbusException
{
	DbusErrorName errorName;
	string remoteMessage;
	DbusMessage reply;

	this(DbusErrorName errorName, string remoteMessage, DbusMessage reply,
		string file = __FILE__, size_t line = __LINE__)
	{
		this.errorName = errorName;
		this.remoteMessage = remoteMessage is null ? null :
			copyDbusText(remoteMessage, "D-Bus error message");
		this.reply = reply;
		super(remoteMessage.length ? remoteMessage : errorName.text, file, line);
	}
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

debug(ae_unittest)
private string dbusTestRepeat(char value, size_t count)
{
	char[] result;
	result.length = count;
	foreach (index; 0 .. count)
		result[index] = value;
	return result.idup;
}

debug(ae_unittest) unittest
{
	auto root = DbusObjectPath.parse("/");
	auto nestedPath = DbusObjectPath.parse("/org/example/Service_42");
	assert(root.text == "/");
	assert(nestedPath.text == "/org/example/Service_42");

	auto interfaceName = DbusInterfaceName.parse("org.example.Service_42");
	auto errorName = DbusErrorName.parse("org.example.Error_42");
	auto localErrorName = DbusErrorName.parse("org.freedesktop.DBus.Local");
	auto memberName = DbusMemberName.parse("Get_Value42");
	assert(interfaceName.text == "org.example.Service_42");
	assert(errorName.text == "org.example.Error_42");
	assert(localErrorName.text == "org.freedesktop.DBus.Local");
	assert(memberName.text == "Get_Value42");

	auto wellKnownName = DbusBusName.parse("org.example.Service-42");
	auto uniqueName = DbusUniqueName.parse(":1.42");
	auto uniqueBusName = DbusBusName.parse(":1.42");
	assert(wellKnownName.text == "org.example.Service-42");
	assert(uniqueName.text == ":1.42");
	assert(uniqueBusName.text == ":1.42");

	assert(DbusInterfaceName.parse(dbusTestRepeat('a', 253) ~ ".b").text.length == 255);
	assert(DbusMemberName.parse(dbusTestRepeat('a', 255)).text.length == 255);
	assert(DbusBusName.parse("a." ~ dbusTestRepeat('b', 253)).text.length == 255);

	auto upperGuid = DbusServerGuid.parse("0123456789ABCDEF0123456789ABCDEF");
	auto lowerGuid = DbusServerGuid.parse("0123456789abcdef0123456789abcdef");
	assert(upperGuid.text == "0123456789abcdef0123456789abcdef");
	assert(upperGuid == lowerGuid);
	assert(upperGuid.toHash == lowerGuid.toHash);
	auto zeroGuid = DbusServerGuid.parse("00000000000000000000000000000000");
	DbusServerGuid defaultGuid;
	assert(defaultGuid != zeroGuid);
}

debug(ae_unittest) unittest
{
	foreach (text; ["", "relative", "/org/example/", "/org//example",
		"/org/example-name", "/org/freedesktop/DBus/Local"])
		expectDbusValidation({ DbusObjectPath.parse(text); });

	foreach (text; ["", "org", "org..example", "org.1example",
		"org.example.", "org.example-name", "org.freedesktop.DBus.Local"])
		expectDbusValidation({ DbusInterfaceName.parse(text); });
	foreach (text; ["", "org", "org..example", "org.1example",
		"org.example.", "org.example-name"])
		expectDbusValidation({ DbusErrorName.parse(text); });
	foreach (text; ["", "1Member", "member.name", "member-name"])
		expectDbusValidation({ DbusMemberName.parse(text); });

	foreach (text; ["org", ".org.example", "org..example", "org.1example",
		"org.example$", ":", ":1", ":.1"])
		expectDbusValidation({ DbusBusName.parse(text); });
	expectDbusValidation({ DbusUniqueName.parse("org.example.Service"); });

	expectDbusValidation({ DbusInterfaceName.parse(dbusTestRepeat('a', 254) ~ ".b"); });
	expectDbusValidation({ DbusMemberName.parse(dbusTestRepeat('a', 256)); });
	expectDbusValidation({ DbusBusName.parse("a." ~ dbusTestRepeat('b', 254)); });

	char[] invalidUtf8 = [cast(char) 0xFF];
	expectDbusValidation({ DbusObjectPath.parse(cast(string) invalidUtf8); });
	expectDbusValidation({ DbusMemberName.parse("member\0name"); });
	expectDbusValidation({ DbusServerGuid.parse("0123456789abcdef0123456789abcdeg"); });
	expectDbusValidation({ DbusServerGuid.parse("0123456789abcdef0123456789abcde"); });
	expectDbusValidation({ DbusServerGuid.parse("0123456789abcdef0123456789abcdef0"); });
}
