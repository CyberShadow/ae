/**
 * Typed D-interface bindings for D-Bus proxies.
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

module ae.net.dbus.binding;

import std.conv : to;
import std.traits : ParameterTypeTuple, ReturnType;
import std.typecons : Tuple;

public import ae.net.dbus.description;

import ae.net.dbus.client : DbusConnection, DbusMethodCall, DbusSubscription;
import ae.net.dbus.common;
import ae.net.dbus.match : DbusSignalMatch;
import ae.net.dbus.signature : DbusOut, dbusSignature;
import ae.net.dbus.value : DbusBody, DbusValue, DbusVariant;
import ae.utils.promise : Promise, PromiseValue;

private void requireDbusEmptyReply(const ref DbusBody body)
{
	if (body.signature.text.length)
		throw new DbusTypeMismatchException("expected an empty D-Bus reply body");
}

private T decodeDbusSingleReply(T)(const ref DbusBody body)
{
	enum expected = dbusSignature!T;
	auto values = body.values;
	if (body.signature.text != expected || values.length != 1)
		throw new DbusTypeMismatchException(
			"expected a D-Bus reply body with signature " ~ expected);
	return values[0].get!T;
}

private T decodeDbusOutReply(T)(const ref DbusBody body)
if (is(T == DbusOut!Types, Types...))
{
	alias Types = T.Types;
	enum expected = dbusTypesSignature!Types;
	auto values = body.values;
	if (body.signature.text != expected || values.length != Types.length)
		throw new DbusTypeMismatchException(
			"expected a D-Bus reply body with signature " ~ expected);
	T result;
	static foreach (index, Type; Types)
		result.values[index] = values[index].get!Type;
	return result;
}

private void invokeWithDecodedValues(Types...)(void delegate(Types) handler,
	scope const(DbusValue)[] values)
{
	Tuple!Types args;
	static foreach (index, Type; Types)
		args[index] = values[index].get!Type;
	handler(args.expand);
}

private string generateDbusProxyMethod(I, size_t infoIndex)()
{
	alias Info = DbusMethodInfos!I[infoIndex];

	// Every generated type position below names a local alias, never a
	// consumer-owned type's `.stringof` spelling, so that this mixin
	// compiles regardless of the visibility of I's own dependencies.
	enum suffix = infoIndex.to!string;
	string code;

	code ~= "alias __dbusMethod_" ~ suffix ~
		" = DbusMethodInfos!I[" ~ suffix ~ "].Method;\n";
	code ~= "alias __dbusParams_" ~ suffix ~
		" = ParameterTypeTuple!__dbusMethod_" ~ suffix ~ ";\n";
	code ~= "alias __dbusReturn_" ~ suffix ~
		" = ReturnType!__dbusMethod_" ~ suffix ~ ";\n";
	code ~= "override __dbusReturn_" ~ suffix ~ " " ~ Info.identifier ~ "(";

	static foreach (parameterIndex; 0 .. Info.Params.length)
	{
		static if (parameterIndex > 0)
			code ~= ", ";
		code ~= "__dbusParams_" ~ suffix ~ "[" ~ parameterIndex.to!string ~
			"] __dbusArg_" ~ suffix ~ "_" ~ parameterIndex.to!string;
	}

	code ~= ")\n{\n\treturn invoke!(DbusMethodInfos!I[" ~ suffix ~ "])(";
	static foreach (parameterIndex; 0 .. Info.Params.length)
	{
		static if (parameterIndex > 0)
			code ~= ", ";
		code ~= "__dbusArg_" ~ suffix ~ "_" ~ parameterIndex.to!string;
	}
	code ~= ");\n}";

	return code;
}

/// A generated client-side proxy implementing `I` by dispatching calls
/// over a `DbusConnection`. Create instances with `dbusProxy`.
final class DbusProxy(I) : I
if (is(I == interface))
{
	private DbusConnection __dbusConnection;
	private DbusBusName __dbusDestination;
	private DbusObjectPath __dbusPath;
	private enum __dbusInterfaceName = dbusInterfaceDescription!I.name;

	private this(DbusConnection connection, DbusBusName destination, DbusObjectPath path)
	{
		__dbusConnection = connection;
		__dbusDestination = destination;
		__dbusPath = path;
	}

	static foreach (infoIndex; 0 .. DbusMethodInfos!I.length)
		mixin(generateDbusProxyMethod!(I, infoIndex));

	private ReturnType!(Info.Method) invoke(alias Info, Args...)(Args args)
	{
		alias ResultType = Info.Result;
		enum memberName = DbusMemberName.parse(Info.wireName);

		DbusMethodCall request;
		request.destination = __dbusDestination;
		request.path = __dbusPath;
		request.interfaceName = __dbusInterfaceName;
		request.member = memberName;
		request.body = DbusBody.from(args);

		static if (is(ResultType == void))
			return __dbusConnection.call(request).then((DbusMessage reply) {
				requireDbusEmptyReply(reply.body);
			});
		else static if (is(ResultType == DbusOut!Types, Types...))
			return __dbusConnection.call(request).then((DbusMessage reply) {
				return decodeDbusOutReply!ResultType(reply.body);
			});
		else
			return __dbusConnection.call(request).then((DbusMessage reply) {
				return decodeDbusSingleReply!ResultType(reply.body);
			});
	}
}

/// Creates a typed proxy for `I` at the given destination and object path.
DbusProxy!I dbusProxy(I)(DbusConnection connection, DbusBusName destination, DbusObjectPath path)
{
	return new DbusProxy!I(connection, destination, path);
}

private enum dbusPropertiesInterfaceName = DbusInterfaceName.parse("org.freedesktop.DBus.Properties");
private enum dbusIntrospectableInterfaceName = DbusInterfaceName.parse("org.freedesktop.DBus.Introspectable");

private enum dbusGetMemberName = DbusMemberName.parse("Get");
private enum dbusSetMemberName = DbusMemberName.parse("Set");
private enum dbusGetAllMemberName = DbusMemberName.parse("GetAll");
private enum dbusPropertiesChangedMemberName = DbusMemberName.parse("PropertiesChanged");
private enum dbusIntrospectMemberName = DbusMemberName.parse("Introspect");

/// Reads a single property through `org.freedesktop.DBus.Properties.Get`.
Promise!T getProperty(T, I)(DbusProxy!I proxy, string propertyName)
{
	DbusMethodCall request;
	request.destination = proxy.__dbusDestination;
	request.path = proxy.__dbusPath;
	request.interfaceName = dbusPropertiesInterfaceName;
	request.member = dbusGetMemberName;
	request.body = DbusBody.from(proxy.__dbusInterfaceName.text, propertyName);
	return proxy.__dbusConnection.call(request).then((DbusMessage reply) {
		return decodeDbusSingleReply!DbusVariant(reply.body).get!T;
	});
}

/// Writes a single property through `org.freedesktop.DBus.Properties.Set`.
Promise!void setProperty(T, I)(DbusProxy!I proxy, string propertyName, T value)
{
	DbusMethodCall request;
	request.destination = proxy.__dbusDestination;
	request.path = proxy.__dbusPath;
	request.interfaceName = dbusPropertiesInterfaceName;
	request.member = dbusSetMemberName;
	request.body = DbusBody.from(proxy.__dbusInterfaceName.text, propertyName, DbusVariant.of!T(value));
	return proxy.__dbusConnection.call(request).then((DbusMessage reply) {
		requireDbusEmptyReply(reply.body);
	});
}

/// Reads all properties through `org.freedesktop.DBus.Properties.GetAll`.
Promise!(DbusVariant[string]) getAllProperties(I)(DbusProxy!I proxy)
{
	DbusMethodCall request;
	request.destination = proxy.__dbusDestination;
	request.path = proxy.__dbusPath;
	request.interfaceName = dbusPropertiesInterfaceName;
	request.member = dbusGetAllMemberName;
	request.body = DbusBody.from(proxy.__dbusInterfaceName.text);
	return proxy.__dbusConnection.call(request).then((DbusMessage reply) {
		return decodeDbusSingleReply!(DbusVariant[string])(reply.body);
	});
}

/// Subscribes to `org.freedesktop.DBus.Properties.PropertiesChanged`,
/// filtered to the properties of `I`'s own D-Bus interface.
Promise!DbusSubscription subscribePropertiesChanged(I)(DbusProxy!I proxy,
	void delegate(DbusVariant[string] changed, string[] invalidated) handler)
{
	auto match = DbusSignalMatch.signal()
		.withSender(proxy.__dbusDestination)
		.withPath(proxy.__dbusPath)
		.withInterface(dbusPropertiesInterfaceName)
		.withMember(dbusPropertiesChangedMemberName)
		.withArgument(0, proxy.__dbusInterfaceName.text);

	enum expectedSignature = "sa{sv}as";
	return proxy.__dbusConnection.subscribe(match, DbusSignature.parse(expectedSignature),
		(const ref DbusSignalMessage message) {
			auto values = message.body.values;
			handler(values[1].get!(DbusVariant[string]), values[2].get!(string[]));
		});
}

/// Subscribes to a `DbusSignal` declared on `I`, such as
/// `alias SomeSignal = DbusSignal!("SomeSignal", Args...);`.
Promise!DbusSubscription subscribe(alias Signal, I)(DbusProxy!I proxy,
	void delegate(Signal.Types) handler)
{
	enum memberName = DbusMemberName.parse(Signal.name);

	auto match = DbusSignalMatch.signal()
		.withSender(proxy.__dbusDestination)
		.withPath(proxy.__dbusPath)
		.withInterface(proxy.__dbusInterfaceName)
		.withMember(memberName);

	enum expectedSignature = dbusTypesSignature!(Signal.Types);
	return proxy.__dbusConnection.subscribe(match, DbusSignature.parse(expectedSignature),
		(const ref DbusSignalMessage message) {
			invokeWithDecodedValues(handler, message.body.values);
		});
}

/// Reads the XML introspection document through
/// `org.freedesktop.DBus.Introspectable.Introspect`.
Promise!string introspect(I)(DbusProxy!I proxy)
{
	DbusMethodCall request;
	request.destination = proxy.__dbusDestination;
	request.path = proxy.__dbusPath;
	request.interfaceName = dbusIntrospectableInterfaceName;
	request.member = dbusIntrospectMemberName;
	return proxy.__dbusConnection.call(request).then((DbusMessage reply) {
		return decodeDbusSingleReply!string(reply.body);
	});
}

// The behavioral test harness below depends on `attachDbusConnection`,
// which is only defined for Posix, matching client.d's own test harness.
version(Posix)
{

debug(ae_unittest)
import ae.net.asockets : socketManager;
debug(ae_unittest)
import ae.net.dbus.client : attachDbusConnection;
debug(ae_unittest)
import ae.net.dbus.testing;
debug(ae_unittest)
import std.string : indexOf;

debug(ae_unittest)
@DbusInterface("org.example.Test")
private interface DbusBindingTestInterface
{
	Promise!void DoSomething(int value);
	Promise!int GetValue();
	Promise!(DbusOut!(int, string)) GetPair();
	alias Changed = DbusSignal!("Changed", int);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	int fulfilled;
	proxy.DoSomething(42).then(() { fulfilled++; }).ignoreResult();

	assert(transport.sent.length == 5);
	auto request = dbusTestSentMessage(transport, 4);
	assert(request.messageType == DbusMessageType.methodCall);
	assert(request.headers.destination.text == ":1.99");
	assert(request.headers.path.text == "/org/example/Test");
	assert(request.headers.interfaceName.text == "org.example.Test");
	assert(request.headers.member.text == "DoSomething");
	assert(request.body.signature.text == "i");
	assert(request.body.values[0].get!int == 42);

	transport.receive(dbusTestMethodReturn(request.serial, DbusBody.from()));
	socketManager.loop();
	assert(fulfilled == 1);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	DbusOut!(int, string) decoded;
	proxy.GetPair().then((DbusOut!(int, string) result) { decoded = result; }).ignoreResult();
	auto request = dbusTestSentMessage(transport, 4);
	assert(request.headers.member.text == "GetPair");
	transport.receive(dbusTestMethodReturn(request.serial, DbusBody.from(7, "seven")));
	socketManager.loop();
	assert(decoded.values[0] == 7);
	assert(decoded.values[1] == "seven");
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	Exception rejected;
	proxy.GetValue().then((int) { assert(false); }, (Exception exception) {
		rejected = exception;
	}).ignoreResult();

	auto first = dbusTestSentMessage(transport, 4);
	transport.receive(dbusTestMethodReturn(first.serial, DbusBody.from("wrong")));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) rejected !is null);
	assert(transport.disconnectCount == 0);

	int fulfilled;
	proxy.GetValue().then((int value) { fulfilled = value; }).ignoreResult();
	auto second = dbusTestSentMessage(transport, 5);
	transport.receive(dbusTestMethodReturn(second.serial, DbusBody.from(7)));
	socketManager.loop();
	assert(fulfilled == 7);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	Exception rejected;
	proxy.GetValue().then((int) { assert(false); }, (Exception exception) {
		rejected = exception;
	}).ignoreResult();
	auto request = dbusTestSentMessage(transport, 4);
	transport.receive(dbusTestError(request.serial, "org.example.Error", "failed"));
	socketManager.loop();
	auto remote = cast(DbusRemoteError) rejected;
	assert(remote !is null);
	assert(remote.errorName.text == "org.example.Error");

	Exception propertyRejected;
	getProperty!int(proxy, "Value").then((int) { assert(false); }, (Exception exception) {
		propertyRejected = exception;
	}).ignoreResult();
	auto propertyRequest = dbusTestSentMessage(transport, 5);
	transport.receive(dbusTestError(propertyRequest.serial, "org.example.Error", "failed"));
	socketManager.loop();
	assert(cast(DbusRemoteError) propertyRejected !is null);

	Exception introspectRejected;
	introspect(proxy).then((string) { assert(false); }, (Exception exception) {
		introspectRejected = exception;
	}).ignoreResult();
	auto introspectRequest = dbusTestSentMessage(transport, 6);
	transport.receive(dbusTestError(introspectRequest.serial, "org.example.Error", "failed"));
	socketManager.loop();
	assert(cast(DbusRemoteError) introspectRejected !is null);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	int gotValue;
	getProperty!int(proxy, "Value").then((int value) { gotValue = value; }).ignoreResult();
	auto get = dbusTestSentMessage(transport, 4);
	assert(get.headers.interfaceName.text == "org.freedesktop.DBus.Properties");
	assert(get.headers.member.text == "Get");
	assert(get.body.signature.text == "ss");
	assert(get.body.values[0].get!string == "org.example.Test");
	assert(get.body.values[1].get!string == "Value");
	transport.receive(dbusTestMethodReturn(get.serial,
		DbusBody.from(DbusVariant.of!int(7))));
	socketManager.loop();
	assert(gotValue == 7);

	bool setDone;
	setProperty!int(proxy, "Value", 9).then(() { setDone = true; }).ignoreResult();
	auto set = dbusTestSentMessage(transport, 5);
	assert(set.headers.member.text == "Set");
	assert(set.body.signature.text == "ssv");
	transport.receive(dbusTestMethodReturn(set.serial, DbusBody.from()));
	socketManager.loop();
	assert(setDone);

	DbusVariant[string] allProperties;
	getAllProperties(proxy).then((DbusVariant[string] properties) {
		allProperties = properties;
	}).ignoreResult();
	auto getAll = dbusTestSentMessage(transport, 6);
	assert(getAll.headers.member.text == "GetAll");
	assert(getAll.body.signature.text == "s");
	transport.receive(dbusTestMethodReturn(getAll.serial,
		DbusBody.from(["Value": DbusVariant.of!int(7)])));
	socketManager.loop();
	assert(allProperties["Value"].get!int == 7);

	string document;
	introspect(proxy).then((string xml) { document = xml; }).ignoreResult();
	auto introspectRequest = dbusTestSentMessage(transport, 7);
	assert(introspectRequest.headers.interfaceName.text == "org.freedesktop.DBus.Introspectable");
	assert(introspectRequest.headers.member.text == "Introspect");
	assert(introspectRequest.body.signature.text == "");
	transport.receive(dbusTestMethodReturn(introspectRequest.serial,
		DbusBody.from("<node/>")));
	socketManager.loop();
	assert(document == "<node/>");
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	Exception rejected;
	getProperty!int(proxy, "Value").then((int) { assert(false); }, (Exception exception) {
		rejected = exception;
	}).ignoreResult();
	auto get = dbusTestSentMessage(transport, 4);
	transport.receive(dbusTestMethodReturn(get.serial,
		DbusBody.from(DbusVariant.of!string("wrong type"))));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) rejected !is null);
	assert(transport.disconnectCount == 0);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	DbusVariant[string] changedProperties;
	string[] invalidatedProperties;
	int deliveries;
	subscribePropertiesChanged(proxy, (DbusVariant[string] changed, string[] invalidated) {
		changedProperties = changed;
		invalidatedProperties = invalidated;
		deliveries++;
	}).ignoreResult();

	auto addMatch = dbusTestSentMessage(transport, 4);
	assert(addMatch.headers.member.text == "AddMatch");
	assert(addMatch.body.signature.text == "s");
	auto rule = addMatch.body.values[0].get!string;
	assert(rule == "type='signal',sender=':1.99',interface='org.freedesktop.DBus.Properties'," ~
		"member='PropertiesChanged',path='/org/example/Test',arg0='org.example.Test'");
	transport.receive(dbusTestMethodReturn(addMatch.serial, DbusBody.from()));
	socketManager.loop();

	auto changedBody = DbusBody.from("org.example.Test",
		["Value": DbusVariant.of!int(11)], ["Old"]);
	transport.receive(dbusTestSignal(":1.99", proxy.__dbusPath,
		DbusInterfaceName.parse("org.freedesktop.DBus.Properties"), "PropertiesChanged", changedBody));
	assert(deliveries == 1);
	assert(changedProperties["Value"].get!int == 11);
	assert(invalidatedProperties == ["Old"]);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	int received;
	int deliveries;
	subscribe!(DbusBindingTestInterface.Changed)(proxy, (int value) {
		received = value;
		deliveries++;
	}).ignoreResult();

	auto addMatch = dbusTestSentMessage(transport, 4);
	assert(addMatch.headers.member.text == "AddMatch");
	auto rule = addMatch.body.values[0].get!string;
	assert(rule == "type='signal',sender=':1.99',interface='org.example.Test'," ~
		"member='Changed',path='/org/example/Test'");
	assert(rule.indexOf("destination=") == -1);
	transport.receive(dbusTestMethodReturn(addMatch.serial, DbusBody.from()));
	socketManager.loop();

	transport.receive(dbusTestSignal(":1.99", proxy.__dbusPath,
		proxy.__dbusInterfaceName, "Changed", DbusBody.from(5)));
	assert(deliveries == 1);
	assert(received == 5);

	transport.receive(dbusTestSignal(":1.99", proxy.__dbusPath,
		proxy.__dbusInterfaceName, "Changed", DbusBody.from("mismatched")));
	assert(deliveries == 1);
}

}
