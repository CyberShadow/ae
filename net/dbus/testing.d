/**
 * In-memory bus transport shared by the D-Bus unit tests.
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

module ae.net.dbus.testing;

// The transport is attached with `attachDbusConnection`, which is only
// defined for Posix.
version(Posix)
debug(ae_unittest):

import core.sys.posix.unistd : getuid;
import std.conv : to;

import ae.net.asockets : ConnectionState, DisconnectType, IConnection;
import ae.net.dbus.common;
import ae.net.dbus.marshal : decodeDbusMessage, encodeDbusMessage;
import ae.net.dbus.value : DbusBody;
import ae.sys.data : Data;
import ae.utils.array : asBytes;

package(ae.net.dbus):

enum dbusTestServerGuid = "0123456789abcdef0123456789abcdef";

/// Records everything a `DbusConnection` sends and feeds it bus input.
final class DbusTestConnection : IConnection
{
	ConnectionState state_ = ConnectionState.connected;
	Data[] sent;
	size_t disconnectCount;

	ConnectHandler connectHandler;
	ReadDataHandler readDataHandler;
	DisconnectHandler disconnectHandler;
	BufferFlushedHandler bufferFlushedHandler;

	@property ConnectionState state()
	{
		return state_;
	}

	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(state_ == ConnectionState.connected);
		foreach (datum; data)
			sent ~= datum.dup;
	}
	alias send = IConnection.send;

	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		assert(state_ == ConnectionState.connected);
		disconnectCount++;
		state_ = ConnectionState.disconnected;
	}

	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	@property void handleReadData(ReadDataHandler value) { readDataHandler = value; }
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	@property void handleBufferFlushed(BufferFlushedHandler value) { bufferFlushedHandler = value; }

	void receive(Data data)
	{
		assert(readDataHandler !is null);
		readDataHandler(data);
	}
}

string dbusTestExternalIdentity()
{
	enum hexadecimal = "0123456789abcdef";
	char[] result;
	foreach (ubyte octet; cast(const(ubyte)[]) to!string(getuid()))
	{
		result ~= hexadecimal[octet >> 4];
		result ~= hexadecimal[octet & 0x0f];
	}
	return result.idup;
}

Data dbusTestMethodReturn(uint replySerial, DbusBody body)
{
	DbusMessage message;
	message.messageType = DbusMessageType.methodReturn;
	message.serial = 900;
	message.headers.replySerial = replySerial;
	message.body = body;
	return encodeDbusMessage(message);
}

Data dbusTestError(uint replySerial, string errorName, string errorMessage)
{
	DbusMessage message;
	message.messageType = DbusMessageType.error;
	message.serial = 901;
	message.headers.errorName = DbusErrorName.parse(errorName);
	message.headers.replySerial = replySerial;
	message.body = DbusBody.from(errorMessage);
	return encodeDbusMessage(message);
}

Data dbusTestSignal(string sender, DbusObjectPath path,
	DbusInterfaceName interfaceName, string member, DbusBody body)
{
	DbusMessage message;
	message.messageType = DbusMessageType.signal;
	message.serial = 902;
	message.headers.sender = DbusBusName.parse(sender);
	message.headers.path = path;
	message.headers.interfaceName = interfaceName;
	message.headers.member = DbusMemberName.parse(member);
	message.body = body;
	return encodeDbusMessage(message);
}

DbusMessage dbusTestSentMessage(DbusTestConnection transport, size_t index)
{
	return decodeDbusMessage(transport.sent[index].toGC);
}

/// Completes the SASL handshake and `Hello` exchange of a freshly
/// attached connection, leaving it ready with `transport.sent.length == 4`.
void dbusTestAuthenticate(DbusTestConnection transport, string uniqueName = ":1.42")
{
	assert(transport.sent.length == 2);
	assert(transport.sent[0].toGC == [cast(ubyte) 0]);
	assert(transport.sent[1].toGC == ("AUTH EXTERNAL " ~
		dbusTestExternalIdentity() ~ "\r\n").asBytes);

	transport.receive(Data(("OK " ~ dbusTestServerGuid ~ "\r\n").asBytes));
	assert(transport.sent.length == 4);
	assert(transport.sent[2].toGC == "BEGIN\r\n".asBytes);

	auto hello = decodeDbusMessage(transport.sent[3].toGC);
	assert(hello.headers.member.text == "Hello");
	transport.receive(dbusTestMethodReturn(hello.serial, DbusBody.from(uniqueName)));
}

Data dbusTestMethodCall(uint serial, string sender, DbusObjectPath path,
	string interfaceName, string member, DbusBody body, ubyte flags = 0)
{
	DbusMessage message;
	message.messageType = DbusMessageType.methodCall;
	message.serial = serial;
	message.flags = flags;
	message.headers.sender = DbusBusName.parse(sender);
	message.headers.path = path;
	if (interfaceName.length)
		message.headers.interfaceName = DbusInterfaceName.parse(interfaceName);
	message.headers.member = DbusMemberName.parse(member);
	message.body = body;
	return encodeDbusMessage(message);
}
