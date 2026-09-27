/**
 * Receive-only D-Bus bus monitor.
 *
 * A `DbusMonitor` is created from an ordinary connection which, once
 * ready, asks the bus driver to promote it via
 * `org.freedesktop.DBus.Monitoring.BecomeMonitor`. After promotion the
 * bus never delivers replies to the monitor and the monitor type exposes
 * nothing that can send. The `ready` promise settles once the bus emits
 * `NameLost` for the former unique name, which marks the last frame the
 * connection received as a regular client.
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

module ae.net.dbus.monitor;

import ae.net.asockets : DisconnectType, IConnection;
import ae.net.dbus.client : DbusConnection;
version(Posix) import ae.net.dbus.client : connectDbusAddress;
import ae.net.dbus.codec : DbusFrameDecoder, DbusFdFramePolicy;
import ae.net.dbus.common : DbusDisconnectedException, DbusMessage, DbusMessageType,
	DbusProtocolException, DbusUniqueName;
import ae.sys.data : Data;
import ae.utils.promise : Promise;

/// Receive-only D-Bus monitor. Has no member that can send.
final class DbusMonitor
{
private:
	Promise!DbusUniqueName readyPromise_;
	DbusConnection connection_;
	IConnection transport_;
	DbusFrameDecoder decoder_;
	DbusUniqueName formerName_;
	void delegate(const ref DbusMessage, size_t) handler_;
	void delegate(string, DisconnectType) disconnectHandler_;
	bool ended_;
	package(ae.net.dbus) debug(ae_unittest) size_t handoffBufferedBytes;
	package(ae.net.dbus) debug(ae_unittest) bool nameLostFromHandoff;
	debug(ae_unittest) bool drainingHandoff_;
	bool readyFulfilled_;

	this(DbusConnection connection, void delegate(const ref DbusMessage, size_t) handler)
	{
		assert(connection !is null);
		assert(handler !is null);
		connection_ = connection;
		handler_ = handler;
		readyPromise_ = new Promise!DbusUniqueName;
	}

	void receive(Data data)
	{
		try
			decoder_.feed(data, (DbusMessage message, size_t frameLength) {
				if (!readyFulfilled_ && message.messageType == DbusMessageType.signal &&
					message.headers.sender.text == "org.freedesktop.DBus" &&
					message.headers.interfaceName.text == "org.freedesktop.DBus" &&
					message.headers.member.text == "NameLost" &&
					message.body.signature.text == "s" &&
					message.body.values.length == 1 &&
					message.body.values[0].get!string() == formerName_.text)
				{
					debug(ae_unittest)
					if (drainingHandoff_)
						nameLostFromHandoff = true;
					readyFulfilled_ = true;
					readyPromise_.fulfill(formerName_);
				}
				handler_(message, frameLength);
				return !ended_;
			});
		catch (DbusProtocolException exception)
		{
			ended_ = true;
			transport_.disconnect(exception.msg, DisconnectType.error);
		}
	}

	void adopt(IConnection transport, Data bufferedSuffix, DbusUniqueName formerName)
	{
		transport_ = transport;
		connection_ = null;
		decoder_ = new DbusFrameDecoder(DbusFdFramePolicy.skip, bufferedSuffix);
		debug(ae_unittest)
		handoffBufferedBytes = decoder_.bufferedLength;
		formerName_ = formerName;
		transport.handleConnect = null;
		transport.handleBufferFlushed = null;
		transport.handleReadData = (Data data) { receive(data); };
		transport.handleDisconnect = (string reason, DisconnectType type) {
			ended_ = true;
			if (!readyFulfilled_)
				readyPromise_.reject(new DbusDisconnectedException(reason, type));
			if (disconnectHandler_ !is null)
				disconnectHandler_(reason, type);
		};
		debug(ae_unittest) drainingHandoff_ = true;
		receive(Data.init);
		debug(ae_unittest) drainingHandoff_ = false;
	}

public:
	/// Resolves with the former unique name after the NameLost barrier.
	/// Failures before promotion completes reject this promise.
	@property Promise!DbusUniqueName ready() { return readyPromise_; }
	/// Fires once when the adopted monitor transport is gone.
	@property void delegate(string, DisconnectType) handleDisconnect()
	{
		return disconnectHandler_;
	}
	@property void handleDisconnect(void delegate(string, DisconnectType) handler)
	{
		disconnectHandler_ = handler;
	}
	/// Call at most once, before ready rejects or handleDisconnect fires.
	void disconnect(string reason = "Monitor closed")
	{
		assert(!ended_);
		ended_ = true;
		if (transport_ is null)
			connection_.disconnect(reason);
		else
			transport_.disconnect(reason, DisconnectType.requested);
	}

	package(ae.net.dbus) void fail(Exception exception)
	{
		ended_ = true;
		readyPromise_.reject(exception);
	}
}

package(ae.net.dbus) DbusMonitor startDbusMonitor(DbusConnection connection,
	string[] matchRules,
	void delegate(const ref DbusMessage, size_t) handler)
{
	auto monitor = new DbusMonitor(connection, handler);
	connection.ready.then((DbusUniqueName ignoredName) {
		return connection.promoteToMonitor(matchRules,
			(IConnection transport, Data bufferedSuffix, DbusUniqueName name) {
				monitor.adopt(transport, bufferedSuffix, name);
			});
	}).then((DbusMessage) {}, (Exception exception) {
		monitor.fail(exception);
	}).ignoreResult();
	return monitor;
}

version(Posix) DbusMonitor connectDbusMonitor(string address, string[] matchRules,
	void delegate(const ref DbusMessage, size_t frameLength) handler)
{
	return startDbusMonitor(connectDbusAddress(address), matchRules, handler);
}

debug(ae_unittest) unittest
{
	static assert(!__traits(hasMember, DbusMonitor, "sendCall"));
	static assert(!__traits(hasMember, DbusMonitor, "call"));
	static assert(!__traits(hasMember, DbusMonitor, "subscribe"));
}

version(Posix) debug(ae_unittest)
{
	import ae.net.asockets : ConnectionState, socketManager;
	import ae.net.dbus.client : attachDbusConnection;
	import ae.net.dbus.common : DbusBusName, DbusErrorName,
		DbusInterfaceName, DbusMemberName, DbusObjectPath,
		DbusRemoteError;
	import ae.net.dbus.marshal : decodeDbusMessage, encodeDbusMessage;
	import ae.net.dbus.value : DbusBody;
	import ae.utils.array : asBytes;
}

version(Posix) debug(ae_unittest)
private final class MonitorTestTransport : IConnection
{
	ConnectionState state_ = ConnectionState.connected;
	Data[] sent;
	ConnectHandler connectHandler;
	ReadDataHandler readDataHandler;
	DisconnectHandler disconnectHandler;
	BufferFlushedHandler bufferFlushedHandler;

	@property ConnectionState state() { return state_; }
	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		foreach (datum; data) sent ~= datum.dup;
	}
	alias send = IConnection.send;
	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		peerDisconnect(reason, type);
	}
	@property void handleConnect(ConnectHandler handler) { connectHandler = handler; }
	@property void handleReadData(ReadDataHandler handler) { readDataHandler = handler; }
	@property void handleDisconnect(DisconnectHandler handler) { disconnectHandler = handler; }
	@property void handleBufferFlushed(BufferFlushedHandler handler) { bufferFlushedHandler = handler; }
	void receive(Data data) { readDataHandler(data); }
	void peerDisconnect(string reason, DisconnectType type)
	{
		state_ = ConnectionState.disconnected;
		if (disconnectHandler !is null)
			disconnectHandler(reason, type);
	}
}

version(Posix) debug(ae_unittest)
private void monitorTestAuthenticate(MonitorTestTransport transport)
{
	assert(transport.sent[0].toGC == [cast(ubyte) 0]);
	assert(transport.sent[1].toGC.length > 0);
	transport.receive(Data("OK 0123456789abcdef0123456789abcdef\r\n".asBytes));
	assert(transport.sent[2].toGC == "BEGIN\r\n".asBytes);
	assert(decodeDbusMessage(transport.sent[3].toGC).headers.member.text == "Hello");
}

version(Posix) debug(ae_unittest)
private Data monitorTestReply(uint replySerial, DbusBody body)
{
	DbusMessage message;
	message.messageType = DbusMessageType.methodReturn;
	message.serial = 100;
	message.headers.replySerial = replySerial;
	message.body = body;
	return encodeDbusMessage(message);
}

version(Posix) debug(ae_unittest)
private Data monitorTestError(uint replySerial, string errorName)
{
	DbusMessage message;
	message.messageType = DbusMessageType.error;
	message.serial = 102;
	message.headers.errorName = DbusErrorName.parse(errorName);
	message.headers.replySerial = replySerial;
	message.body = DbusBody.from("denied");
	return encodeDbusMessage(message);
}

version(Posix) debug(ae_unittest)
private Data monitorTestSignal(string member, DbusBody body)
{
	DbusMessage message;
	message.messageType = DbusMessageType.signal;
	message.serial = 101;
	message.headers.sender = DbusBusName.parse("org.freedesktop.DBus");
	message.headers.path = DbusObjectPath.parse("/org/freedesktop/DBus");
	message.headers.interfaceName = DbusInterfaceName.parse("org.freedesktop.DBus");
	message.headers.member = DbusMemberName.parse(member);
	message.body = body;
	return encodeDbusMessage(message);
}

version(Posix) debug(ae_unittest) unittest
{
	auto transport = new MonitorTestTransport;
	auto client = attachDbusConnection(transport);
	DbusMessage[] observed;
	size_t[] lengths;
	auto monitor = startDbusMonitor(client, ["type='signal'"],
		(const ref DbusMessage message, size_t length) {
			observed ~= cast(DbusMessage) message;
			lengths ~= length;
		});
	monitorTestAuthenticate(transport);
	transport.receive(monitorTestReply(1, DbusBody.from(":1.42")));
	socketManager.loop();
	DbusUniqueName readyName;
	monitor.ready.then((DbusUniqueName name) { readyName = name; },
		(Exception) { assert(false); }).ignoreResult();
	auto request = decodeDbusMessage(transport.sent[$ - 1].toGC);
	assert(request.headers.member.text == "BecomeMonitor");
	assert(readyName.text.length == 0);
	auto sentBeforePromotionReply = transport.sent.length;
	auto barrier = monitorTestSignal("NameLost", DbusBody.from(":1.42"));
	auto reply = monitorTestReply(request.serial, DbusBody.from());
	transport.receive(reply ~ barrier);
	socketManager.loop();
	assert(readyName.text == ":1.42");
	assert(observed.length == 1 && lengths[0] == barrier.length);
	assert(monitor.nameLostFromHandoff);
	assert(monitor.handoffBufferedBytes == barrier.length);
	assert(transport.sent.length == sentBeforePromotionReply);

	DbusMessage call;
	call.messageType = DbusMessageType.methodCall;
	call.serial = 201;
	call.headers.path = DbusObjectPath.parse("/org/example/Object");
	call.headers.interfaceName = DbusInterfaceName.parse("org.example.Interface");
	call.headers.member = DbusMemberName.parse("Run");
	call.body = DbusBody.from("payload");
	DbusMessage error;
	error.messageType = DbusMessageType.error;
	error.serial = 202;
	error.headers.replySerial = 201;
	error.headers.errorName = DbusErrorName.parse("org.example.Failed");
	error.body = DbusBody.from("failure");
	auto frames = [encodeDbusMessage(call), monitorTestReply(201, DbusBody.from()),
		encodeDbusMessage(error), monitorTestSignal("Changed", DbusBody.from("value"))];
	foreach (frame; frames) transport.receive(frame);
	assert(observed.length == 5);
	foreach (index, frame; frames)
	{
		assert(observed[index + 1].messageType == decodeDbusMessage(frame.toGC).messageType);
		assert(lengths[index + 1] == frame.length);
	}
	assert(transport.sent.length == sentBeforePromotionReply);
	transport.receive(barrier);
	assert(observed.length == 6);
	assert(lengths[$ - 1] == barrier.length);
	assert(observed[$ - 1].headers.member.text == "NameLost");
	transport.peerDisconnect("done", DisconnectType.graceful);
}

version(Posix) debug(ae_unittest) unittest
{
	auto transport = new MonitorTestTransport;
	auto client = attachDbusConnection(transport);
	auto monitor = startDbusMonitor(client, ["type='signal'"],
		(const ref DbusMessage, size_t) {});
	monitorTestAuthenticate(transport);
	transport.receive(monitorTestReply(1, DbusBody.from(":1.43")));
	socketManager.loop();
	bool resolved;
	DbusDisconnectedException rejection;
	monitor.ready.then((DbusUniqueName) { resolved = true; },
		(Exception exception) { rejection = cast(DbusDisconnectedException) exception; }).ignoreResult();
	auto request = decodeDbusMessage(transport.sent[$ - 1].toGC);
	transport.receive(monitorTestReply(request.serial, DbusBody.from()));
	transport.peerDisconnect("before barrier", DisconnectType.graceful);
	socketManager.loop();
	assert(!resolved);
	assert(rejection !is null && rejection.msg == "before barrier");
}

version(Posix) debug(ae_unittest) unittest
{
	auto transport = new MonitorTestTransport;
	auto client = attachDbusConnection(transport);
	auto monitor = startDbusMonitor(client, ["type='signal'"],
		(const ref DbusMessage, size_t) {});
	monitorTestAuthenticate(transport);
	transport.receive(monitorTestReply(1, DbusBody.from(":1.44")));
	socketManager.loop();
	DbusDisconnectedException rejection;
	monitor.ready.then((DbusUniqueName) { assert(false); },
		(Exception exception) {
			rejection = cast(DbusDisconnectedException) exception;
		}).ignoreResult();
	assert(decodeDbusMessage(transport.sent[$ - 1].toGC).headers.member.text ==
		"BecomeMonitor");
	monitor.disconnect();
	socketManager.loop();
	assert(transport.state == ConnectionState.disconnected);
	assert(rejection !is null);
}

version(Posix) debug(ae_unittest) unittest
{
	auto transport = new MonitorTestTransport;
	auto client = attachDbusConnection(transport);
	auto monitor = startDbusMonitor(client, ["type='signal'"],
		(const ref DbusMessage, size_t) {});
	monitorTestAuthenticate(transport);
	transport.receive(monitorTestReply(1, DbusBody.from(":1.45")));
	auto sentThroughHello = transport.sent.length;
	assert(decodeDbusMessage(transport.sent[$ - 1].toGC).headers.member.text == "Hello");
	DbusDisconnectedException rejection;
	monitor.ready.then((DbusUniqueName) { assert(false); },
		(Exception exception) { rejection = cast(DbusDisconnectedException) exception; }).ignoreResult();
	monitor.disconnect();
	socketManager.loop();
	assert(rejection !is null);
	assert(transport.state == ConnectionState.disconnected);
	assert(transport.sent.length == sentThroughHello);
}

version(Posix) debug(ae_unittest) unittest
{
	auto transport = new MonitorTestTransport;
	auto client = attachDbusConnection(transport);
	auto monitor = startDbusMonitor(client, ["type='signal'"],
		(const ref DbusMessage, size_t) {});
	DbusDisconnectedException rejection;
	monitor.ready.then((DbusUniqueName) { assert(false); },
		(Exception exception) { rejection = cast(DbusDisconnectedException) exception; }).ignoreResult();
	auto sentDuringAuth = transport.sent.length;
	monitor.disconnect();
	socketManager.loop();
	assert(rejection !is null);
	assert(transport.state == ConnectionState.disconnected);
	assert(transport.sent.length == sentDuringAuth);
}

version(Posix) debug(ae_unittest) unittest
{
	auto transport = new MonitorTestTransport;
	auto client = attachDbusConnection(transport);
	auto monitor = startDbusMonitor(client, ["type='signal'"],
		(const ref DbusMessage, size_t) {});
	monitorTestAuthenticate(transport);
	transport.receive(monitorTestReply(1, DbusBody.from(":1.46")));
	socketManager.loop();
	DbusRemoteError rejection;
	monitor.ready.then((DbusUniqueName) { assert(false); },
		(Exception exception) { rejection = cast(DbusRemoteError) exception; }).ignoreResult();
	auto request = decodeDbusMessage(transport.sent[$ - 1].toGC);
	assert(request.headers.member.text == "BecomeMonitor");
	transport.receive(monitorTestError(request.serial,
		"org.freedesktop.DBus.Error.AccessDenied"));
	socketManager.loop();
	assert(rejection !is null);
	assert(rejection.errorName.text == "org.freedesktop.DBus.Error.AccessDenied");
	assert(transport.state == ConnectionState.disconnected);
}
