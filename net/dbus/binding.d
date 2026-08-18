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
import std.traits : BaseTypeTuple, FunctionAttribute, ParameterDefaults,
	ParameterStorageClass, ParameterStorageClassTuple, ParameterTypeTuple,
	ReturnType, Unqual, Variadic, functionAttributes, variadicFunctionStyle;
import std.typecons : Tuple;

import ae.net.dbus.client : DbusConnection, DbusMethodCall, DbusSubscription;
import ae.net.dbus.common;
import ae.net.dbus.match : DbusSignalMatch;
import ae.net.dbus.signature : DbusOut, dbusSignature;
import ae.net.dbus.value : DbusBody, DbusValue, DbusVariant;
import ae.utils.meta : getAttribute, hasAttribute;
import ae.utils.promise : Promise, PromiseError, PromiseValue, isPromise;

/// Names the D-Bus interface implemented by a `DbusProxy!I`.
struct DbusInterface
{
	string name;
}

/// Overrides the D-Bus member name of a method, when it must differ from
/// the D method name (for example, to disambiguate D overloads).
struct DbusMember
{
	string name;
}

/// Describes a D-Bus signal as metadata on an interface, rather than as a
/// callable method.
struct DbusSignal(string memberName, Args...)
{
	enum name = memberName;
	alias Types = Args;
}

private template dbusAttributeCount(T, alias D)
{
	enum dbusAttributeCount = () {
		size_t count;
		static foreach (attribute; __traits(getAttributes, D))
			static if (is(typeof(attribute) == T))
				count++;
		return count;
	}();
}

private template dbusInterfaceName(I)
{
	enum dbusInterfaceName = () {
		static assert(hasAttribute!(DbusInterface, I),
			"D-Bus interfaces must be annotated with @DbusInterface");
		static assert(dbusAttributeCount!(DbusInterface, I) == 1,
			"D-Bus interfaces must have exactly one @DbusInterface annotation");
		return getAttribute!(DbusInterface, I).name;
	}();
}

private template dbusMemberName(alias Method)
{
	static if (hasAttribute!(DbusMember, Method))
		enum dbusMemberName = getAttribute!(DbusMember, Method).name;
	else
		enum dbusMemberName = __traits(identifier, Method);
}

private template dbusResultIsOut(T)
{
	static if (is(T == DbusOut!Types, Types...))
		enum dbusResultIsOut = true;
	else
		enum dbusResultIsOut = false;
}

private template dbusValuesSignature(Types...)
{
	enum dbusValuesSignature = () {
		string result;
		static foreach (Type; Types)
			result ~= dbusSignature!Type;
		return result;
	}();
}

private template dbusWireNamesAreUnique(I)
{
	enum dbusWireNamesAreUnique = () {
		string[] names;
		foreach (memberName; __traits(allMembers, I))
			static if (__traits(getOverloads, I, memberName).length)
				foreach (overload; __traits(getOverloads, I, memberName))
					names ~= dbusMemberName!overload;
		foreach (i; 0 .. names.length)
			foreach (j; i + 1 .. names.length)
				if (names[i] == names[j])
					return false;
		return true;
	}();
}

private template dbusOverloadWireNamesAreExplicit(I)
{
	enum dbusOverloadWireNamesAreExplicit = () {
		foreach (memberName; __traits(allMembers, I))
			static if (__traits(getOverloads, I, memberName).length > 1)
				foreach (overload; __traits(getOverloads, I, memberName))
					if (!hasAttribute!(DbusMember, overload))
						return false;
		return true;
	}();
}

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
if (dbusResultIsOut!T)
{
	alias Types = T.Types;
	enum expected = dbusValuesSignature!Types;
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

private string generateDbusProxyMethod(I, size_t memberIndex, size_t overloadIndex,
	string memberName)()
{
	alias Method = __traits(getOverloads, I, memberName)[overloadIndex];
	alias Params = ParameterTypeTuple!Method;
	alias Return = ReturnType!Method;

	static assert(__traits(isVirtualMethod, Method),
		"D-Bus interface method " ~ memberName ~
		" must not be final or static; the MVP binding does not support non-virtual interface methods");

	static if (isPromise!Return)
	{
		static assert(is(PromiseError!Return == Exception),
			"D-Bus interface method " ~ memberName ~
			" must return a Promise with the default Exception error type");

		alias ResultType = PromiseValue!Return;
		static if (!is(ResultType == void))
		{
			static if (dbusResultIsOut!ResultType)
				enum _ = dbusValuesSignature!(ResultType.Types);
			else
				enum _ = dbusSignature!ResultType;
		}
	}
	else
		static assert(false,
			"D-Bus interface method " ~ memberName ~ " must return a Promise!T");

	static foreach (Param; Params)
		static assert(is(Unqual!Param == Param),
			"D-Bus interface method " ~ memberName ~
			" must not use qualified (const/immutable/inout/shared) parameter types");
	static foreach (Param; Params)
		static assert(__traits(compiles, dbusSignature!Param),
			"D-Bus interface method " ~ memberName ~
			" has a parameter type with no D-Bus signature");

	static assert(functionAttributes!Method == FunctionAttribute.system,
		"D-Bus interface method " ~ memberName ~
		" must not use qualifiers or non-default function attributes");
	static assert(variadicFunctionStyle!Method == Variadic.no,
		"D-Bus interface method " ~ memberName ~ " must not be variadic");
	static foreach (storage; ParameterStorageClassTuple!Method)
		static assert(storage == ParameterStorageClass.none,
			"D-Bus interface method " ~ memberName ~
			" must not use explicit parameter storage classes");
	static foreach (default_; ParameterDefaults!Method)
		static assert(is(default_ == void),
			"D-Bus interface method " ~ memberName ~ " must not use parameter default values");

	// Every generated type position below names a local alias, never a
	// consumer-owned type's `.stringof` spelling, so that this mixin
	// compiles regardless of the visibility of I's own dependencies.
	enum suffix = memberIndex.to!string ~ "_" ~ overloadIndex.to!string;
	string code;

	code ~= "alias __dbusMethod_" ~ suffix ~
		" = __traits(getOverloads, I, \"" ~ memberName ~ "\")[" ~
		overloadIndex.to!string ~ "];\n";
	code ~= "alias __dbusParams_" ~ suffix ~
		" = ParameterTypeTuple!__dbusMethod_" ~ suffix ~ ";\n";
	code ~= "alias __dbusReturn_" ~ suffix ~
		" = ReturnType!__dbusMethod_" ~ suffix ~ ";\n";
	code ~= "override __dbusReturn_" ~ suffix ~ " " ~ memberName ~ "(";

	static foreach (parameterIndex; 0 .. Params.length)
	{
		static if (parameterIndex > 0)
			code ~= ", ";
		code ~= "__dbusParams_" ~ suffix ~ "[" ~ parameterIndex.to!string ~
			"] __dbusArg_" ~ suffix ~ "_" ~ parameterIndex.to!string;
	}

	code ~= ")\n{\n\treturn invoke!__dbusMethod_" ~ suffix ~ "(";
	static foreach (parameterIndex; 0 .. Params.length)
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
	static assert(BaseTypeTuple!I.length == 0,
		"D-Bus interfaces must not inherit from other interfaces");
	static assert(dbusWireNamesAreUnique!I,
		"D-Bus interface methods must have unique wire names; use @DbusMember to disambiguate overloads");
	static assert(dbusOverloadWireNamesAreExplicit!I,
		"D-Bus interface methods with more than one overload must have an explicit, distinct @DbusMember wire name on every overload");

	private DbusConnection __dbusConnection;
	private DbusBusName __dbusDestination;
	private DbusObjectPath __dbusPath;
	private enum __dbusInterfaceName = DbusInterfaceName.parse(dbusInterfaceName!I);

	private this(DbusConnection connection, DbusBusName destination, DbusObjectPath path)
	{
		__dbusConnection = connection;
		__dbusDestination = destination;
		__dbusPath = path;
	}

	// `MemberFunctionsTuple` is keyed by a member name, so an `allMembers`
	// walk is required regardless; `__traits(getOverloads, I, name)` is the
	// overload-enumeration form the typed-proxy spike proved.
	static foreach (memberIndex, memberName; __traits(allMembers, I))
	{
		static if (__traits(getOverloads, I, memberName).length)
		{
			static foreach (overloadIndex, overload; __traits(getOverloads, I, memberName))
				mixin(generateDbusProxyMethod!(I, memberIndex, overloadIndex, memberName));
		}
		else static if (__traits(compiles, __traits(isTemplate, __traits(getMember, I, memberName))) &&
			__traits(isTemplate, __traits(getMember, I, memberName)))
			static assert(false,
				"D-Bus interface methods must not be templated: " ~ memberName);
	}

	private ReturnType!Method invoke(alias Method, Args...)(Args args)
	{
		alias ResultType = PromiseValue!(ReturnType!Method);
		enum memberName = DbusMemberName.parse(dbusMemberName!Method);

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
		else static if (dbusResultIsOut!ResultType)
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

	enum expectedSignature = dbusValuesSignature!(Signal.Types);
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
import ae.net.asockets : ConnectionState, DisconnectType, IConnection, socketManager;
debug(ae_unittest)
import ae.net.dbus.client : attachDbusConnection;
debug(ae_unittest)
import ae.net.dbus.marshal : decodeDbusMessage, encodeDbusMessage;
debug(ae_unittest)
import ae.sys.data : Data;
debug(ae_unittest)
import ae.utils.array : asBytes;
debug(ae_unittest)
import core.sys.posix.unistd : getuid;
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

debug(ae_unittest)
private enum dbusBindingTestServerGuid = "0123456789abcdef0123456789abcdef";

debug(ae_unittest)
private final class DbusBindingTestConnection : IConnection
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

debug(ae_unittest)
private string dbusBindingTestExternalIdentity()
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

debug(ae_unittest)
private Data dbusBindingTestMethodReturn(uint replySerial, DbusBody body)
{
	DbusMessage message;
	message.messageType = DbusMessageType.methodReturn;
	message.serial = 900;
	message.headers.replySerial = replySerial;
	message.body = body;
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private Data dbusBindingTestError(uint replySerial, string errorName, string errorMessage)
{
	DbusMessage message;
	message.messageType = DbusMessageType.error;
	message.serial = 901;
	message.headers.errorName = DbusErrorName.parse(errorName);
	message.headers.replySerial = replySerial;
	message.body = DbusBody.from(errorMessage);
	return encodeDbusMessage(message);
}

debug(ae_unittest)
private Data dbusBindingTestSignal(string sender, DbusObjectPath path,
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

debug(ae_unittest)
private DbusMessage dbusBindingTestSentMessage(DbusBindingTestConnection transport, size_t index)
{
	return decodeDbusMessage(transport.sent[index].toGC);
}

debug(ae_unittest)
private void dbusBindingTestAuthenticate(DbusBindingTestConnection transport,
	string uniqueName = ":1.42")
{
	assert(transport.sent.length == 2);
	assert(transport.sent[0].toGC == [cast(ubyte) 0]);
	assert(transport.sent[1].toGC == ("AUTH EXTERNAL " ~
		dbusBindingTestExternalIdentity() ~ "\r\n").asBytes);

	transport.receive(Data(("OK " ~ dbusBindingTestServerGuid ~ "\r\n").asBytes));
	assert(transport.sent.length == 4);
	assert(transport.sent[2].toGC == "BEGIN\r\n".asBytes);

	auto hello = decodeDbusMessage(transport.sent[3].toGC);
	assert(hello.headers.member.text == "Hello");
	transport.receive(dbusBindingTestMethodReturn(hello.serial, DbusBody.from(uniqueName)));
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	int fulfilled;
	proxy.DoSomething(42).then(() { fulfilled++; }).ignoreResult();

	assert(transport.sent.length == 5);
	auto request = dbusBindingTestSentMessage(transport, 4);
	assert(request.messageType == DbusMessageType.methodCall);
	assert(request.headers.destination.text == ":1.99");
	assert(request.headers.path.text == "/org/example/Test");
	assert(request.headers.interfaceName.text == "org.example.Test");
	assert(request.headers.member.text == "DoSomething");
	assert(request.body.signature.text == "i");
	assert(request.body.values[0].get!int == 42);

	transport.receive(dbusBindingTestMethodReturn(request.serial, DbusBody.from()));
	socketManager.loop();
	assert(fulfilled == 1);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	DbusOut!(int, string) decoded;
	proxy.GetPair().then((DbusOut!(int, string) result) { decoded = result; }).ignoreResult();
	auto request = dbusBindingTestSentMessage(transport, 4);
	assert(request.headers.member.text == "GetPair");
	transport.receive(dbusBindingTestMethodReturn(request.serial, DbusBody.from(7, "seven")));
	socketManager.loop();
	assert(decoded.values[0] == 7);
	assert(decoded.values[1] == "seven");
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	Exception rejected;
	proxy.GetValue().then((int) { assert(false); }, (Exception exception) {
		rejected = exception;
	}).ignoreResult();

	auto first = dbusBindingTestSentMessage(transport, 4);
	transport.receive(dbusBindingTestMethodReturn(first.serial, DbusBody.from("wrong")));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) rejected !is null);
	assert(transport.disconnectCount == 0);

	int fulfilled;
	proxy.GetValue().then((int value) { fulfilled = value; }).ignoreResult();
	auto second = dbusBindingTestSentMessage(transport, 5);
	transport.receive(dbusBindingTestMethodReturn(second.serial, DbusBody.from(7)));
	socketManager.loop();
	assert(fulfilled == 7);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	Exception rejected;
	proxy.GetValue().then((int) { assert(false); }, (Exception exception) {
		rejected = exception;
	}).ignoreResult();
	auto request = dbusBindingTestSentMessage(transport, 4);
	transport.receive(dbusBindingTestError(request.serial, "org.example.Error", "failed"));
	socketManager.loop();
	auto remote = cast(DbusRemoteError) rejected;
	assert(remote !is null);
	assert(remote.errorName.text == "org.example.Error");

	Exception propertyRejected;
	getProperty!int(proxy, "Value").then((int) { assert(false); }, (Exception exception) {
		propertyRejected = exception;
	}).ignoreResult();
	auto propertyRequest = dbusBindingTestSentMessage(transport, 5);
	transport.receive(dbusBindingTestError(propertyRequest.serial, "org.example.Error", "failed"));
	socketManager.loop();
	assert(cast(DbusRemoteError) propertyRejected !is null);

	Exception introspectRejected;
	introspect(proxy).then((string) { assert(false); }, (Exception exception) {
		introspectRejected = exception;
	}).ignoreResult();
	auto introspectRequest = dbusBindingTestSentMessage(transport, 6);
	transport.receive(dbusBindingTestError(introspectRequest.serial, "org.example.Error", "failed"));
	socketManager.loop();
	assert(cast(DbusRemoteError) introspectRejected !is null);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	int gotValue;
	getProperty!int(proxy, "Value").then((int value) { gotValue = value; }).ignoreResult();
	auto get = dbusBindingTestSentMessage(transport, 4);
	assert(get.headers.interfaceName.text == "org.freedesktop.DBus.Properties");
	assert(get.headers.member.text == "Get");
	assert(get.body.signature.text == "ss");
	assert(get.body.values[0].get!string == "org.example.Test");
	assert(get.body.values[1].get!string == "Value");
	transport.receive(dbusBindingTestMethodReturn(get.serial,
		DbusBody.from(DbusVariant.of!int(7))));
	socketManager.loop();
	assert(gotValue == 7);

	bool setDone;
	setProperty!int(proxy, "Value", 9).then(() { setDone = true; }).ignoreResult();
	auto set = dbusBindingTestSentMessage(transport, 5);
	assert(set.headers.member.text == "Set");
	assert(set.body.signature.text == "ssv");
	transport.receive(dbusBindingTestMethodReturn(set.serial, DbusBody.from()));
	socketManager.loop();
	assert(setDone);

	DbusVariant[string] allProperties;
	getAllProperties(proxy).then((DbusVariant[string] properties) {
		allProperties = properties;
	}).ignoreResult();
	auto getAll = dbusBindingTestSentMessage(transport, 6);
	assert(getAll.headers.member.text == "GetAll");
	assert(getAll.body.signature.text == "s");
	transport.receive(dbusBindingTestMethodReturn(getAll.serial,
		DbusBody.from(["Value": DbusVariant.of!int(7)])));
	socketManager.loop();
	assert(allProperties["Value"].get!int == 7);

	string document;
	introspect(proxy).then((string xml) { document = xml; }).ignoreResult();
	auto introspectRequest = dbusBindingTestSentMessage(transport, 7);
	assert(introspectRequest.headers.interfaceName.text == "org.freedesktop.DBus.Introspectable");
	assert(introspectRequest.headers.member.text == "Introspect");
	assert(introspectRequest.body.signature.text == "");
	transport.receive(dbusBindingTestMethodReturn(introspectRequest.serial,
		DbusBody.from("<node/>")));
	socketManager.loop();
	assert(document == "<node/>");
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	Exception rejected;
	getProperty!int(proxy, "Value").then((int) { assert(false); }, (Exception exception) {
		rejected = exception;
	}).ignoreResult();
	auto get = dbusBindingTestSentMessage(transport, 4);
	transport.receive(dbusBindingTestMethodReturn(get.serial,
		DbusBody.from(DbusVariant.of!string("wrong type"))));
	socketManager.loop();
	assert(cast(DbusTypeMismatchException) rejected !is null);
	assert(transport.disconnectCount == 0);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

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

	auto addMatch = dbusBindingTestSentMessage(transport, 4);
	assert(addMatch.headers.member.text == "AddMatch");
	assert(addMatch.body.signature.text == "s");
	auto rule = addMatch.body.values[0].get!string;
	assert(rule == "type='signal',sender=':1.99',interface='org.freedesktop.DBus.Properties'," ~
		"member='PropertiesChanged',path='/org/example/Test',arg0='org.example.Test'");
	transport.receive(dbusBindingTestMethodReturn(addMatch.serial, DbusBody.from()));
	socketManager.loop();

	auto changedBody = DbusBody.from("org.example.Test",
		["Value": DbusVariant.of!int(11)], ["Old"]);
	transport.receive(dbusBindingTestSignal(":1.99", proxy.__dbusPath,
		DbusInterfaceName.parse("org.freedesktop.DBus.Properties"), "PropertiesChanged", changedBody));
	assert(deliveries == 1);
	assert(changedProperties["Value"].get!int == 11);
	assert(invalidatedProperties == ["Old"]);
}

debug(ae_unittest) unittest
{
	auto transport = new DbusBindingTestConnection;
	auto connection = attachDbusConnection(transport);
	connection.ready.ignoreResult();
	dbusBindingTestAuthenticate(transport);

	auto proxy = dbusProxy!DbusBindingTestInterface(connection,
		DbusBusName.parse(":1.99"), DbusObjectPath.parse("/org/example/Test"));

	int received;
	int deliveries;
	subscribe!(DbusBindingTestInterface.Changed)(proxy, (int value) {
		received = value;
		deliveries++;
	}).ignoreResult();

	auto addMatch = dbusBindingTestSentMessage(transport, 4);
	assert(addMatch.headers.member.text == "AddMatch");
	auto rule = addMatch.body.values[0].get!string;
	assert(rule == "type='signal',sender=':1.99',interface='org.example.Test'," ~
		"member='Changed',path='/org/example/Test'");
	assert(rule.indexOf("destination=") == -1);
	transport.receive(dbusBindingTestMethodReturn(addMatch.serial, DbusBody.from()));
	socketManager.loop();

	transport.receive(dbusBindingTestSignal(":1.99", proxy.__dbusPath,
		proxy.__dbusInterfaceName, "Changed", DbusBody.from(5)));
	assert(deliveries == 1);
	assert(received == 5);

	transport.receive(dbusBindingTestSignal(":1.99", proxy.__dbusPath,
		proxy.__dbusInterfaceName, "Changed", DbusBody.from("mismatched")));
	assert(deliveries == 1);
}

}
