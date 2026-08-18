/**
 * D-Bus Unix address parsing and source selection.
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

module ae.net.dbus.address;

import ae.net.dbus.common : DbusServerGuid, DbusUnsupportedException,
	DbusValidationException;

version(Posix)
import std.process : environment;
version(Posix)
import std.socket : AddressInfo, AddressFamily, ProtocolType, SocketType,
	UnixAddress;

debug(ae_unittest)
import ae.sys.data : Data;
debug(ae_unittest)
import std.conv : to;

version(Posix)
debug(ae_unittest)
import ae.net.asockets : ConnectionState, DisconnectType, SocketConnection,
	SocketServer, socketManager;
version(Posix)
debug(ae_unittest)
import ae.sys.timing : TimerTask, setTimeout;
version(Posix)
debug(ae_unittest)
import core.sys.posix.unistd : getpid;
version(Posix)
debug(ae_unittest)
import core.time : seconds;
version(Posix)
debug(ae_unittest)
import std.file : exists, remove;

private enum DbusUnixEndpointKind
{
	path,
	abstractName,
}

/**
 * One independently connectable Unix address and its optional server GUID.
 * The endpoint is decoded once and remains associated with that GUID until a
 * later connection attempt consumes this candidate.
 */
package(ae.net.dbus) struct DbusUnixAddressCandidate
{
private:
	DbusUnixEndpointKind endpointKind_;
	ubyte[] endpoint_;
	bool hasExpectedGuid_;
	DbusServerGuid expectedGuid_;

	static DbusUnixAddressCandidate create(DbusUnixEndpointKind endpointKind,
		ubyte[] endpoint, bool hasExpectedGuid, DbusServerGuid expectedGuid)
	{
		DbusUnixAddressCandidate result;
		result.endpointKind_ = endpointKind;
		result.endpoint_ = endpoint.dup;
		result.hasExpectedGuid_ = hasExpectedGuid;
		result.expectedGuid_ = expectedGuid;
		return result;
	}

	@property private DbusUnixEndpointKind endpointKind() const
	{
		return endpointKind_;
	}

	@property private const(ubyte)[] endpoint() const
	{
		return endpoint_;
	}

package:
	@property bool hasExpectedGuid() const
	{
		return hasExpectedGuid_;
	}

	@property DbusServerGuid expectedGuid() const
	{
		assert(hasExpectedGuid_);
		return expectedGuid_;
	}

	version(Posix)
	AddressInfo toAddressInfo()
	{
		switch (endpointKind_)
		{
		case DbusUnixEndpointKind.path:
		{
			auto path = cast(string) endpoint_;
			auto address = new UnixAddress(path);
			return AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
				cast(ProtocolType) 0, address, path);
		}
		case DbusUnixEndpointKind.abstractName:
			version(linux)
			{
				ubyte[] bytes = new ubyte[endpoint_.length + 1];
				bytes[0] = 0;
				bytes[1 .. $] = endpoint_[];
				auto address = new UnixAddress(cast(string) bytes);
				return AddressInfo(AddressFamily.UNIX, SocketType.STREAM,
					cast(ProtocolType) 0, address, "unix:abstract");
			}
			else
				assert(false, "abstract Unix sockets are unavailable on this platform");
		default:
			assert(false);
		}
	}
}

private bool isAddressTransportByte(ubyte value)
{
	return value >= 'a' && value <= 'z' ||
		value >= 'A' && value <= 'Z' ||
		value >= '0' && value <= '9' || value == '-' || value == '_';
}

private bool isRawAddressValueByte(ubyte value)
{
	return value >= 'a' && value <= 'z' ||
		value >= 'A' && value <= 'Z' ||
		value >= '0' && value <= '9' || value == '-' || value == '_' ||
		value == '/' || value == '.' || value == '*';
}

private ubyte decodeAddressHexDigit(ubyte value)
{
	if (value >= '0' && value <= '9')
		return cast(ubyte) (value - '0');
	if (value >= 'a' && value <= 'f')
		return cast(ubyte) (value - 'a' + 10);
	if (value >= 'A' && value <= 'F')
		return cast(ubyte) (value - 'A' + 10);
	throw new DbusValidationException("D-Bus address escapes must use hexadecimal digits");
}

private ubyte[] decodeAddressValue(string value)
{
	auto raw = cast(const(ubyte)[]) value;
	ubyte[] result;
	size_t index;
	while (index < raw.length)
	{
		auto octet = raw[index++];
		if (octet == '%')
		{
			if (index + 1 >= raw.length)
				throw new DbusValidationException("D-Bus address values contain a truncated percent escape");
			auto high = decodeAddressHexDigit(raw[index]);
			auto low = decodeAddressHexDigit(raw[index + 1]);
			result ~= cast(ubyte) ((high << 4) | low);
			index += 2;
			continue;
		}
		if (!isRawAddressValueByte(octet))
			throw new DbusValidationException("D-Bus address values contain an unescaped byte");
		result ~= octet;
	}
	return result;
}

private size_t findAddressByte(scope const(ubyte)[] value, ubyte needle,
	size_t start = 0)
{
	foreach (size_t index; start .. value.length)
		if (value[index] == needle)
			return index;
	return size_t.max;
}

private void validateAddressToken(scope const(ubyte)[] value,
	bool function(ubyte) isAllowed, string description)
{
	if (!value.length)
		throw new DbusValidationException("D-Bus address " ~ description ~ " must not be empty");
	foreach (octet; value)
		if (!isAllowed(octet))
			throw new DbusValidationException("D-Bus address " ~ description ~ " contains an invalid byte");
}

private void parseAddressElement(string element,
	ref DbusUnixAddressCandidate[] candidates)
{
	auto bytes = cast(const(ubyte)[]) element;
	if (!bytes.length)
		throw new DbusValidationException("D-Bus address lists must not contain empty elements");

	auto colon = findAddressByte(bytes, ':');
	if (colon == size_t.max)
		throw new DbusValidationException("D-Bus addresses must contain a transport separator");
	validateAddressToken(bytes[0 .. colon], &isAddressTransportByte,
		"transport name");

	auto transport = element[0 .. colon];
	auto isUnix = transport == "unix";
	DbusUnixEndpointKind endpointKind;
	ubyte[] endpoint;
	bool hasEndpoint;
	bool endpointSupported = true;
	DbusServerGuid expectedGuid;
	bool hasExpectedGuid;

	if (colon + 1 < bytes.length)
	{
		size_t pairStart = colon + 1;
		while (true)
		{
			auto comma = findAddressByte(bytes, ',', pairStart);
			auto pairEnd = comma == size_t.max ? bytes.length : comma;
			if (pairStart == pairEnd)
				throw new DbusValidationException("D-Bus addresses must not contain empty key/value pairs");

			auto equals = findAddressByte(bytes[0 .. pairEnd], '=', pairStart);
			if (equals == size_t.max)
				throw new DbusValidationException("D-Bus address key/value pairs require '='");
			validateAddressToken(bytes[pairStart .. equals], &isAddressTransportByte,
				"key");

			auto key = element[pairStart .. equals];
			auto value = decodeAddressValue(element[equals + 1 .. pairEnd]);
			if (isUnix)
			{
				switch (key)
				{
				case "path":
					if (hasEndpoint)
						throw new DbusValidationException("D-Bus Unix addresses require exactly one endpoint");
					if (!value.length)
						throw new DbusValidationException("D-Bus Unix paths must not be empty");
					foreach (octet; value)
						if (octet == 0)
							throw new DbusValidationException("D-Bus Unix paths must not contain NUL");
					hasEndpoint = true;
					endpointKind = DbusUnixEndpointKind.path;
					endpoint = value;
					version(Posix) {}
					else endpointSupported = false;
					break;

				case "abstract":
					if (hasEndpoint)
						throw new DbusValidationException("D-Bus Unix addresses require exactly one endpoint");
					if (!value.length)
						throw new DbusValidationException("D-Bus Unix abstract names must not be empty");
					hasEndpoint = true;
					endpointKind = DbusUnixEndpointKind.abstractName;
					endpoint = value;
					version(linux) {}
					else endpointSupported = false;
					break;

				case "guid":
					if (hasExpectedGuid)
						throw new DbusValidationException("D-Bus Unix addresses must not repeat guid");
					if (!value.length)
						throw new DbusValidationException("D-Bus address GUIDs must not be empty");
					expectedGuid = DbusServerGuid.parse(cast(string) value);
					hasExpectedGuid = true;
					break;

				case "dir", "tmpdir", "runtime":
					throw new DbusUnsupportedException("D-Bus server-only Unix address forms are unsupported");

				default:
					throw new DbusValidationException("D-Bus Unix addresses contain an unknown key");
				}
			}

			if (comma == size_t.max)
				break;
			pairStart = comma + 1;
		}
	}

	if (!isUnix)
		return;
	if (!hasEndpoint)
		throw new DbusValidationException("D-Bus Unix addresses require one endpoint");
	if (endpointSupported)
		candidates ~= DbusUnixAddressCandidate.create(endpointKind, endpoint,
			hasExpectedGuid, expectedGuid);
}

/**
 * Parse a complete D-Bus server-address list and retain every supported Unix
 * candidate in source order.
 */
package(ae.net.dbus) DbusUnixAddressCandidate[] parseDbusAddress(string address)
{
	auto bytes = cast(const(ubyte)[]) address;
	DbusUnixAddressCandidate[] candidates;
	size_t elementStart;
	foreach (size_t index, octet; bytes)
	{
		if (octet > 0x7f)
			throw new DbusValidationException("D-Bus addresses must be ASCII");
		if (octet == ';')
		{
			parseAddressElement(address[elementStart .. index], candidates);
			elementStart = index + 1;
		}
	}
	parseAddressElement(address[elementStart .. $], candidates);
	if (!candidates.length)
		throw new DbusUnsupportedException("the D-Bus address list has no supported Unix candidate");
	return candidates;
}

version(Posix)
package(ae.net.dbus) DbusUnixAddressCandidate[] selectSessionBusAddresses()
{
	auto address = environment.get("DBUS_SESSION_BUS_ADDRESS");
	if (address is null || !address.length)
		throw new DbusUnsupportedException("DBUS_SESSION_BUS_ADDRESS is not set");
	return parseDbusAddress(address);
}

version(Posix)
package(ae.net.dbus) DbusUnixAddressCandidate[] selectSystemBusAddresses()
{
	auto address = environment.get("DBUS_SYSTEM_BUS_ADDRESS");
	if (address is null)
		address = "unix:path=/var/run/dbus/system_bus_socket";
	return parseDbusAddress(address);
}

debug(ae_unittest)
private enum dbusAddressTestGuidOne = "0123456789abcdef0123456789abcdef";

debug(ae_unittest)
private enum dbusAddressTestGuidTwo = "fedcba98765432100123456789abcdef";

debug(ae_unittest)
private void expectDbusAddressValidation(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusValidationException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private void expectDbusAddressUnsupported(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusUnsupportedException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private void assertDbusAddressCandidate(const ref DbusUnixAddressCandidate candidate,
	DbusUnixEndpointKind endpointKind, scope const(ubyte)[] endpoint,
	string expectedGuid = null)
{
	assert(candidate.endpointKind == endpointKind);
	assert(candidate.endpoint == endpoint);
	assert(candidate.hasExpectedGuid == (expectedGuid !is null));
	if (expectedGuid !is null)
		assert(candidate.expectedGuid.text == expectedGuid);
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		auto candidates = parseDbusAddress("unix:path=/tmp/Az09-_.raw*");
		assert(candidates.length == 1);
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/Az09-_.raw*");
	}
	else
		expectDbusAddressUnsupported({
			parseDbusAddress("unix:path=/tmp/Az09-_.raw*");
		});
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		auto candidates = parseDbusAddress("unix:path=/tmp/a%2cb%3bc%3dd%20e%25");
		assert(candidates.length == 1);
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/a,b;c=d e%");

		candidates = parseDbusAddress("unix:path=/tmp/%41%4A%2C%3B%3D");
		assert(candidates.length == 1);
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/AJ,;=");

		candidates = parseDbusAddress("unix:path=/tmp/%4a");
		assert(candidates.length == 1);
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/J");
	}
	else
		foreach (address; [
			"unix:path=/tmp/a%2cb%3bc%3dd%20e%25",
			"unix:path=/tmp/%41%4A%2C%3B%3D",
			"unix:path=/tmp/%4a",
		])
			expectDbusAddressUnsupported({ parseDbusAddress(address); });
}

debug(ae_unittest) unittest
{
	foreach (address; [
		"unix:path=/tmp/%",
		"unix:path=/tmp/%0",
		"unix:path=/tmp/%0g",
		"unix:path=/tmp/%g0",
		"unix:path=/tmp/a=b",
		"unix:path=/tmp/a b",
		"unix:path=/tmp/a@b",
		"unix:path=/tmp/a,b",
		"unix:path=/tmp/a;b",
	])
		expectDbusAddressValidation({ parseDbusAddress(address); });
}

debug(ae_unittest) unittest
{
	foreach (address; [
		"",
		";unix:path=/tmp/a",
		"unix:path=/tmp/a;",
		"unix:path=/tmp/a;;unix:path=/tmp/b",
		"unix",
		"unix:path",
		"unix:=/tmp/a",
		"unix:path=/tmp/a,broken",
	])
		expectDbusAddressValidation({ parseDbusAddress(address); });
}

debug(ae_unittest) unittest
{
	foreach (address; [
		"unix:path=/tmp/a,path=/tmp/b",
		"unix:path=/tmp/a,abstract=other",
		"unix:path=/tmp/a,guid=" ~ dbusAddressTestGuidOne ~
			",guid=" ~ dbusAddressTestGuidTwo,
		"unix:path=/tmp/a,unknown=value",
		"unix:guid=" ~ dbusAddressTestGuidOne,
		"unix:path=",
		"unix:abstract=",
		"unix:path=/tmp/a,guid=",
		"unix:path=/tmp/a,guid=0123456789abcdef0123456789abcde",
		"unix:path=/tmp/a,guid=0123456789abcdef0123456789abcdef0",
		"unix:path=/tmp/a,guid=0123456789abcdef0123456789abcdeg",
		"unix:path=/tmp/a%00b",
	])
		expectDbusAddressValidation({ parseDbusAddress(address); });

	foreach (address; [
		"unix:dir=/tmp",
		"unix:tmpdir=/tmp",
		"unix:runtime=/tmp",
	])
		expectDbusAddressUnsupported({ parseDbusAddress(address); });
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		auto candidates = parseDbusAddress(
			"unix:path=/tmp/first;tcp:host=localhost,port=1234;" ~
			"nonce-tcp:host=example,port=42;unix:path=/tmp/second");
		assert(candidates.length == 2);
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/first");
		assertDbusAddressCandidate(candidates[1], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/second");
	}
	else
		expectDbusAddressUnsupported({
			parseDbusAddress(
				"unix:path=/tmp/first;tcp:host=localhost,port=1234;" ~
				"nonce-tcp:host=example,port=42;unix:path=/tmp/second");
		});

	expectDbusAddressUnsupported({
		parseDbusAddress("tcp:host=localhost,port=1234");
	});
	expectDbusAddressUnsupported({
		parseDbusAddress("autolaunch:scope=*");
	});
	expectDbusAddressValidation({
		parseDbusAddress("tcp:host=%");
	});
	expectDbusAddressValidation({
		parseDbusAddress("tcp:host=localhost,port");
	});
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		auto candidates = parseDbusAddress(
			"unix:path=/tmp/one,guid=0123456789ABCDEF0123456789ABCDEF;" ~
			"unix:path=/tmp/two;unix:guid=" ~ dbusAddressTestGuidTwo ~
			",path=/tmp/three");
		assert(candidates.length == 3);
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/one", dbusAddressTestGuidOne);
		assertDbusAddressCandidate(candidates[1], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/two");
		assertDbusAddressCandidate(candidates[2], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/three", dbusAddressTestGuidTwo);
	}
	else
		expectDbusAddressUnsupported({
			parseDbusAddress(
				"unix:path=/tmp/one,guid=0123456789ABCDEF0123456789ABCDEF;" ~
				"unix:path=/tmp/two;unix:guid=" ~ dbusAddressTestGuidTwo ~
				",path=/tmp/three");
		});
}

debug(ae_unittest) unittest
{
	version(linux)
	{
		auto candidates = parseDbusAddress(
			"unix:abstract=ae%00dbus%ff%2cendpoint,guid=" ~ dbusAddressTestGuidOne);
		assert(candidates.length == 1);
		ubyte[] expected = [
			cast(ubyte) 'a', 'e', cast(ubyte) 0, 'd', 'b', 'u', 's', 0xff,
			',', 'e', 'n', 'd', 'p', 'o', 'i', 'n', 't',
		];
		assertDbusAddressCandidate(candidates[0], DbusUnixEndpointKind.abstractName,
			expected, dbusAddressTestGuidOne);
	}
}

version(Posix)
debug(ae_unittest)
private size_t dbusAddressTestSocketSerial;

version(Posix)
debug(ae_unittest)
private string dbusAddressTestSocketPath()
{
	return "/tmp/ae-dbus-address-" ~ to!string(getpid()) ~ "-" ~
		to!string(dbusAddressTestSocketSerial++);
}

version(Posix)
debug(ae_unittest)
private void removeDbusAddressTestSocketPath(string path)
{
	if (exists(path))
		remove(path);
}

version(Posix)
debug(ae_unittest)
private void disconnectDbusAddressTestConnection(SocketConnection connection)
{
	if (connection !is null && connection.state >= ConnectionState.resolving &&
		connection.state <= ConnectionState.connected)
		connection.disconnect("D-Bus address unittest cleanup");
}

version(Posix)
debug(ae_unittest)
private void testDbusUnixByteExchange(DbusUnixAddressCandidate candidate)
{
	immutable ubyte[] request = [0, cast(ubyte) 'r', 0xff, 'q'];
	immutable ubyte[] response = [cast(ubyte) 'o', 0, 0xfe, 'k'];
	auto server = new SocketServer;
	auto client = new SocketConnection;
	SocketConnection accepted;
	ubyte[] serverReceived;
	ubyte[] clientReceived;
	bool clientConnected;
	bool exchangeComplete;
	bool clientDisconnected;
	bool acceptedDisconnected;
	bool timedOut;
	TimerTask timeout;

	void cleanup()
	{
		if (timeout.isWaiting())
			timeout.cancel();
		disconnectDbusAddressTestConnection(client);
		disconnectDbusAddressTestConnection(accepted);
		if (server.isListening)
			server.close();
	}

	scope(exit) cleanup();

	server.handleAccept = (SocketConnection incoming) {
		assert(accepted is null);
		accepted = incoming;
		incoming.handleReadData = (Data data) {
			serverReceived ~= data.toGC;
			assert(serverReceived.length <= request.length);
			if (serverReceived.length == request.length)
			{
				assert(serverReceived == request);
				incoming.send(Data(response.dup));
			}
		};
		incoming.handleDisconnect = (string, DisconnectType) {
			acceptedDisconnected = true;
		};
	};
	server.listen([candidate.toAddressInfo()]);

	client.handleConnect = {
		clientConnected = true;
		client.send(Data(request.dup));
	};
	client.handleReadData = (Data data) {
		clientReceived ~= data.toGC;
		assert(clientReceived.length <= response.length);
		if (clientReceived.length == response.length)
		{
			assert(clientReceived == response);
			exchangeComplete = true;
			timeout.cancel();
			client.disconnect();
			server.close();
		}
	};
	client.handleDisconnect = (string, DisconnectType) {
		clientDisconnected = true;
	};

	timeout = setTimeout({
		timedOut = true;
		cleanup();
	}, 5.seconds);
	client.connect([candidate.toAddressInfo()]);
	socketManager.loop();

	assert(!timedOut, "D-Bus Unix socket byte exchange timed out");
	assert(clientConnected);
	assert(exchangeComplete);
	assert(clientDisconnected);
	assert(acceptedDisconnected);
}

version(Posix)
debug(ae_unittest)
private void testDbusUnixRefusal(DbusUnixAddressCandidate candidate)
{
	auto client = new SocketConnection;
	bool disconnected;
	DisconnectType disconnectType;
	bool timedOut;
	TimerTask timeout;

	void cleanup()
	{
		if (timeout.isWaiting())
			timeout.cancel();
		disconnectDbusAddressTestConnection(client);
	}

	scope(exit) cleanup();
	client.handleDisconnect = (string, DisconnectType type) {
		disconnected = true;
		disconnectType = type;
		timeout.cancel();
	};
	timeout = setTimeout({
		timedOut = true;
		cleanup();
	}, 5.seconds);
	client.connect([candidate.toAddressInfo()]);
	socketManager.loop();

	assert(!timedOut, "D-Bus Unix socket refusal timed out");
	assert(disconnected);
	assert(disconnectType == DisconnectType.error);
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		auto path = dbusAddressTestSocketPath();
		removeDbusAddressTestSocketPath(path);
		scope(exit) removeDbusAddressTestSocketPath(path);

		auto candidate = parseDbusAddress("unix:path=" ~ path)[0];
		testDbusUnixByteExchange(candidate);
		assert(exists(path));
		removeDbusAddressTestSocketPath(path);
		assert(!exists(path));

		testDbusUnixRefusal(parseDbusAddress("unix:path=" ~ path)[0]);
	}
}

debug(ae_unittest) unittest
{
	version(linux)
	{
		auto name = "ae-dbus-address-" ~ to!string(getpid()) ~ "-" ~
			to!string(dbusAddressTestSocketSerial++);
		auto candidate = parseDbusAddress("unix:abstract=" ~ name ~ "%00%ffbyte")[0];
		testDbusUnixByteExchange(candidate);
		testDbusUnixRefusal(candidate);
	}
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		auto originalSession = environment.get("DBUS_SESSION_BUS_ADDRESS");
		auto originalSystem = environment.get("DBUS_SYSTEM_BUS_ADDRESS");
		scope(exit)
		{
			if (originalSession is null)
				environment.remove("DBUS_SESSION_BUS_ADDRESS");
			else
				environment["DBUS_SESSION_BUS_ADDRESS"] = originalSession;
			if (originalSystem is null)
				environment.remove("DBUS_SYSTEM_BUS_ADDRESS");
			else
				environment["DBUS_SYSTEM_BUS_ADDRESS"] = originalSystem;
		}

		environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/tmp/session-only";
		environment["DBUS_SYSTEM_BUS_ADDRESS"] = "unix:path=/tmp/system-only";
		auto session = selectSessionBusAddresses();
		auto system = selectSystemBusAddresses();
		assertDbusAddressCandidate(session[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/session-only");
		assertDbusAddressCandidate(system[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/tmp/system-only");

		environment.remove("DBUS_SESSION_BUS_ADDRESS");
		expectDbusAddressUnsupported({ selectSessionBusAddresses(); });
		environment["DBUS_SESSION_BUS_ADDRESS"] = "";
		expectDbusAddressUnsupported({ selectSessionBusAddresses(); });
		environment["DBUS_SESSION_BUS_ADDRESS"] = "autolaunch:";
		expectDbusAddressUnsupported({ selectSessionBusAddresses(); });

		environment["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/tmp/not-system";
		environment.remove("DBUS_SYSTEM_BUS_ADDRESS");
		system = selectSystemBusAddresses();
		assertDbusAddressCandidate(system[0], DbusUnixEndpointKind.path,
			cast(const(ubyte)[]) "/var/run/dbus/system_bus_socket");
		environment["DBUS_SYSTEM_BUS_ADDRESS"] = "";
		expectDbusAddressValidation({ selectSystemBusAddresses(); });
	}
}
