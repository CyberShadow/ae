/**
 * `ae.net.dbus`: a native, event-loop-integrated asynchronous D-Bus
 * message-bus client.
 *
 * This is the package facade. It re-exports:
 * - the POSIX transport entry points and the raw asynchronous
 *   client -- `connectDbusAddress`, `connectSessionBus`,
 *   `connectSystemBus`, `attachDbusConnection`, `DbusConnection`,
 *   `DbusMethodCall`, `DbusSubscription` -- from
 *   `ae.net.dbus.client`;
 * - the protocol/value layer -- byte order, message/header/body
 *   structs, the validated name/path/signature/GUID wrappers, and the
 *   `DbusException` hierarchy from `ae.net.dbus.common`; message framing,
 *   `encodeDbusMessage` and `decodeDbusMessage`, from
 *   `ae.net.dbus.marshal`; the signature parser and the
 *   `@DbusStruct`/`DbusOut` types from `ae.net.dbus.signature`; and the
 *   dynamic value model -- `DbusValue`, `DbusVariant`, `DbusBody` -- from
 *   `ae.net.dbus.value`;
 * - receive-only `DbusMonitor` and `connectDbusMonitor`; the monitor's
 *   `ready` promise settles after the bus sends `NameLost` for its former
 *   unique name. Its handler receives frames with their wire lengths;
 * - `DbusOutgoingCall` and `DbusConnection.sendCall` expose the serial
 *   assigned to an outgoing method call;
 * - `DbusFdFramePolicy`: ordinary connections reject frames carrying
 *   UNIX_FDS, while monitors skip them. UNIX_FD values remain unsupported
 *   for sending and receiving;
 * - structured signal matching, `DbusSignalMatch`, from
 *   `ae.net.dbus.match`;
 * - the compile-time typed D-interface binding layer --
 *   `@DbusInterface`, `@DbusMember`, `DbusSignal`, `dbusProxy`,
 *   `DbusProxy`, `getProperty`, `setProperty`, `getAllProperties`,
 *   `subscribePropertiesChanged`, `subscribe`, `introspect` -- from
 *   `ae.net.dbus.binding`.
 *
 * `ae.net.dbus.address`, `ae.net.dbus.auth`, and `ae.net.dbus.codec` are
 * internal implementation modules. The codec's public fd-frame policy is
 * re-exported separately; its decoder remains package-visible.
 *
 * This package implements a POSIX D-Bus *message-bus client*, not a
 * service host and not a binding to `libdbus`/`sd-bus`. In particular, it
 * does not support:
 * - `UNIX_FD` (`h`), `NEGOTIATE_UNIX_FD`, or `SCM_RIGHTS` -- passing
 *   file descriptors requires a separate `ae.net.asockets` transport
 *   project, since `IConnection` cannot associate ancillary
 *   descriptors with byte ranges or preserve that association through
 *   partial writes;
 * - exporting local objects, registering dispatch implementations,
 *   generating introspection XML, `Peer`/`ObjectManager` service
 *   behavior, or `RequestName`/`ReleaseName` ownership convenience
 *   APIs -- an incoming method call that expects a reply receives
 *   `org.freedesktop.DBus.Error.UnknownObject`, but there is no object
 *   registry;
 * - runtime XML parsing or runtime proxy generation --
 *   `introspect()` returns the raw XML string;
 * - TCP, nonce-TCP, systemd, launchd, unixexec, X-root-window
 *   discovery, `autolaunch:`, and any authentication mechanism other
 *   than `EXTERNAL`;
 * - automatic reconnection after a terminal disconnect, peer-to-peer
 *   mode, per-call cancellation/timeouts, and outgoing no-reply typed
 *   methods or application signals.
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

module ae.net.dbus;

public import ae.net.dbus.binding;
public import ae.net.dbus.client;
public import ae.net.dbus.codec : DbusFdFramePolicy;
public import ae.net.dbus.common;
public import ae.net.dbus.marshal;
public import ae.net.dbus.match;
public import ae.net.dbus.monitor;
public import ae.net.dbus.signature;
public import ae.net.dbus.value;

version (HAVE_DBUS_SERVER)
debug(ae_unittest) unittest
{
	import std.process : environment, execute, spawnProcess, kill, wait;
	import std.conv : to;
	import std.string : split, strip;
	import std.stdio : writeln;
	import ae.utils.promise : Promise;
	import ae.utils.promise.await : async, await, awaitSync;
	import ae.net.dbus.client : DbusClientTestObservedSocket, dbusClientTestSocketObserver;
	import ae.net.asockets : ConnectionState;

	auto address = environment["DBUS_SESSION_BUS_ADDRESS"];
	DbusClientTestObservedSocket monitorSocket;
	dbusClientTestSocketObserver = (socket) {
		if (monitorSocket is null)
			monitorSocket = cast(DbusClientTestObservedSocket) socket;
	};
	scope(exit) dbusClientTestSocketObserver = null;

	async({
		DbusMessage[] observed;
		void delegate() onEvent;
		auto monitor = connectDbusMonitor(address,
			["type='method_call',interface='org.freedesktop.Notifications'",
			 "type='method_return'",
			 "type='error'",
			 "type='signal',interface='org.freedesktop.Notifications'",
			 "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.freedesktop.Notifications'"],
			(const ref DbusMessage message, size_t frameLength) {
				observed ~= cast(DbusMessage) message;
				if (onEvent !is null) onEvent();
			});
		auto formerName = await(monitor.ready);
		bool nameLostSeen;
		foreach (message; observed)
		{
			if (message.messageType == DbusMessageType.signal &&
				message.headers.sender.text == "org.freedesktop.DBus" &&
				message.headers.member.text == "NameLost" &&
				message.body.values.length == 1 &&
				message.body.values[0].get!string() == formerName.text)
			{
				nameLostSeen = true;
				break;
			}
			assert(message.headers.destination.text != formerName.text);
		}
		assert(nameLostSeen);
		auto sentAtPromotion = monitorSocket.sentBytes;
		writeln("monitor ready former=", formerName.text,
			" socket bytes sent=", sentAtPromotion,
			" bytes at BecomeMonitor=", monitorSocket.sentBytesAtBecomeMonitor);
		assert(sentAtPromotion == monitorSocket.sentBytesAtBecomeMonitor);

		Promise!void waitFor(bool delegate() predicate)
		{
			auto result = new Promise!void;
			void check()
			{
				if (!predicate()) return;
				onEvent = null;
				result.fulfill();
			}
			onEvent = &check;
			check();
			return result;
		}

		auto watcher = connectDbusAddress(address);
		await(watcher.ready);
		auto ownerChanged = new Promise!void;
		auto ownerMatch = DbusSignalMatch.signal()
			.withSender(DbusBusName.parse("org.freedesktop.DBus"))
			.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
			.withMember(DbusMemberName.parse("NameOwnerChanged"))
			.withArgument(0, "org.freedesktop.Notifications");
		auto ownerSubscription = await(watcher.subscribe(ownerMatch,
			(const ref DbusSignalMessage) { ownerChanged.fulfill(); }));
		auto echo = spawnProcess(["dbus-test-tool", "echo",
			"--name=org.freedesktop.Notifications"]);
		scope(exit) { echo.kill(); echo.wait(); }
		await(ownerChanged);
		await(waitFor(() {
			foreach (message; observed)
				if (message.messageType == DbusMessageType.signal &&
					message.headers.member.text == "NameOwnerChanged" &&
					message.body.values.length == 3 &&
					message.body.values[0].get!string() ==
						"org.freedesktop.Notifications")
					return true;
			return false;
		}));
		writeln("Notifications NameOwnerChanged observed after echo startup");

		auto client = connectDbusAddress(address);
		auto clientName = await(client.ready);
		DbusMethodCall notify;
		notify.destination = DbusBusName.parse("org.freedesktop.Notifications");
		notify.path = DbusObjectPath.parse("/org/freedesktop/Notifications");
		notify.interfaceName = DbusInterfaceName.parse("org.freedesktop.Notifications");
		notify.member = DbusMemberName.parse("Notify");
		notify.body = DbusBody.from("spike", cast(uint) 100, "", "summary", "body",
			cast(string[]) [], cast(DbusVariant[string]) null, cast(int) -1);
		auto outgoing = client.sendCall(notify);
		await(outgoing.reply);
		await(waitFor(() {
			bool callSeen, replySeen;
			foreach (message; observed)
			{
				if (message.messageType == DbusMessageType.methodCall &&
					message.headers.member.text == "Notify" &&
					message.headers.sender.text == clientName.text &&
					message.serial == outgoing.serial)
					callSeen = true;
				if (message.messageType == DbusMessageType.methodReturn &&
					message.headers.destination.text == clientName.text &&
					message.headers.replySerial == outgoing.serial &&
					message.body.values.length == 0)
					replySeen = true;
			}
			return callSeen && replySeen;
		}));
		writeln("Notify call and return observed serial=", outgoing.serial);

		DbusMethodCall invalid;
		invalid.destination = DbusBusName.parse("org.freedesktop.Notifications.Absent");
		invalid.path = DbusObjectPath.parse("/org/freedesktop/Notifications");
		invalid.interfaceName = DbusInterfaceName.parse("org.freedesktop.Notifications");
		invalid.member = DbusMemberName.parse("Notify");
		invalid.body = notify.body;
		auto invalidOutgoing = client.sendCall(invalid);
		bool remoteRejected;
		try
			await(invalidOutgoing.reply);
		catch (DbusRemoteError exception)
		{
			remoteRejected = true;
			assert(exception.errorName.text == "org.freedesktop.DBus.Error.ServiceUnknown");
		}
		assert(remoteRejected);
		await(waitFor(() {
			bool callSeen, errorSeen;
			foreach (message; observed)
			{
				if (message.messageType == DbusMessageType.methodCall &&
					message.headers.interfaceName.text == "org.freedesktop.Notifications" &&
					message.headers.destination.text == "org.freedesktop.Notifications.Absent" &&
					message.serial == invalidOutgoing.serial)
					callSeen = true;
				if (message.messageType == DbusMessageType.error &&
					message.headers.destination.text == clientName.text &&
					message.headers.replySerial == invalidOutgoing.serial)
					errorSeen = true;
			}
			return callSeen && errorSeen;
		}));
		writeln("error observed reply_serial=", invalidOutgoing.serial);

		auto third = connectDbusAddress(address);
		auto thirdName = await(third.ready);
		third.disconnect();
		auto sent = execute(["dbus-send", "--session", "--type=signal",
			"--dest=" ~ thirdName.text, "/org/freedesktop/Notifications",
			"org.freedesktop.Notifications.NotificationClosed", "uint32:100", "uint32:2"]);
		assert(sent.status == 0, sent.output);
		await(waitFor(() {
			bool directedSeen;
			foreach (message; observed)
			{
				if (message.messageType == DbusMessageType.signal &&
					message.headers.member.text == "NotificationClosed" &&
					message.headers.destination.text == thirdName.text)
					directedSeen = true;
			}
			return directedSeen;
		}));
		bool thirdNameChangeSeen;
		foreach (message; observed)
			if (message.messageType == DbusMessageType.signal &&
				message.headers.member.text == "NameOwnerChanged" &&
				message.body.values.length == 3 &&
				message.body.values[0].get!string() == thirdName.text)
				thirdNameChangeSeen = true;
		assert(!thirdNameChangeSeen);
		assert(monitorSocket.sentBytes == sentAtPromotion);
		assert(monitorSocket.state == ConnectionState.connected);
		auto fdExchange = execute(["python3", environment["AE_DBUS_FD_PEER_HELPER"]]);
		assert(fdExchange.status == 0, fdExchange.output);
		auto fdDetails = fdExchange.output.strip().split(" ");
		assert(fdDetails.length == 2);
		assert(fdDetails[0].length > "deliver-serial=".length &&
			fdDetails[0][0 .. "deliver-serial=".length] == "deliver-serial=");
		assert(fdDetails[1].length > "sender=".length &&
			fdDetails[1][0 .. "sender=".length] == "sender=");
		auto deliverSerial = fdDetails[0]["deliver-serial=".length .. $].to!uint();
		auto deliverSender = fdDetails[1]["sender=".length .. $];
		assert(monitorSocket.state == ConnectionState.connected);
		auto nextOutgoing = client.sendCall(notify);
		await(nextOutgoing.reply);
		await(waitFor(() {
			foreach (message; observed)
				if (message.messageType == DbusMessageType.methodCall &&
					message.headers.member.text == "Notify" &&
					message.serial == nextOutgoing.serial)
					return true;
			return false;
		}));
		bool fdReplySeen;
		foreach (message; observed)
		{
			assert(message.headers.member.text != "Deliver");
			assert(!(message.messageType == DbusMessageType.methodCall &&
				message.headers.sender.text != clientName.text &&
				message.serial == deliverSerial));
			if (message.messageType == DbusMessageType.methodReturn &&
				message.headers.replySerial == deliverSerial &&
				message.headers.destination.text == deliverSender)
				fdReplySeen = true;
		}
		assert(fdReplySeen);
		assert(monitorSocket.state == ConnectionState.connected);
		writeln("fd-bearing Deliver withheld; reply observed reply_serial=",
			deliverSerial);
		writeln("directed signal observed; third NameOwnerChanged=",
			thirdNameChangeSeen, " post-promotion bytes=",
			monitorSocket.sentBytes - sentAtPromotion,
			" handoff buffered=", monitor.handoffBufferedBytes,
			" NameLost in suffix=", monitor.nameLostFromHandoff);
		monitor.disconnect();
		client.disconnect();
		watcher.disconnect();
	}).awaitSync();
}

version (HAVE_DBUS_SERVER)
debug(ae_unittest) unittest
{
	import std.algorithm.searching : canFind;
	import std.conv : to;
	import std.process : environment, thisProcessID;
	import std.string : indexOf, indexOfAny;

	import ae.utils.promise : Promise;
	import ae.utils.promise.await : async, await, awaitSync;

	@DbusInterface("org.freedesktop.DBus")
	interface DbusPackageTestBus
	{
		Promise!(string[]) ListNames();

		@DbusMember("ThisMethodDoesNotExist")
		Promise!void Bogus();

		alias NameOwnerChanged = DbusSignal!("NameOwnerChanged", string, string, string);
	}

	// DBUS_SESSION_BUS_ADDRESS commonly already carries its own `guid=`;
	// strip it so a candidate list can attach a deliberately wrong one
	// without producing a duplicate-key address parse error.
	string stripGuid(string address)
	{
		enum key = ",guid=";
		auto pos = address.indexOf(key);
		if (pos < 0)
			return address;
		auto valueStart = pos + key.length;
		auto end = address[valueStart .. $].indexOfAny(",;");
		return end < 0 ? address[0 .. pos] : address[0 .. pos] ~ address[valueStart + end .. $];
	}

	auto sessionAddress = environment.get("DBUS_SESSION_BUS_ADDRESS");
	assert(sessionAddress.length, "DBUS_SESSION_BUS_ADDRESS is not set");

	async({
		auto connection = connectSessionBus();
		scope(exit) connection.disconnect("D-Bus package test complete");

		auto uniqueName = await(connection.ready);
		assert(uniqueName.text.length);
		assert(connection.uniqueName.text == uniqueName.text);

		auto bus = dbusProxy!DbusPackageTestBus(connection,
			DbusBusName.parse("org.freedesktop.DBus"), DbusObjectPath.parse("/org/freedesktop/DBus"));

		auto names = await(bus.ListNames());
		assert(canFind(names, uniqueName.text));

		bool gotRemoteError;
		try
			await(bus.Bogus());
		catch (DbusRemoteError)
			gotRemoteError = true;
		assert(gotRemoteError, "Expected DbusRemoteError from an invalid method");

		// The bus daemon delivers the second connection's NameOwnerChanged
		// broadcast to this connection's socket in the same poll iteration
		// as the second connection's own Hello reply, so the signal handler
		// below runs before `await(second.ready)` resumes (which is
		// scheduled via onNextTick). Record every event and evaluate
		// matching predicates against the whole history, rather than
		// assuming events only arrive after their subject is known.
		struct DbusPackageTestNameChange { string name, oldOwner, newOwner; }
		DbusPackageTestNameChange[] changes;
		void delegate() onChange;
		auto subscription = await(subscribe!(DbusPackageTestBus.NameOwnerChanged)(bus,
			(string name, string oldOwner, string newOwner) {
				changes ~= DbusPackageTestNameChange(name, oldOwner, newOwner);
				if (onChange !is null)
					onChange();
			}));

		Promise!void waitFor(bool delegate() predicate)
		{
			auto promise = new Promise!void;
			bool done;
			void check()
			{
				if (done || !predicate())
					return;
				done = true;
				onChange = null;
				promise.fulfill();
			}
			onChange = &check;
			check();
			return promise;
		}

		auto second = connectSessionBus();
		auto secondUniqueName = await(second.ready);

		await(waitFor(() {
			foreach (change; changes)
				if (change.name == secondUniqueName.text && change.newOwner == secondUniqueName.text)
					return true;
			return false;
		}));

		second.disconnect("D-Bus package test second client done");

		await(waitFor(() {
			foreach (change; changes)
				if (change.name == secondUniqueName.text && change.oldOwner == secondUniqueName.text && !change.newOwner.length)
					return true;
			return false;
		}));

		await(subscription.unsubscribe());

		auto bareSessionAddress = stripGuid(sessionAddress);

		// Candidate fallback against the real daemon: a failing first
		// candidate, then a working one.
		auto refusedPath = environment.get("TMPDIR", "/tmp") ~
			"/ae-dbus-package-test-" ~ thisProcessID.to!string ~ "-refused";

		// the refused candidate must fail alone, or the fallback below proves nothing
		bool refusedRejected;
		try
			await(connectDbusAddress("unix:path=" ~ refusedPath).ready);
		catch (DbusDisconnectedException)
			refusedRejected = true;
		assert(refusedRejected, "An unconnectable candidate must fail");

		auto fallback = connectDbusAddress(
			"unix:path=" ~ refusedPath ~ ";" ~ bareSessionAddress);
		scope(exit) fallback.disconnect("D-Bus package test fallback complete");
		auto fallbackName = await(fallback.ready);
		assert(fallbackName.text.length);

		// Candidate fallback with a wrong expected GUID on the first
		// (otherwise reachable) candidate.
		enum wrongGuid = "deadbeefdeadbeefdeadbeefdeadbeef";

		// the wrong-GUID candidate must fail alone, or the fallback below proves nothing
		bool wrongGuidRejected;
		try
			await(connectDbusAddress(bareSessionAddress ~ ",guid=" ~ wrongGuid).ready);
		catch (DbusAuthenticationException)
			wrongGuidRejected = true;
		assert(wrongGuidRejected, "A wrong address GUID must fail authentication");

		auto guidFallback = connectDbusAddress(
			bareSessionAddress ~ ",guid=" ~ wrongGuid ~ ";" ~ bareSessionAddress);
		scope(exit) guidFallback.disconnect("D-Bus package test GUID fallback complete");
		auto guidFallbackName = await(guidFallback.ready);
		assert(guidFallbackName.text.length);
	}).awaitSync();
}
