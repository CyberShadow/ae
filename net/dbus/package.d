/**
 * `ae.net.dbus`: a native, event-loop-integrated asynchronous D-Bus
 * message-bus client and service host.
 *
 * This is the package facade. It re-exports:
 * - the POSIX transport entry points and the raw asynchronous
 *   client -- `connectDbusAddress`, `connectSessionBus`,
 *   `connectSystemBus`, `attachDbusConnection`, `DbusConnection`,
 *   `DbusMethodCall`, `DbusSubscription` -- from
 *   `ae.net.dbus.client`;
 * - the protocol/value layer -- byte order, message/header/body
 *   structs, the validated name/path/signature/GUID wrappers, and the
 *   `DbusException` hierarchy (including `DbusError` for a named handler
 *   reply and the separate `DbusRemoteError` received from a peer) from
 *   `ae.net.dbus.common`;
 *   message framing, `encodeDbusMessage` and `decodeDbusMessage`, from
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
 *   `ae.net.dbus.match`; `withPathNamespace` adds `path_namespace`,
 *   `withArgumentPath` adds `argNpath`, and `withArgument0Namespace`
 *   adds `arg0namespace`. Each argument index accepts only one exact,
 *   path, or namespace constraint;
 * - the compile-time typed D-interface layer -- `@DbusInterface`,
 *   `@DbusMember`, `@DbusProperty`, `DbusSignal`, and the interface
 *   descriptions, from `ae.net.dbus.description`; on the client side,
 *   `dbusProxy`, `DbusProxy` (whose `@DbusProperty` accessors read and
 *   write properties), `getAllProperties`, `subscribePropertiesChanged`,
 *   `subscribe`, `introspect` -- from `ae.net.dbus.binding`; on the
 *   service side, `exportObject` and `DbusExport` (signal emission and
 *   property change notifications) from `ae.net.dbus.exporter`;
 * - the per-connection object registry, `DbusObjectRegistry`
 *   (`DbusConnection.objects`), which serves untyped
 *   `DbusInterfaceImplementation`s and answers
 *   `org.freedesktop.DBus.Peer` on every path, and `Introspectable` and
 *   `Properties` for registered objects, from `ae.net.dbus.service`;
 * - introspection XML generation, `dbusInterfaceXml` and
 *   `dbusIntrospectionXml`, from `ae.net.dbus.introspection`, and the
 *   standard interfaces `DbusPeer`, `DbusIntrospectable` and
 *   `DbusProperties` from `ae.net.dbus.standard`.
 *
 * Services also use `DbusConnection.emitSignal` for untyped signals,
 * and `requestName`/`releaseName` with `handleNameAcquired` and
 * `handleNameLost` for well-known names. The bus reports the
 * connection's own unique name through `NameAcquired` too, right after
 * the connection becomes ready.
 * A handler forwards a received error only explicitly:
 * `catch (DbusRemoteError e) throw new DbusError(e.errorName, e.remoteMessage);`
 * `DbusConnection.listNames` and `listActivatableNames` return validated
 * bus names for running and activatable services.
 *
 * `ae.net.dbus.address`, `ae.net.dbus.auth`, and `ae.net.dbus.codec` are
 * internal implementation modules. The codec's public fd-frame policy is
 * re-exported separately; its decoder remains package-visible.
 *
 * This package implements POSIX D-Bus *message-bus* connections, not a
 * binding to `libdbus`/`sd-bus`. In particular, it does not support:
 * - `UNIX_FD` (`h`), `NEGOTIATE_UNIX_FD`, or `SCM_RIGHTS` -- passing
 *   file descriptors requires a separate `ae.net.asockets` transport
 *   project, since `IConnection` cannot associate ancillary
 *   descriptors with byte ranges or preserve that association through
 *   partial writes;
 * - `org.freedesktop.DBus.ObjectManager`, subtree or fallback handlers
 *   serving every path below a prefix, and passing caller information
 *   (sender, flags) to typed exported methods -- untyped handlers
 *   receive the whole call message;
 * - runtime XML parsing or runtime proxy generation --
 *   `introspect()` returns the raw XML string;
 * - TCP, nonce-TCP, systemd, launchd, unixexec, X-root-window
 *   discovery, `autolaunch:`, and any authentication mechanism other
 *   than `EXTERNAL`;
 * - automatic reconnection after a terminal disconnect, peer-to-peer
 *   mode, per-call cancellation/timeouts, and outgoing no-reply typed
 *   methods.
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
public import ae.net.dbus.description;
public import ae.net.dbus.exporter;
public import ae.net.dbus.introspection;
public import ae.net.dbus.marshal;
public import ae.net.dbus.match;
public import ae.net.dbus.monitor;
public import ae.net.dbus.service;
public import ae.net.dbus.signature;
public import ae.net.dbus.standard;
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
		assert(canFind(names, "org.freedesktop.DBus"));
		auto typedNames = await(connection.listNames());
		bool ownNameListed, busNameListed;
		foreach (name; typedNames)
		{
			if (name.text == uniqueName.text)
				ownNameListed = true;
			if (name.text == "org.freedesktop.DBus")
				busNameListed = true;
		}
		assert(ownNameListed && busNameListed);

		string[] namespaceChanges;
		auto player1Seen = new Promise!void;
		auto namespaceMatch = DbusSignalMatch.signal()
			.withSender(DbusBusName.parse("org.freedesktop.DBus"))
			.withInterface(DbusInterfaceName.parse("org.freedesktop.DBus"))
			.withMember(DbusMemberName.parse("NameOwnerChanged"))
			.withArgument0Namespace("org.ae.TestNs");
		auto namespaceSubscription = await(connection.subscribe(namespaceMatch,
			(const ref DbusSignalMessage signal) {
				auto name = signal.body.values[0].get!string();
				namespaceChanges ~= name;
				if (name == "org.ae.TestNs.Player1")
					player1Seen.fulfill();
			}));
		auto named = connectSessionBus();
		await(named.ready);
		// Signals from one bus connection arrive in order, even though the
		// request replies and this subscription use different sockets.
		await(named.requestName(DbusBusName.parse("org.ae.TestNsOther")));
		await(named.requestName(DbusBusName.parse("org.ae.TestNs.Player1")));
		await(player1Seen);
		assert(namespaceChanges == ["org.ae.TestNs.Player1"]);
		await(namespaceSubscription.unsubscribe());

		auto pathSignal = new Promise!void;
		auto pathMatch = DbusSignalMatch.signal()
			.withInterface(DbusInterfaceName.parse("org.ae.Test.PathNamespace"))
			.withMember(DbusMemberName.parse("Changed"))
			.withPathNamespace(DbusObjectPath.parse("/org/ae/Test"));
		auto pathSubscription = await(connection.subscribe(pathMatch,
			(const ref DbusSignalMessage signal) { pathSignal.fulfill(); }));
		DbusSignalEmission emission;
		emission.path = DbusObjectPath.parse("/org/ae/Test/Child");
		emission.interfaceName = DbusInterfaceName.parse("org.ae.Test.PathNamespace");
		emission.member = DbusMemberName.parse("Changed");
		named.emitSignal(emission);
		await(pathSignal);
		await(pathSubscription.unsubscribe());
		named.disconnect("namespace match test complete");

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

// Serving an exported object on a real bus, to this library's own
// clients and to the reference tools.
version (HAVE_DBUS_SERVER)
debug(ae_unittest) unittest
{
	import core.time : MonoTime, msecs, seconds;
	import std.algorithm.searching : canFind;
	import std.conv : to;
	import std.file : FileException, readText, remove, tempDir;
	import std.process : spawnProcess, thisProcessID, tryWait;
	import std.stdio : File, stdin, writeln;
	import std.string : split, strip;

	import ae.sys.timing : setTimeout;
	import ae.utils.promise : Promise, resolve;
	import ae.utils.promise.await : async, await, awaitSync;

	@DbusInterface("org.ae.Test1")
	interface ITest
	{
		Promise!int Add(int a, int b);
		Promise!(DbusOut!(int, string)) Pair();
		Promise!void Fail();
		Promise!void Crash();
		Promise!void Slow();
		@DbusProperty Promise!double Volume();
		@DbusProperty Promise!void Volume(double value);
		@DbusProperty Promise!string Name();
		alias Changed = DbusSignal!("Changed", int);
	}

	class TestObject : ITest
	{
		double volume = 0;
		Promise!void slow;

		Promise!int Add(int a, int b) { return resolve(a + b); }
		Promise!(DbusOut!(int, string)) Pair()
		{
			DbusOut!(int, string) result;
			result.values[0] = 1;
			result.values[1] = "one";
			return resolve(result);
		}
		Promise!void Fail()
		{
			throw new DbusError(DbusErrorName.parse("org.ae.Test.Error.Custom"), "custom failure");
		}
		Promise!void Crash() { throw new Exception("crashed"); }
		Promise!void Slow() { return slow = new Promise!void; }
		Promise!double Volume() { return resolve(volume); }
		Promise!void Volume(double value) { volume = value; return resolve(); }
		Promise!string Name() { return resolve("test-object"); }
	}

	enum serviceName = "org.ae.Test";
	enum objectPath = "/org/ae/Test/Obj";

	/// Fulfills once `predicate` holds, polling the event loop.
	Promise!void waitFor(bool delegate() predicate, string what)
	{
		auto result = new Promise!void;
		auto deadline = MonoTime.currTime + 10.seconds;
		void check()
		{
			if (predicate())
				result.fulfill();
			else if (MonoTime.currTime > deadline)
				result.reject(new Exception("Timed out waiting for " ~ what));
			else
				setTimeout(&check, 10.msecs);
		}
		check();
		return result;
	}

	/// Runs a tool without blocking the event loop (it may call back into
	/// this process's own service), and returns its output.
	size_t toolRuns;
	Promise!string runTool(string[] argv)
	{
		auto outputPath = tempDir ~ "/ae-dbus-service-test-" ~
			thisProcessID.to!string ~ "-" ~ (toolRuns++).to!string;
		auto output = File(outputPath, "w");
		auto pid = spawnProcess(argv, stdin, output, output);
		output.close();
		auto result = new Promise!string;
		auto deadline = MonoTime.currTime + 10.seconds;
		void poll()
		{
			auto status = tryWait(pid);
			if (!status.terminated)
			{
				assert(MonoTime.currTime < deadline, argv[0] ~ " did not exit");
				setTimeout(&poll, 10.msecs);
				return;
			}
			auto text = readText(outputPath);
			remove(outputPath);
			if (status.status == 0)
				result.fulfill(text);
			else
				result.reject(new Exception(argv[0] ~ " failed: " ~ text));
		}
		poll();
		return result;
	}

	Promise!string dbusSend(string[] args)
	{
		return runTool(["dbus-send", "--session", "--print-reply", "--dest=" ~ serviceName] ~ args);
	}

	/// Summarizes an introspection document, one line per element.
	enum introspectionSummary = `
import sys, xml.etree.ElementTree as ET
root = ET.fromstring(sys.argv[1].strip())
def types(element, direction):
    return "".join(a.get("type") for a in element.findall("arg")
        if direction is None or a.get("direction") == direction)
for node in root.findall("node"):
    print("node", node.get("name"))
for interface in root.findall("interface"):
    print("interface", interface.get("name"))
    for method in interface.findall("method"):
        print("method %s(%s)->(%s)" % (method.get("name"), types(method, "in"), types(method, "out")))
    for signal in interface.findall("signal"):
        print("signal %s(%s)" % (signal.get("name"), types(signal, None)))
    for property in interface.findall("property"):
        print("property", property.get("name"), property.get("type"), property.get("access"))
`;
	Promise!(string[]) introspectWithTools(string path)
	{
		return runTool(["dbus-send", "--session", "--print-reply=literal", "--dest=" ~ serviceName,
				path, "org.freedesktop.DBus.Introspectable.Introspect"])
			.then((string xml) => runTool(["python3", "-I", "-c", introspectionSummary, xml]))
			.then((string summary) => summary.strip.split("\n"));
	}

	string remoteErrorName(T)(Promise!T promise)
	{
		try
			await(promise);
		catch (DbusRemoteError error)
			return error.errorName.text;
		assert(false, "Expected a D-Bus error reply");
	}

	async({
		// 1. Export the object.
		auto service = connectSessionBus();
		auto serviceUniqueName = await(service.ready);
		auto implementation = new TestObject;
		auto exported = exportObject!ITest(service, DbusObjectPath.parse(objectPath), implementation);

		// 2. Name ownership.
		string[] serviceAcquired, serviceLost;
		service.handleNameAcquired = (DbusBusName name) { serviceAcquired ~= name.text; };
		service.handleNameLost = (DbusBusName name) { serviceLost ~= name.text; };
		assert(await(service.requestName(DbusBusName.parse(serviceName),
			DbusRequestNameFlags.doNotQueue)) == DbusRequestNameReply.primaryOwner);
		await(waitFor(() => serviceAcquired.canFind(serviceName), "NameAcquired"));

		auto client = connectSessionBus();
		await(client.ready);
		string[] clientAcquired;
		client.handleNameAcquired = (DbusBusName name) { clientAcquired ~= name.text; };
		assert(await(client.requestName(DbusBusName.parse(serviceName),
			DbusRequestNameFlags.doNotQueue)) == DbusRequestNameReply.exists);
		assert(await(client.requestName(DbusBusName.parse(serviceName))) ==
			DbusRequestNameReply.inQueue);

		// 3. A method call from the reference tools.
		assert(await(dbusSend([objectPath, "org.ae.Test1.Add", "int32:2", "int32:3"]))
			.canFind("int32 5"));

		// 4. Introspection, as parsed by a standard XML parser.
		auto root = await(introspectWithTools("/"));
		assert(root.canFind("node org"), root.to!string);
		assert(root.canFind("interface org.freedesktop.DBus.Peer"));
		assert(root.canFind("interface org.freedesktop.DBus.Introspectable"));
		assert(!root.canFind("interface org.freedesktop.DBus.Properties"));
		auto object = await(introspectWithTools(objectPath));
		foreach (line; [
			"interface org.freedesktop.DBus.Peer",
			"interface org.freedesktop.DBus.Introspectable",
			"interface org.freedesktop.DBus.Properties",
			"interface org.ae.Test1",
			"method Add(ii)->(i)",
			"method Pair()->(is)",
			"method Slow()->()",
			"signal Changed(i)",
			"property Volume d readwrite",
			"property Name s read",
		])
			assert(object.canFind(line), line ~ " missing from " ~ object.to!string);
		assert(!object.canFind!(line => line.split(" ")[0] == "node"));

		// 5. Typed calls and error replies.
		auto proxy = dbusProxy!ITest(client, DbusBusName.parse(serviceName),
			DbusObjectPath.parse(objectPath));
		assert(await(proxy.Add(40, 2)) == 42);
		auto pair = await(proxy.Pair());
		assert(pair.values[0] == 1 && pair.values[1] == "one");
		assert(remoteErrorName(proxy.Fail()) == "org.ae.Test.Error.Custom");
		assert(remoteErrorName(proxy.Crash()) == "org.freedesktop.DBus.Error.Failed");

		Promise!DbusMessage rawCall(string path, string interfaceName, string member, DbusBody body)
		{
			DbusMethodCall request;
			request.destination = DbusBusName.parse(serviceName);
			request.path = DbusObjectPath.parse(path);
			request.interfaceName = DbusInterfaceName.parse(interfaceName);
			request.member = DbusMemberName.parse(member);
			request.body = body;
			return client.call(request);
		}
		assert(remoteErrorName(rawCall(objectPath, "org.ae.Test1", "Missing", DbusBody.from())) ==
			"org.freedesktop.DBus.Error.UnknownMethod");
		assert(remoteErrorName(rawCall(objectPath, "org.ae.Missing", "Add", DbusBody.from(1, 2))) ==
			"org.freedesktop.DBus.Error.UnknownInterface");
		assert(remoteErrorName(rawCall("/org/ae/Missing", "org.ae.Test1", "Add", DbusBody.from(1, 2))) ==
			"org.freedesktop.DBus.Error.UnknownObject");
		assert(remoteErrorName(rawCall(objectPath, "org.ae.Test1", "Add", DbusBody.from("x"))) ==
			"org.freedesktop.DBus.Error.InvalidArgs");

		auto peer = dbusProxy!DbusPeer(client, DbusBusName.parse(serviceName),
			DbusObjectPath.parse("/not/exported"));
		await(peer.Ping());
		string machineId;
		foreach (path; ["/var/lib/dbus/machine-id", "/etc/machine-id"])
		{
			try
				machineId = readText(path).strip;
			catch (FileException)
				continue;
			break;
		}
		if (machineId.length)
			assert(await(peer.GetMachineId()) == machineId);
		else
			assert(remoteErrorName(peer.GetMachineId()) == "org.freedesktop.DBus.Error.Failed");

		// 6. Properties.
		await(proxy.Volume(0.25));
		assert(await(proxy.Volume()) == 0.25);
		assert(implementation.volume == 0.25);
		static assert(!__traits(compiles, proxy.Name("renamed")));
		assert(remoteErrorName(rawCall(objectPath, "org.freedesktop.DBus.Properties", "Set",
			DbusBody.from("org.ae.Test1", "Name", DbusVariant.of("renamed")))) ==
			"org.freedesktop.DBus.Error.PropertyReadOnly");
		auto all = await(getAllProperties(proxy));
		assert(all.length == 2);
		assert(all["Volume"].get!double == 0.25);
		assert(all["Name"].get!string == "test-object");
		assert(await(dbusSend([objectPath, "org.freedesktop.DBus.Properties.Get",
			"string:org.ae.Test1", "string:Name"])).canFind(`string "test-object"`));

		// 7. Signals, delivered through the well-known name's owner.
		int[] changedValues;
		double[] volumes;
		auto changedSubscription = await(subscribe!(ITest.Changed)(proxy,
			(int value) { changedValues ~= value; }));
		auto propertiesSubscription = await(subscribePropertiesChanged(proxy,
			(DbusVariant[string] changed, string[] invalidated) {
				assert(!invalidated.length);
				volumes ~= changed["Volume"].get!double;
			}));
		exported.emit!(ITest.Changed)(7);
		exported.propertyChanged!"Volume"(0.5);
		await(waitFor(() => changedValues == [7] && volumes == [0.5], "signals"));
		await(changedSubscription.unsubscribe());
		await(propertiesSubscription.unsubscribe());

		// 8. Releasing the name passes it to the queued connection.
		assert(await(service.releaseName(DbusBusName.parse(serviceName))) ==
			DbusReleaseNameReply.released);
		await(waitFor(() => serviceLost.canFind(serviceName) &&
			clientAcquired.canFind(serviceName), "name handover"));

		// 9. Unexporting.
		auto direct = dbusProxy!ITest(client, DbusBusName.parse(serviceUniqueName.text),
			DbusObjectPath.parse(objectPath));
		exported.unexport();
		assert(remoteErrorName(direct.Add(1, 2)) == "org.freedesktop.DBus.Error.UnknownObject");

		// 10. A reply pending when the service disconnects is dropped,
		// and the bus answers the caller.
		exported = exportObject!ITest(service, DbusObjectPath.parse(objectPath), implementation);
		auto slow = direct.Slow();
		await(waitFor(() => implementation.slow !is null, "Slow call"));
		service.disconnect("D-Bus service test complete");
		implementation.slow.fulfill();
		assert(remoteErrorName(slow) == "org.freedesktop.DBus.Error.NoReply");

		client.disconnect("D-Bus service test complete");
		writeln("D-Bus service scenario passed");
	}).awaitSync();
}
