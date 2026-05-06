/**
 * Transport-agnostic identification of a connection endpoint.
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

module ae.net.endpoint;

import std.algorithm.searching : canFind;
import std.conv : text;
import std.socket : Address, AddressFamily;

/// Identifies one side of an `IConnection` — either the bind point of an
/// acceptor or the peer of an established connection. Subclasses correspond
/// to transport families.
///
/// `toString` returns a transport-native, scheme-less form
/// (e.g. `"127.0.0.1:8080"`, `"[::1]:80"`, `\\.\pipe\foo`); callers that
/// want a URL prepend their own scheme (e.g. `"http://" ~ ep.toString()`).
abstract class Endpoint
{
}

/// Endpoint reachable via a `std.socket.Address`.
class SocketEndpoint : Endpoint
{
	Address address; ///
	this(Address address) { this.address = address; } ///

	override string toString() const
	{
		auto addr = address.toAddrString();
		if (address.addressFamily == AddressFamily.UNIX)
			return addr;
		auto port = address.toPortString();
		string host =
			(addr == "0.0.0.0" || addr == "::") ? "*" :
			addr.canFind(":") ? "[" ~ addr ~ "]" :
			addr;
		return host ~ ":" ~ port;
	}
}

/// Endpoint identified by a Windows named-pipe path (e.g. `\\.\pipe\foo`).
version (Windows)
class NamedPipeEndpoint : Endpoint
{
	string pipeName; ///
	this(string pipeName) { this.pipeName = pipeName; } ///

	override string toString() const
	{
		return pipeName;
	}
}

// Sketch — kept disabled until there's an actual caller (e.g. a future
// Connector.connect(Endpoint) refactor needs to carry an unresolved
// hostname+port pair). Re-enable and add tests when introducing it.
version (none)
class HostnameEndpoint : Endpoint
{
	string host;
	ushort port;
	this(string host, ushort port) { this.host = host; this.port = port; }

	override string toString() const
	{
		string h = host.canFind(":") ? "[" ~ host ~ "]" : host;
		return h ~ (port ? ":" ~ text(port) : "");
	}
}

debug (ae_unittest) unittest
{
	import std.socket : InternetAddress, Internet6Address;

	auto e = new SocketEndpoint(new InternetAddress("127.0.0.1", 8080));
	assert(e.toString() == "127.0.0.1:8080");

	auto e0 = new SocketEndpoint(new InternetAddress("0.0.0.0", 80));
	assert(e0.toString() == "*:80");

	auto e6 = new SocketEndpoint(new Internet6Address("::1", 80));
	assert(e6.toString() == "[::1]:80");

	version (Windows)
	{
		auto p = new NamedPipeEndpoint(`\\.\pipe\foo`);
		assert(p.toString() == `\\.\pipe\foo`);
	}
}
