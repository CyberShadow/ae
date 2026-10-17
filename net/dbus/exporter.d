/**
 * Typed object export: serving a D class through the D-Bus interface it
 * implements.
 *
 * `exportObject` registers an implementation of a `@DbusInterface` D
 * interface, the same declaration `dbusProxy` consumes, with a
 * connection's object registry.  Method calls are decoded into the
 * typed arguments of the matching D method, and its promised result is
 * encoded as the reply; `@DbusProperty` accessors serve
 * `org.freedesktop.DBus.Properties`.  Wire names and signatures come
 * from `ae.net.dbus.description`, so the exported object, its proxies
 * and its introspection data always agree.
 *
 * A remote `Set` does not announce the change: the setter decides
 * whether the value changed, and calls `DbusExport.propertyChanged` or
 * `propertyInvalidated` if so.
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

module ae.net.dbus.exporter;

import std.typecons : Tuple;

import ae.net.dbus.client : DbusConnection, DbusSignalEmission;
import ae.net.dbus.common;
import ae.net.dbus.description;
import ae.net.dbus.service;
import ae.net.dbus.signature : DbusOut;
import ae.net.dbus.standard : DbusProperties;
import ae.net.dbus.value : DbusBody, DbusVariant;
import ae.utils.promise : Promise;

/// Exports `implementation` as the D-Bus interface `I` at `path` on
/// `connection`.  Throws like `DbusObjectRegistry.register`, e.g. if
/// `I` is already registered at `path`.
DbusExport!I exportObject(I)(DbusConnection connection, DbusObjectPath path, I implementation)
if (is(I == interface))
{
	assert(implementation !is null, "Exported D-Bus object is null");
	DbusInterfaceImplementation result;
	result.description = dbusInterfaceDescription!I;
	static foreach (index; 0 .. DbusMethodInfos!I.length)
		result.methods ~= dbusMethodHandler!(DbusMethodInfos!I[index])(implementation);
	static foreach (index; 0 .. DbusPropertyInfos!I.length)
		result.properties ~= dbusPropertyHandlers!(DbusPropertyInfos!I[index])(implementation);
	return new DbusExport!I(connection, connection.objects.register(path, result));
}

/// An object exported with `exportObject`: emits its signals and
/// property notifications, and ends the export.
final class DbusExport(I)
if (is(I == interface))
{
	/// The object path the implementation is exported at.
	@property DbusObjectPath path() const { return registration_.path; }

	/// Broadcasts the signal `Signal`, a `DbusSignal` alias declared on `I`.
	void emit(alias Signal)(Signal.Types args)
	{
		static assert(dbusDeclaresSignal!(I, Signal),
			"D-Bus signal " ~ Signal.name ~ " is not declared on " ~ I.stringof);
		enum member = DbusMemberName.parse(Signal.name);
		send(interfaceName, member, DbusBody.from(args));
	}

	/// Broadcasts `PropertiesChanged` with the new `value` of the property
	/// declared by the accessors named `property`, which must announce
	/// changes with their value (`DbusEmitsChangedSignal.true_`).
	void propertyChanged(string property)(DbusPropertyType!(I, property) value)
	{
		alias Info = DbusPropertyInfoOf!(I, property);
		static assert(Info.emitsChangedSignal == DbusEmitsChangedSignal.true_,
			"D-Bus property " ~ property ~ " does not announce changes with values");
		DbusVariant[string] changed = [Info.wireName: DbusVariant.of!(Info.Type)(value)];
		sendPropertiesChanged(changed, null);
	}

	/// Broadcasts `PropertiesChanged` invalidating the property declared
	/// by the accessors named `property`, which must announce changes
	/// without their value (`DbusEmitsChangedSignal.invalidates`).
	void propertyInvalidated(string property)()
	{
		alias Info = DbusPropertyInfoOf!(I, property);
		static assert(Info.emitsChangedSignal == DbusEmitsChangedSignal.invalidates,
			"D-Bus property " ~ property ~ " does not announce changes by invalidation");
		sendPropertiesChanged(null, [Info.wireName]);
	}

	/// Stops serving the object.  Calls already being handled still get
	/// their replies; the object must not emit afterwards.
	void unexport()
	{
		registration_.unregister();
	}

private:
	DbusConnection connection_;
	DbusInterfaceRegistration registration_;

	enum interfaceName = dbusInterfaceDescription!I.name;

	this(DbusConnection connection, DbusInterfaceRegistration registration)
	{
		connection_ = connection;
		registration_ = registration;
	}

	void sendPropertiesChanged(DbusVariant[string] changed, string[] invalidated)
	{
		alias Signal = DbusProperties.PropertiesChanged;
		enum propertiesInterfaceName = dbusInterfaceDescription!DbusProperties.name;
		enum member = DbusMemberName.parse(Signal.name);
		send(propertiesInterfaceName, member,
			DbusBody.from(interfaceName.text, changed, invalidated));
	}

	void send(DbusInterfaceName signalInterface, DbusMemberName member, DbusBody body)
	{
		assert(registration_.active, "D-Bus signal emitted by an unexported object");
		DbusSignalEmission signal;
		signal.path = registration_.path;
		signal.interfaceName = signalInterface;
		signal.member = member;
		signal.body = body;
		connection_.emitSignal(signal);
	}
}

private:

/// Whether `Signal` is one of the `DbusSignal` aliases declared on `I`.
template dbusDeclaresSignal(I, Signal)
{
	enum dbusDeclaresSignal = () {
		bool found;
		static foreach (index; 0 .. DbusSignalInfos!I.length)
			static if (is(DbusSignalInfos!I[index].Signal == Signal))
				found = true;
		return found;
	}();
}

/// Decodes the call's arguments (whose signature the registry has
/// checked), calls the method `Info` of `implementation`, and encodes
/// its result.
DbusMethodHandler dbusMethodHandler(alias Info, I)(I implementation)
{
	return (const ref DbusMessage call) {
		Tuple!(Info.Params) args;
		auto values = call.body.values;
		static foreach (index, Param; Info.Params)
		{
			try
				args[index] = values[index].get!Param;
			catch (DbusTypeMismatchException e)
				throw new DbusError(DbusErrorNames.invalidArgs, e.msg);
		}
		auto method = &__traits(getOverloads, implementation, Info.identifier)[Info.overloadIndex];
		alias Result = Info.Result;
		static if (is(Result == void))
			return method(args.expand).then(() => DbusBody.from());
		else static if (is(Result == DbusOut!Types, Types...))
			return method(args.expand).then((Result result) => DbusBody.from(result.values.expand));
		else
			return method(args.expand).then((Result result) => DbusBody.from(result));
	};
}

/// Wraps the accessors of the property `Info` of `implementation`.  The
/// registry passes the setter only values of the declared type.
DbusPropertyHandlers dbusPropertyHandlers(alias Info, I)(I implementation)
{
	alias Type = Info.Type;
	DbusPropertyHandlers handlers;
	static if (Info.hasGetter)
		handlers.get = () {
			auto getter = &__traits(getOverloads, implementation, Info.identifier)[Info.getterIndex];
			return getter().then((Type value) => DbusVariant.of!Type(value));
		};
	static if (Info.hasSetter)
		handlers.set = (DbusVariant value) {
			auto setter = &__traits(getOverloads, implementation, Info.identifier)[Info.setterIndex];
			Type decoded;
			try
				decoded = value.get!Type;
			catch (DbusTypeMismatchException e)
				throw new DbusError(DbusErrorNames.invalidArgs, e.msg);
			return setter(decoded);
		};
	return handlers;
}

// The tests run exported objects on connections attached to the in-memory
// transport, which is only defined for Posix.
version(Posix)
{

debug(ae_unittest) import ae.net.asockets : socketManager;
debug(ae_unittest) import ae.net.dbus.binding : dbusProxy, getAllProperties;
debug(ae_unittest) import ae.net.dbus.client : attachDbusConnection;
debug(ae_unittest) import ae.net.dbus.introspection : dbusIntrospectionXml, dbusNodeXml;
debug(ae_unittest) import ae.net.dbus.standard : dbusIntrospectableXml, dbusPeerXml, dbusPropertiesXml;
debug(ae_unittest) import ae.net.dbus.marshal : decodeDbusMessage, encodeDbusMessage;
debug(ae_unittest) import ae.net.dbus.testing;
debug(ae_unittest) import ae.utils.promise : resolve;

debug(ae_unittest)
{
	enum DbusExporterTestMode : int { stopped, playing }

	@DbusInterface("org.example.Exported")
	interface DbusExporterTestInterface
	{
		Promise!void Play();
		Promise!int Add(int a, int b);
		Promise!(DbusOut!(uint, string)) GetPosition();
		@DbusMember("Seek") Promise!long seek(long offset);
		@DbusMember("SeekFrom") Promise!long seek(long offset, bool relative);
		Promise!void Fail();
		Promise!void SetMode(DbusExporterTestMode mode);
		@DbusProperty Promise!DbusExporterTestMode Mode();
		@DbusProperty Promise!void Mode(DbusExporterTestMode mode);
		@DbusProperty Promise!double Volume();
		@DbusProperty Promise!void Volume(double value);
		@DbusPropertyAttribute(DbusEmitsChangedSignal.invalidates) Promise!string Title();
		@DbusProperty Promise!void Secret(string value);
		alias Seeked = DbusSignal!("Seeked", long);
		alias Stopped = DbusSignal!("Stopped");
	}

	class DbusExporterTestObject : DbusExporterTestInterface
	{
		string[] calls;
		double volume = 0.25;
		string title = "Intro";
		string secret;
		DbusExporterTestMode mode;

		Promise!void Play() { calls ~= "Play"; return resolve(); }
		Promise!int Add(int a, int b) { calls ~= "Add"; return resolve(a + b); }
		Promise!(DbusOut!(uint, string)) GetPosition()
		{
			DbusOut!(uint, string) result;
			result.values[0] = 7;
			result.values[1] = "seven";
			return resolve(result);
		}
		Promise!long seek(long offset) { calls ~= "Seek"; return resolve(offset); }
		Promise!long seek(long offset, bool relative)
		{
			calls ~= "SeekFrom";
			return resolve(relative ? 100 + offset : offset);
		}
		Promise!void Fail()
		{
			throw new DbusError(DbusErrorName.parse("org.example.Error.Failed"), "nope");
		}
		Promise!void SetMode(DbusExporterTestMode value) { mode = value; return resolve(); }
		Promise!DbusExporterTestMode Mode() { return resolve(mode); }
		Promise!void Mode(DbusExporterTestMode value) { mode = value; return resolve(); }
		Promise!double Volume() { return resolve(volume); }
		Promise!void Volume(double value) { volume = value; return resolve(); }
		Promise!string Title() { return resolve(title); }
		Promise!void Secret(string value) { secret = value; return resolve(); }
	}

	/// An exported test object on a ready connection named ":1.42".
	struct DbusExporterTestService
	{
		DbusTestConnection transport;
		DbusExporterTestObject object;
		DbusExport!DbusExporterTestInterface exported;
		uint serial = 100;

		static DbusExporterTestService create()
		{
			DbusExporterTestService service;
			service.transport = new DbusTestConnection;
			auto connection = attachDbusConnection(service.transport);
			connection.ready.ignoreResult();
			dbusTestAuthenticate(service.transport);
			service.object = new DbusExporterTestObject;
			service.exported = exportObject!DbusExporterTestInterface(connection,
				DbusObjectPath.parse("/org/example/Exported"), service.object);
			return service;
		}

		/// Delivers a method call from ":1.99" and returns the reply.
		DbusMessage call(string interfaceName, string member, DbusBody body)
		{
			auto sent = transport.sent.length;
			transport.receive(dbusTestMethodCall(++serial, ":1.99",
				DbusObjectPath.parse("/org/example/Exported"), interfaceName, member, body));
			socketManager.loop();
			assert(transport.sent.length == sent + 1);
			auto reply = dbusTestSentMessage(transport, sent);
			assert(reply.headers.replySerial == serial);
			return reply;
		}

		DbusMessage call(string member, DbusBody body = DbusBody.from())
		{
			return call("org.example.Exported", member, body);
		}

		/// The only message sent since `sent` messages, which must be a
		/// broadcast signal from the exported object.
		DbusMessage takeSignal(size_t sent)
		{
			assert(transport.sent.length == sent + 1);
			auto signal = dbusTestSentMessage(transport, sent);
			assert(signal.messageType == DbusMessageType.signal);
			assert(signal.headers.path.text == "/org/example/Exported");
			assert(!signal.headers.destination.text.length);
			return signal;
		}
	}
}

// Method calls and property access reach the implementation's methods
// and accessors.
debug(ae_unittest) unittest
{
	auto service = DbusExporterTestService.create();
	auto object = service.object;

	auto reply = service.call("Play");
	assert(reply.messageType == DbusMessageType.methodReturn);
	assert(reply.body.signature.text == "");
	reply = service.call("Add", DbusBody.from(2, 3));
	assert(reply.body.signature.text == "i");
	assert(reply.body.values[0].get!int == 5);
	reply = service.call("GetPosition");
	assert(reply.body.signature.text == "us");
	assert(reply.body.values[0].get!uint == 7);
	assert(reply.body.values[1].get!string == "seven");
	reply = service.call("Seek", DbusBody.from(5L));
	assert(reply.body.values[0].get!long == 5);
	reply = service.call("SeekFrom", DbusBody.from(5L, true));
	assert(reply.body.values[0].get!long == 105);
	assert(object.calls == ["Play", "Add", "Seek", "SeekFrom"]);

	reply = service.call("Fail");
	assert(reply.messageType == DbusMessageType.error);
	assert(reply.headers.errorName.text == "org.example.Error.Failed");
	assert(reply.body.values[0].get!string == "nope");
	reply = service.call("Add", DbusBody.from(2));
	assert(reply.headers.errorName.text == "org.freedesktop.DBus.Error.InvalidArgs");

	enum properties = "org.freedesktop.DBus.Properties";
	reply = service.call(properties, "Get", DbusBody.from("org.example.Exported", "Volume"));
	assert(reply.body.signature.text == "v");
	assert(reply.body.values[0].get!DbusVariant.get!double == 0.25);
	reply = service.call(properties, "Set",
		DbusBody.from("org.example.Exported", "Volume", DbusVariant.of(0.5)));
	assert(reply.messageType == DbusMessageType.methodReturn);
	assert(object.volume == 0.5);
	reply = service.call(properties, "Set",
		DbusBody.from("org.example.Exported", "Secret", DbusVariant.of("hidden")));
	assert(reply.messageType == DbusMessageType.methodReturn);
	assert(object.secret == "hidden");
	reply = service.call(properties, "Set",
		DbusBody.from("org.example.Exported", "Title", DbusVariant.of("Outro")));
	assert(reply.headers.errorName.text == "org.freedesktop.DBus.Error.PropertyReadOnly");
	reply = service.call(properties, "GetAll", DbusBody.from("org.example.Exported"));
	auto all = reply.body.values[0].get!(DbusVariant[string]);
	assert(all.length == 3);
	assert(all["Volume"].get!double == 0.5);
	assert(all["Title"].get!string == "Intro");
	assert(all["Mode"].get!DbusExporterTestMode == DbusExporterTestMode.stopped);

	reply = service.call("org.freedesktop.DBus.Introspectable", "Introspect", DbusBody.from());
	assert(reply.body.values[0].get!string == dbusNodeXml([dbusPeerXml, dbusIntrospectableXml,
		dbusPropertiesXml, dbusIntrospectionXml!DbusExporterTestInterface], null));
}

// Undefined enum values are rejected before a typed method or setter runs.
debug(ae_unittest) unittest
{
	auto service = DbusExporterTestService.create();
	auto reply = service.call("SetMode", DbusBody.from(99));
	assert(reply.messageType == DbusMessageType.error);
	assert(reply.headers.replySerial == service.serial);
	assert(reply.headers.errorName.text == "org.freedesktop.DBus.Error.InvalidArgs");
	assert(service.object.mode == DbusExporterTestMode.stopped);

	reply = service.call("org.freedesktop.DBus.Properties", "Set",
		DbusBody.from("org.example.Exported", "Mode", DbusVariant.of(99)));
	assert(reply.messageType == DbusMessageType.error);
	assert(reply.headers.replySerial == service.serial);
	assert(reply.headers.errorName.text == "org.freedesktop.DBus.Error.InvalidArgs");
	assert(service.object.mode == DbusExporterTestMode.stopped);
}

// Signals and property change notifications.
debug(ae_unittest) unittest
{
	auto service = DbusExporterTestService.create();
	auto exported = service.exported;
	assert(exported.path.text == "/org/example/Exported");

	auto sent = service.transport.sent.length;
	exported.emit!(DbusExporterTestInterface.Seeked)(5);
	auto signal = service.takeSignal(sent);
	assert(signal.headers.interfaceName.text == "org.example.Exported");
	assert(signal.headers.member.text == "Seeked");
	assert(signal.body.signature.text == "x");
	assert(signal.body.values[0].get!long == 5);

	sent = service.transport.sent.length;
	exported.emit!(DbusExporterTestInterface.Stopped)();
	signal = service.takeSignal(sent);
	assert(signal.headers.member.text == "Stopped");
	assert(signal.body.signature.text == "");

	sent = service.transport.sent.length;
	exported.propertyChanged!"Volume"(0.5);
	signal = service.takeSignal(sent);
	assert(signal.headers.interfaceName.text == "org.freedesktop.DBus.Properties");
	assert(signal.headers.member.text == "PropertiesChanged");
	assert(signal.body.signature.text == "sa{sv}as");
	assert(signal.body.values[0].get!string == "org.example.Exported");
	auto changed = signal.body.values[1].get!(DbusVariant[string]);
	assert(changed.length == 1);
	assert(changed["Volume"].get!double == 0.5);
	assert(signal.body.values[2].get!(string[]).length == 0);

	sent = service.transport.sent.length;
	exported.propertyInvalidated!"Title"();
	signal = service.takeSignal(sent);
	assert(signal.body.signature.text == "sa{sv}as");
	assert(signal.body.values[1].get!(DbusVariant[string]).length == 0);
	assert(signal.body.values[2].get!(string[]) == ["Title"]);

	static assert( __traits(compiles, exported.emit!(DbusExporterTestInterface.Seeked)(5)));
	static assert(!__traits(compiles, exported.emit!(DbusExporterTestInterface.Seeked)("5")));
	static assert(!__traits(compiles, exported.emit!(DbusSignal!("Seeked", int))(5)));
	static assert(!__traits(compiles, exported.emit!(DbusSignal!("Elsewhere", long))(5)));
	static assert(!__traits(compiles, exported.propertyChanged!"Volume"("loud")));
	static assert(!__traits(compiles, exported.propertyChanged!"Title"("Outro")));
	static assert(!__traits(compiles, exported.propertyChanged!"Missing"(1)));
	static assert(!__traits(compiles, exported.propertyInvalidated!"Volume"()));
	static assert(!__traits(compiles, exported.propertyChanged!"Play"(1)));
}

// Unexporting removes the object; calls already being handled still
// get their replies.
debug(ae_unittest) unittest
{
	auto service = DbusExporterTestService.create();
	service.exported.unexport();
	auto reply = service.call("Add", DbusBody.from(2, 3));
	assert(reply.headers.errorName.text == "org.freedesktop.DBus.Error.UnknownObject");
	assert(service.object.calls.length == 0);

	// The interface can be exported again at the same path.
	auto connection = service.exported.connection_;
	auto exported = exportObject!DbusExporterTestInterface(connection,
		DbusObjectPath.parse("/org/example/Exported"), service.object);
	reply = service.call("Add", DbusBody.from(2, 3));
	assert(reply.body.values[0].get!int == 5);
	exported.unexport();
}

// A typed proxy and a typed export of the same interface agree on the
// wire: the proxy's requests are relayed to the exporting connection and
// the replies back, as a bus would.
debug(ae_unittest) unittest
{
	auto clientTransport = new DbusTestConnection;
	auto client = attachDbusConnection(clientTransport);
	client.ready.ignoreResult();
	dbusTestAuthenticate(clientTransport, ":1.10");
	auto service = DbusExporterTestService.create();

	void relay(DbusTestConnection from, size_t index, DbusTestConnection to, string sender)
	{
		auto message = decodeDbusMessage(from.sent[index].toGC);
		message.headers.sender = DbusBusName.parse(sender);
		to.receive(encodeDbusMessage(message));
	}

	/// Relays the request the client just sent, and the reply to it.
	void roundTrip()
	{
		assert(clientTransport.sent.length == 5);
		auto serviceSent = service.transport.sent.length;
		relay(clientTransport, 4, service.transport, ":1.10");
		clientTransport.sent = clientTransport.sent[0 .. 4];
		socketManager.loop();
		assert(service.transport.sent.length == serviceSent + 1);
		relay(service.transport, serviceSent, clientTransport, ":1.42");
		socketManager.loop();
	}

	auto proxy = dbusProxy!DbusExporterTestInterface(client,
		DbusBusName.parse(":1.42"), DbusObjectPath.parse("/org/example/Exported"));

	int sum;
	proxy.Add(2, 3).then((int value) { sum = value; }).ignoreResult();
	roundTrip();
	assert(sum == 5);

	DbusOut!(uint, string) position;
	proxy.GetPosition().then((DbusOut!(uint, string) value) { position = value; }).ignoreResult();
	roundTrip();
	assert(position.values[0] == 7 && position.values[1] == "seven");

	long offset;
	proxy.seek(5, true).then((long value) { offset = value; }).ignoreResult();
	roundTrip();
	assert(offset == 105);

	bool played;
	proxy.Play().then({ played = true; }).ignoreResult();
	roundTrip();
	assert(played);

	string errorName;
	proxy.Fail().then({ assert(false); }, (Exception e) {
		errorName = (cast(DbusRemoteError) e).errorName.text;
	}).ignoreResult();
	roundTrip();
	assert(errorName == "org.example.Error.Failed");

	proxy.Volume(0.75).ignoreResult();
	roundTrip();
	assert(service.object.volume == 0.75);
	double volume;
	proxy.Volume().then((double value) { volume = value; }).ignoreResult();
	roundTrip();
	assert(volume == 0.75);

	proxy.Secret("hidden").ignoreResult();
	roundTrip();
	assert(service.object.secret == "hidden");

	DbusVariant[string] all;
	getAllProperties(proxy).then((DbusVariant[string] value) { all = value; }).ignoreResult();
	roundTrip();
	assert(all.length == 3 && all["Title"].get!string == "Intro");
}

}
