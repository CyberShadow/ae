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
 * - structured signal matching, `DbusSignalMatch`, from
 *   `ae.net.dbus.match`;
 * - the compile-time typed D-interface binding layer --
 *   `@DbusInterface`, `@DbusMember`, `DbusSignal`, `dbusProxy`,
 *   `DbusProxy`, `getProperty`, `setProperty`, `getAllProperties`,
 *   `subscribePropertiesChanged`, `subscribe`, `introspect` -- from
 *   `ae.net.dbus.binding`.
 *
 * `ae.net.dbus.address`, `ae.net.dbus.auth`, and `ae.net.dbus.codec` are
 * internal implementation modules: every declaration they expose beyond
 * their own module is `package(ae.net.dbus)` or narrower, so they have
 * nothing to re-export here and are not imported by this module.
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
public import ae.net.dbus.common;
public import ae.net.dbus.marshal;
public import ae.net.dbus.match;
public import ae.net.dbus.signature;
public import ae.net.dbus.value;

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
