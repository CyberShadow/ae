/**
 * SOCKS5 protocol implementation (RFC 1928).
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

module ae.net.socks.socks5;

import std.conv : to;
import std.exception : enforce;
import std.socket : Socket, AddressFamily, InternetAddress, Internet6Address, AddressInfo, sockaddr_in, sockaddr_in6;
import std.string : representation;

import ae.net.asockets : ConnectionAdapter, IConnection, DisconnectType, ConnectionState, TcpConnection;
import ae.sys.data : Data;
import ae.utils.array : as, asBytes;
import ae.utils.bitmanip : NetworkByteOrder;

debug(SOCKS5) import std.stdio : stderr;

/// SOCKS5 client connection adapter.
/// Connects to a SOCKS5 proxy server and tunnels traffic through it.
/// This is a client-side implementation only; it cannot be used to implement a SOCKS5 server.
class SOCKS5ClientAdapter : ConnectionAdapter
{
	/// SOCKS5 protocol version
	private enum ubyte SOCKS_VERSION = 5;

	/// Authentication methods
	enum AuthMethod : ubyte
	{
		noAuth = 0x00,           /// No authentication required
		gssapi = 0x01,           /// GSSAPI
		usernamePassword = 0x02, /// Username/password
		noAcceptable = 0xFF,     /// No acceptable methods
	}

	/// SOCKS5 commands
	enum Command : ubyte
	{
		connect = 0x01,      /// CONNECT
		bind = 0x02,         /// BIND
		udpAssociate = 0x03, /// UDP ASSOCIATE
	}

	/// Address types
	enum AddressType : ubyte
	{
		ipv4 = 0x01,       /// IPv4 address
		domainName = 0x03, /// Domain name
		ipv6 = 0x04,       /// IPv6 address
	}

	/// Reply codes
	enum Reply : ubyte
	{
		succeeded = 0x00,                /// Succeeded
		generalFailure = 0x01,           /// General SOCKS server failure
		notAllowed = 0x02,               /// Connection not allowed by ruleset
		networkUnreachable = 0x03,       /// Network unreachable
		hostUnreachable = 0x04,          /// Host unreachable
		connectionRefused = 0x05,        /// Connection refused
		ttlExpired = 0x06,               /// TTL expired
		commandNotSupported = 0x07,      /// Command not supported
		addressTypeNotSupported = 0x08,  /// Address type not supported
	}

	private enum State
	{
		greeting,    /// Sending greeting, waiting for method selection
		requesting,  /// Sending request, waiting for reply
		connected,   /// Connected through proxy, data flows transparently
	}

	private State socksState;
	private Data inBuffer;

	/// Target host to connect to through the proxy
	string targetHost;

	/// Target port to connect to through the proxy
	ushort targetPort;

	/**
	 * Create a SOCKS5 adapter.
	 *
	 * Params:
	 *   next = The connection to the SOCKS5 proxy server
	 *   targetHost = The destination host to connect to through the proxy (can be set later via setTarget)
	 *   targetPort = The destination port to connect to through the proxy (can be set later via setTarget)
	 */
	this(IConnection next, string targetHost = null, ushort targetPort = 0)
	{
		this.targetHost = targetHost;
		this.targetPort = targetPort;
		super(next);
		socksState = State.greeting;
	}

	/**
	 * Set the target host and port.
	 * Must be called before the connection to the proxy is established.
	 *
	 * Params:
	 *   targetHost = The destination host to connect to through the proxy
	 *   targetPort = The destination port to connect to through the proxy
	 */
	void setTarget(string targetHost, ushort targetPort)
	{
		enforce(next.state == ConnectionState.disconnected,
			"Cannot set target after connection is established");
		this.targetHost = targetHost;
		this.targetPort = targetPort;
	}

	override void onConnect()
	{
		enforce(targetHost !is null && targetPort != 0,
			"Target host and port must be set before connecting");
		debug(SOCKS5) stderr.writefln("SOCKS5: Connected to proxy, sending greeting");
		sendGreeting();
	}

	override void onReadData(Data data)
	{
		inBuffer ~= data;

		while (inBuffer.length > 0)
		{
			final switch (socksState)
			{
				case State.greeting:
					if (!processMethodSelection())
						return;
					break;

				case State.requesting:
					if (!processReply())
						return;
					break;

				case State.connected:
					// Pass data through transparently
					auto buf = inBuffer;
					inBuffer = Data.init;
					super.onReadData(buf);
					return;
			}
		}
	}

	override void send(scope Data[] data, int priority)
	{
		enforce(socksState == State.connected,
			"Cannot send data before SOCKS5 connection is established");
		super.send(data, priority);
	}

	alias send = IConnection.send; /// ditto

private:
	/// Send the initial greeting with supported authentication methods
	void sendGreeting()
	{
		// +----+----------+----------+
		// |VER | NMETHODS | METHODS  |
		// +----+----------+----------+
		// | 1  |    1     | 1 to 255 |
		// +----+----------+----------+

		ubyte[] greeting = [
			SOCKS_VERSION,
			1,                        // Number of methods
			AuthMethod.noAuth,        // Method: No authentication
		];

		next.send(Data(greeting));
		debug(SOCKS5) stderr.writefln("SOCKS5: Sent greeting");
	}

	/// Process the method selection response from the server
	bool processMethodSelection()
	{
		// +----+--------+
		// |VER | METHOD |
		// +----+--------+
		// | 1  |   1    |
		// +----+--------+

		if (inBuffer.length < 2)
			return false;

		ubyte ver, method;
		inBuffer.enter((scope ubyte[] bytes) {
			ver = bytes[0];
			method = bytes[1];
		});

		debug(SOCKS5) stderr.writefln("SOCKS5: Received method selection: version=%d, method=%d",
			ver, method);

		enforce(ver == SOCKS_VERSION, "Invalid SOCKS version in method selection");
		enforce(method != AuthMethod.noAcceptable, "No acceptable authentication methods");
		enforce(method == AuthMethod.noAuth, "Only no-auth method is supported");

		// Consume the response
		inBuffer = inBuffer[2 .. $];

		socksState = State.requesting;
		sendRequest();

		return true;
	}

	/// Send the connection request
	void sendRequest()
	{
		// +----+-----+-------+------+----------+----------+
		// |VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
		// +----+-----+-------+------+----------+----------+
		// | 1  |  1  | X'00' |  1   | Variable |    2     |
		// +----+-----+-------+------+----------+----------+

		Data request;

		// Try to parse as IP address first
		bool isIPv4, isIPv6;
		ubyte[4] ipv4Bytes;
		ubyte[16] ipv6Bytes;

		try
		{
			auto addr = new InternetAddress(targetHost, targetPort);
			isIPv4 = true;
			// Get the raw address bytes in network byte order
			auto sin = cast(sockaddr_in*)addr.name();
			auto addrBytes = cast(ubyte*)&sin.sin_addr.s_addr;
			ipv4Bytes[] = addrBytes[0..4];
		}
		catch (Exception)
		{
			try
			{
				auto addr = new Internet6Address(targetHost, targetPort);
				isIPv6 = true;
				// Get the raw address bytes
				auto sin6 = cast(sockaddr_in6*)addr.name();
				auto addrBytes = cast(ubyte*)&sin6.sin6_addr;
				ipv6Bytes[] = addrBytes[0..16];
			}
			catch (Exception)
			{
				// Not an IP address, use domain name
			}
		}

		if (isIPv4)
		{
			ubyte[] req = [
				SOCKS_VERSION,
				Command.connect,
				0,                        // Reserved
				AddressType.ipv4,
			];
			req ~= ipv4Bytes[];
			NetworkByteOrder!ushort port = targetPort;
			req ~= port.asBytes[];
			request = Data(req);

			debug(SOCKS5) stderr.writefln("SOCKS5: Sending CONNECT request for IPv4 %s:%d",
				targetHost, targetPort);
		}
		else if (isIPv6)
		{
			ubyte[] req = [
				SOCKS_VERSION,
				Command.connect,
				0,                        // Reserved
				AddressType.ipv6,
			];
			req ~= ipv6Bytes[];
			NetworkByteOrder!ushort port = targetPort;
			req ~= port.asBytes[];
			request = Data(req);

			debug(SOCKS5) stderr.writefln("SOCKS5: Sending CONNECT request for IPv6 %s:%d",
				targetHost, targetPort);
		}
		else
		{
			// Domain name
			auto hostBytes = targetHost.representation;
			enforce(hostBytes.length <= 255, "Domain name too long");

			ubyte[] req = [
				SOCKS_VERSION,
				Command.connect,
				0,                        // Reserved
				AddressType.domainName,
				cast(ubyte)hostBytes.length,
			];
			req ~= hostBytes;
			NetworkByteOrder!ushort port = targetPort;
			req ~= port.asBytes[];
			request = Data(req);

			debug(SOCKS5) stderr.writefln("SOCKS5: Sending CONNECT request for domain %s:%d",
				targetHost, targetPort);
		}

		next.send(request);
	}

	/// Process the reply from the server
	bool processReply()
	{
		// +----+-----+-------+------+----------+----------+
		// |VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
		// +----+-----+-------+------+----------+----------+
		// | 1  |  1  | X'00' |  1   | Variable |    2     |
		// +----+-----+-------+------+----------+----------+

		if (inBuffer.length < 4)
			return false;

		ubyte ver, rep, rsv, atyp;
		inBuffer.enter((scope ubyte[] bytes) {
			ver = bytes[0];
			rep = bytes[1];
			rsv = bytes[2];
			atyp = bytes[3];
		});

		debug(SOCKS5) stderr.writefln("SOCKS5: Received reply header: version=%d, reply=%d, atyp=%d",
			ver, rep, atyp);

		enforce(ver == SOCKS_VERSION, "Invalid SOCKS version in reply");

		// Calculate the total length of the reply
		size_t addressLength;
		final switch (cast(AddressType)atyp)
		{
			case AddressType.ipv4:
				addressLength = 4;
				break;
			case AddressType.ipv6:
				addressLength = 16;
				break;
			case AddressType.domainName:
				if (inBuffer.length < 5)
					return false;
				inBuffer.enter((scope ubyte[] bytes) {
					addressLength = 1 + bytes[4];  // Length byte + domain
				});
				break;
		}

		size_t totalLength = 4 + addressLength + 2;  // Header + address + port

		if (inBuffer.length < totalLength)
			return false;

		// We have the complete reply
		if (rep != Reply.succeeded)
		{
			string error = "SOCKS5 error: ";
			final switch (cast(Reply)rep)
			{
				case Reply.succeeded:
					break;
				case Reply.generalFailure:
					error ~= "General SOCKS server failure";
					break;
				case Reply.notAllowed:
					error ~= "Connection not allowed by ruleset";
					break;
				case Reply.networkUnreachable:
					error ~= "Network unreachable";
					break;
				case Reply.hostUnreachable:
					error ~= "Host unreachable";
					break;
				case Reply.connectionRefused:
					error ~= "Connection refused";
					break;
				case Reply.ttlExpired:
					error ~= "TTL expired";
					break;
				case Reply.commandNotSupported:
					error ~= "Command not supported";
					break;
				case Reply.addressTypeNotSupported:
					error ~= "Address type not supported";
					break;
			}

			disconnect(error, DisconnectType.error);
			return false;
		}

		// Consume the reply
		inBuffer = inBuffer[totalLength .. $];

		socksState = State.connected;
		debug(SOCKS5) stderr.writefln("SOCKS5: Successfully connected through proxy");

		// Notify that the connection is established
		super.onConnect();

		return true;
	}
}

// ***************************************************************************

static if (__traits(compiles, { import ae.net.http.client; }))
{
	import ae.net.http.client : Connector;

	/// Connector for use with ae.net.http.client.HttpClient to route HTTP requests through a SOCKS5 proxy.
	class SOCKS5Connector : Connector
	{
		private string proxyHost;
		private ushort proxyPort;
		private SOCKS5ClientAdapter adapter;
		private TcpConnection tcpConn;

		/**
		 * Create a SOCKS5 connector.
		 *
		 * Params:
		 *   proxyHost = Hostname or IP address of the SOCKS5 proxy server
		 *   proxyPort = Port number of the SOCKS5 proxy server
		 */
		this(string proxyHost, ushort proxyPort)
		{
			this.proxyHost = proxyHost;
			this.proxyPort = proxyPort;

			// Create the TCP connection and SOCKS5 adapter immediately
			// (target will be set later in connect())
			tcpConn = new TcpConnection();
			adapter = new SOCKS5ClientAdapter(tcpConn);
		}

		/// Get the connection (IConnection interface).
		override IConnection getConnection()
		{
			return adapter;
		}

		/// Connect to the target host through the SOCKS5 proxy.
		override void connect(string host, ushort port)
		{
			// Set the target for the SOCKS5 adapter
			adapter.setTarget(host, port);

			// Connect to the SOCKS5 proxy (the adapter handles the SOCKS5 handshake)
			tcpConn.connect(proxyHost, proxyPort);
		}
	}
}

debug(ae_unittest) unittest
{
	// Basic test to verify the adapter compiles and can be instantiated
	import ae.net.asockets : TcpConnection;

	auto conn = new TcpConnection();
	auto socks = new SOCKS5ClientAdapter(conn, "example.com", 80);
	assert(socks !is null);

	// Test connector if http.client is available
	static if (__traits(compiles, { import ae.net.http.client; }))
	{
		auto connector = new SOCKS5Connector("localhost", 1080);
		assert(connector !is null);
	}
}
