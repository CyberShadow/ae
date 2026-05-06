/**
 * A simple HTTP server.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.net.http.server;

import std.algorithm.mutation : move;
import std.algorithm.searching : canFind;
import std.conv;
import std.datetime;
import std.exception;
import std.range;
import std.socket;
import std.string;
import std.uri;

import ae.net.asockets;
import ae.net.http.chunked : ChunkedDecodingAdapter;
import ae.net.ietf.headerparse;
import ae.net.ietf.headers;
import ae.net.ssl;
import ae.sys.data;
import ae.sys.dataset : bytes, DataVec, joinData, joinToGC;
import ae.sys.log;
import ae.utils.array;
import ae.utils.container.listnode;
import ae.utils.exception;
import ae.utils.text;
import ae.utils.textout;

public import ae.net.http.common;
public import ae.net.endpoint : Endpoint, SocketEndpoint;
version (Windows) public import ae.net.endpoint : NamedPipeEndpoint;

debug(HTTP) import std.stdio : stderr;

// TODO:
// - Decouple protocol from network operations.
//   This should work on IConnection everywhere.
// - Unify HTTP client and server connections.
//   Aside the first line, these are pretty much the same protocols.
// - We have more than one axis of parameters:
//   transport socket type, whether TLS is enabled, possibly more.
//   We have only one axis of polymorphism (class inheritance),
//   so combinations such as UNIX TLS HTTP server are difficult to represent.
//   Refactor to fix this.
// - HTTP bodies have stream semantics, and should be represented as such.

/// Abstract acceptor for use with `HttpServer`.
/// Implementations produce `IConnection` instances on accept and pass
/// `Endpoint` objects describing the local bind point and the remote
/// peer alongside each connection. (Mirrors `ae.net.http.client.Connector`
/// for the server side.)
interface Acceptor
{
	alias AcceptHandler = void delegate(
		IConnection incoming, Endpoint local, Endpoint remote);
	@property AcceptHandler handleAccept();
	@property void handleAccept(AcceptHandler value);

	alias CloseHandler = void delegate();
	@property void handleClose(CloseHandler value);

	@property bool isListening();
	void close();

	/// Returns one Endpoint per bound address/path. Used by callers
	/// that want to log a listening banner or introspect where the
	/// server is bound.
	Endpoint[] localEndpoints();
}

/// Acceptor backed by a `TcpServer`.
class TcpAcceptor : Acceptor
{
	TcpServer server;
	private AcceptHandler _onAccept;

	this()                  { server = new TcpServer(); }
	this(TcpServer server)  { this.server = server; }

	/// Bind to the given port and address. Forwards to
	/// `TcpServer.listen(port, addr)`. Returns the actual port bound
	/// (useful when port == 0).
	ushort listen(ushort port, string addr = null)
	{
		return server.listen(port, addr);
	}

	/// Bind to the given address-info entries. Forwards to
	/// `TcpServer.listen(AddressInfo[])`.
	void listen(AddressInfo[] addresses)
	{
		server.listen(addresses);
	}

	@property AcceptHandler handleAccept() { return _onAccept; }

	@property void handleAccept(AcceptHandler value)
	{
		_onAccept = value;
		// TcpServer.handleAccept hides SocketServer.handleAccept; cast to
		// reach the base-class setter that accepts void delegate(SocketConnection).
		auto ss = cast(SocketServer) server;
		if (value)
			ss.handleAccept = (SocketConnection inc) {
				value(inc,
				      new SocketEndpoint(inc.localAddress),
				      new SocketEndpoint(inc.remoteAddress));
			};
		else
			ss.handleAccept = null;
	}

	@property void handleClose(CloseHandler value)
	{
		server.handleClose = value;
	}

	@property bool isListening() { return server.isListening; }
	void close()                 { server.close(); }

	Endpoint[] localEndpoints()
	{
		Endpoint[] r;
		foreach (a; server.localAddresses)
			r ~= new SocketEndpoint(a);
		return r;
	}
}

/// Acceptor backed by a `NamedPipeServer` (Windows-only).
version (Windows)
class NamedPipeAcceptor : Acceptor
{
	NamedPipeServer server;
	private AcceptHandler _onAccept;

	this(string pipeName, SECURITY_ATTRIBUTES* sa = null)
	{
		server = new NamedPipeServer(pipeName);
		server.securityAttributes = sa;
	}

	this(NamedPipeServer server) { this.server = server; }

	/// Start accepting. Forwards to `NamedPipeServer.listen()`.
	/// (No port/address args — the pipe name was set at construction.)
	void listen() { server.listen(); }

	@property AcceptHandler handleAccept() { return _onAccept; }

	@property void handleAccept(AcceptHandler value)
	{
		_onAccept = value;
		if (value)
			server.handleAccept = (WindowsPipeConnection inc) {
				// Named pipes have no separate local/remote identity at
				// the OS level; pass the same Endpoint for both.
				auto ep = new NamedPipeEndpoint(server.pipeName);
				value(inc, ep, ep);
			};
		else
			server.handleAccept = null;
	}

	@property void handleClose(CloseHandler value)
	{
		server.handleClose = value;
	}

	@property bool isListening() { return server.isListening; }
	void close()                 { server.close(); }

	Endpoint[] localEndpoints()
	{
		return [ cast(Endpoint) new NamedPipeEndpoint(server.pipeName) ];
	}
}

/// The base class for an incoming connection to a HTTP server,
/// unassuming of transport.
class BaseHttpServerConnection
{
public:
	TimeoutAdapter timer; /// Time-out adapter.
	IConnection conn; /// Connection used for this HTTP connection.

	HttpRequest currentRequest; /// The current in-flight request.
	bool persistent; /// Whether we will keep the connection open after the request is handled.
	bool optimizeResponses = true; /// Whether we should compress responses according to the request headers.
	bool satisfyRangeRequests = true; /// Whether we should follow "Range" request headers.

	bool connected = true; /// Are we connected now?
	Logger log; /// Optional HTTP log.

	void delegate(HttpRequest request) handleRequest; /// Callback to handle a fully received request.

protected:
	string protocol;
	DataVec inBuffer;
	size_t responseSize;
	bool requestProcessing; // user code is asynchronously processing current request
	DataVec bodyData; // accumulated decoded body data during body reading
	bool firstRequest = true;
	Duration timeout = HttpServer.defaultTimeout;
	bool timeoutActive;
	string banner;

	this(IConnection c)
	{
		debug (HTTP) debugLog("New connection from %s", remoteAddressStr(null));

		if (timeout != Duration.zero)
		{
			timer = new TimeoutAdapter(c);
			timer.setIdleTimeout(timeout);
			c = timer;
		}

		this.conn = c;
		conn.handleReadData = &onNewRequest;
		conn.handleDisconnect = &onDisconnect;

		timeoutActive = true;
	}

	debug (HTTP)
	final void debugLog(Args...)(Args args)
	{
		stderr.writef("[%s %s] ", Clock.currTime(), cast(void*)this);
		stderr.writefln(args);
	}

	final void onNewRequest(Data data)
	{
		try
		{
			inBuffer ~= data;
			debug (HTTP) debugLog("Receiving start of request (%d new bytes, %d total)", data.length, inBuffer.bytes.length);

			string reqLine;
			Headers headers;

			if (!parseHeaders(inBuffer, reqLine, headers))
			{
				debug (HTTP) debugLog("Headers not yet received. Data in buffer:\n%s---", inBuffer.joinToGC().as!string);
				return;
			}

			debug (HTTP)
			{
				debugLog("Headers received:");
				debugLog("> %s", reqLine);
				foreach (name, value; headers)
					debugLog("> %s: %s", name, value);
			}

			currentRequest = new HttpRequest;
			currentRequest.protocol = protocol;
			currentRequest.parseRequestLine(reqLine);
			currentRequest.headers = headers;

			auto connection = toLower(currentRequest.headers.get("Connection", null));
			switch (currentRequest.protocolVersion)
			{
				case "1.0":
					persistent = connection == "keep-alive";
					break;
				default: // 1.1+
					persistent = connection != "close";
					break;
			}
			debug (HTTP) debugLog("This %s connection %s persistent", currentRequest.protocolVersion, persistent ? "IS" : "is NOT");

			auto transferEncoding = toLower(currentRequest.headers.get("Transfer-Encoding", null));
			if (transferEncoding == "chunked")
			{
				debug (HTTP) debugLog("Request uses chunked transfer encoding");
				auto decoder = new ChunkedDecodingAdapter(conn);
				decoder.handleReadData = &onBodyData;
				decoder.handleDisconnect = &onDisconnect;
				decoder.handleFinished = &onBodyFinished;
				setupBodyDecoder(decoder);
			}
			else
			if ("Content-Length" in currentRequest.headers)
			{
				auto contentLength = to!size_t(currentRequest.headers["Content-Length"]);
				if (contentLength > 0)
				{
					auto decoder = new ContentLengthAdapter(conn, contentLength);
					decoder.handleReadData = &onBodyData;
					decoder.handleDisconnect = &onDisconnect;
					decoder.handleFinished = &onBodyFinished;
					setupBodyDecoder(decoder);
				}
				else
					processRequest(DataVec.init);
			}
			else
				processRequest(DataVec.init);
		}
		catch (CaughtException e)
		{
			debug (HTTP) debugLog("Exception onNewRequest: %s", e);
			if (conn && conn.state == ConnectionState.connected)
			{
				HttpResponse response;
				debug
				{
					response = new HttpResponse();
					response.status = HttpStatusCode.InternalServerError;
					response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.InternalServerError);
					response.headers["Content-Type"] = "text/plain";
					response.data = DataVec(Data(e.toString().asBytes));
				}
				sendResponse(response);
			}
			else
				assert(false, "Unhandled HTTP exception after disconnect");
		}
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		debug (HTTP) debugLog("Disconnect: %s", reason);
		connected = false;
	}

	/// Set up a body framing adapter and feed it any data already
	/// buffered after the headers.
	final void setupBodyDecoder(ConnectionAdapter decoder)
	{
		bodyData = DataVec.init;
		// Feed any body data already buffered after the headers.
		// Use joinData to produce a single Data so that if the adapter
		// fires handleFinished synchronously, the iteration is complete.
		if (inBuffer.bytes.length > 0)
		{
			auto buffered = inBuffer.joinData();
			inBuffer = DataVec.init;
			decoder.onReadData(buffered);
		}
	}

	final void onBodyData(Data data)
	{
		debug (HTTP) debugLog("Receiving body data: %d bytes", data.length);
		bodyData ~= data;
	}

	final void onBodyFinished(scope Data[] rest)
	{
		debug (HTTP) debugLog("Request body complete (%d bytes)", bodyData.bytes.length);
		inBuffer ~= rest;
		// Unwire the body adapter; accumulate any further data for pipelining
		conn.handleReadData = &onBodyAccumulate;
		processRequest(move(bodyData));
	}

	final void onBodyAccumulate(Data data)
	{
		inBuffer ~= data;
	}

	final void processRequest(DataVec data)
	{
		debug (HTTP) debugLog("processRequest (%d bytes)", data.bytes.length);
		currentRequest.data = move(data);
		timeoutActive = false;
		if (timer)
			timer.cancelIdleTimeout();
		if (handleRequest)
		{
			// Log unhandled exceptions, but don't mess up the stack trace
			//scope(failure) logRequest(currentRequest, null);

			// sendResponse may be called immediately, or later
			requestProcessing = true;
			handleRequest(currentRequest);
		}
	}

	final void logRequest(HttpRequest request, HttpResponse response)
	{
		debug // avoid linewrap in terminal during development
			enum DEBUG = true;
		else
			enum DEBUG = false;

		if (log) log(([
			"", // align IP to tab
			remoteAddressStr(request),
			response ? text(cast(ushort)response.status) : "-",
			request ? format("%9.2f ms", request.age.total!"usecs" / 1000f) : "-",
			request ? request.method : "-",
			request ? formatLocalAddress(request) ~ request.resource : "-",
			response ? response.headers.get("Content-Type", "-") : "-",
		] ~ (DEBUG ? [] : [
			request ? request.headers.get("Referer", "-") : "-",
			request ? request.headers.get("User-Agent", "-") : "-",
		])).join("\t"));
	}

	abstract string formatLocalAddress(HttpRequest r);

	/// Idle connections are those which can be closed when the server
	/// is shutting down.
	final @property bool idle()
	{
		// Technically, with a persistent connection, we never know if
		// there is a request on the wire on the way to us which we
		// haven't received yet, so it's not possible to truly know
		// when the connection is idle and can be safely closed.
		// However, we do have the ability to do that for
		// non-persistent connections - assume that a connection is
		// never idle until we receive (and process) the first
		// request.  Therefore, in deployments where clients require
		// that an outstanding request is always processed before the
		// server is shut down, non-persistent connections can be used
		// (i.e. no attempt to reuse `HttpClient`) to achieve this.
		if (firstRequest)
			return false;

		if (requestProcessing)
			return false;

		foreach (datum; inBuffer)
			if (datum.length)
				return false;

		return true;
	}

	/// Send the given HTTP response, and do nothing else.
	final void writeResponse(HttpResponse response)
	{
		assert(response.status != 0, "Attempting to write a response without a status code");

		if (currentRequest)
		{
			if (optimizeResponses)
				response.optimizeData(currentRequest.headers);
			if (satisfyRangeRequests)
				response.sliceData(currentRequest.headers);
		}

		if ("Content-Length" !in response.headers)
			response.headers["Content-Length"] = text(response.data.bytes.length);

		sendHeaders(response);

		bool isHead = currentRequest ? currentRequest.method == "HEAD" : false;
		if (response && response.data.length && !isHead)
			sendData(response.data[]);

		responseSize = response ? response.data.bytes.length : 0;
		debug (HTTP) debugLog("Sent response (%d bytes data)", responseSize);
	}

public:
	/// Send the given HTTP response.
	final void sendResponse(HttpResponse response)
	{
		requestProcessing = false;
		if (!response)
		{
			debug (HTTP) debugLog("sendResponse(null) - generating dummy response");
			response = new HttpResponse();
			response.status = HttpStatusCode.InternalServerError;
			response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.InternalServerError);
			response.data = DataVec(Data("Internal Server Error".asBytes));
		}
		writeResponse(response);

		closeResponse();

		logRequest(currentRequest, response);
	}

	/// Switch protocols.
	/// If `response` is given, send that first.
	/// Then, release the connection and return it.
	final Upgrade upgrade(HttpResponse response = null)
	{
		requestProcessing = false;
		if (response)
			writeResponse(response);

		conn.handleReadData = null;
		conn.handleDisconnect = null;

		Upgrade upgrade;
		upgrade.conn = conn;
		upgrade.initialData = move(inBuffer);

		this.conn = null;
		assert(!timeoutActive);

		logRequest(currentRequest, response);
		return upgrade;
	}

	struct Upgrade
	{
		IConnection conn; /// The connection.

		/// Any data that came after the request.
		/// It is almost surely part of the protocol being upgraded to,
		/// so it should be parsed as such.
		DataVec initialData;
	} /// ditto

	/// Send these headers only.
	/// Low-level alternative to `sendResponse`.
	final void sendHeaders(Headers headers, HttpStatusCode status, string statusMessage = null)
	{
		assert(status, "Unset status code");

		if (!statusMessage)
			statusMessage = HttpResponse.getStatusMessage(status);

		StringBuilder respMessage;
		auto protocolVersion = currentRequest ? currentRequest.protocolVersion : "1.0";
		respMessage.put("HTTP/", protocolVersion, " ");

		if (banner && "X-Powered-By" !in headers)
			headers["X-Powered-By"] = banner;

		if ("Date" !in headers)
			headers["Date"] = httpTime(Clock.currTime());

		if ("Connection" !in headers)
		{
			if (persistent && protocolVersion=="1.0")
				headers["Connection"] = "Keep-Alive";
			else
			if (!persistent && protocolVersion=="1.1")
				headers["Connection"] = "close";
		}

		respMessage.put("%d %s\r\n".format(status, statusMessage));
		foreach (string header, string value; headers)
			respMessage.put(header, ": ", value, "\r\n");

		debug (HTTP) debugLog("Response headers:\n> %s", respMessage.get().chomp().replace("\r\n", "\n> "));

		respMessage.put("\r\n");
		conn.send(Data(respMessage.get().asBytes));
	}

	/// ditto
	final void sendHeaders(HttpResponse response)
	{
		sendHeaders(response.headers, response.status, response.statusMessage);
	}

	/// Send this data only.
	/// Headers should have already been sent.
	/// Low-level alternative to `sendResponse`.
	final void sendData(scope Data[] data)
	{
		conn.send(data);
	}

	/// Accept more requests on the same connection?
	protected bool acceptMore() { return true; }

	/// Finalize writing the response.
	/// Headers and data should have already been sent.
	/// Low-level alternative to `sendResponse`.
	final void closeResponse()
	{
		firstRequest = false;
		if (persistent && acceptMore)
		{
			// reset for next request
			debug (HTTP) debugLog("  Waiting for next request.");
			conn.handleReadData = &onNewRequest;
			if (!timeoutActive)
			{
				// Give the client time to download large requests.
				// Assume a minimal speed of 1kb/s.
				if (timer)
					timer.setIdleTimeout(timeout + (responseSize / 1024).seconds);
				timeoutActive = true;
			}
			if (inBuffer.bytes.length) // a second request has been pipelined
			{
				debug (HTTP) debugLog("A second request has been pipelined: %d datums, %d bytes", inBuffer.length, inBuffer.bytes.length);
				onNewRequest(Data());
			}
		}
		else
		{
			string reason = persistent ? "Server has been shut down" : "Non-persistent connection";
			debug (HTTP) debugLog("  Closing connection (%s).", reason);
			conn.disconnect(reason);
		}
	}

	/// Retrieve the remote address of the peer, as a string.
	abstract @property string remoteAddressStr(HttpRequest r);
}

/// Basic unencrypted HTTP 1.0/1.1 server.
class HttpServer
{
	enum defaultTimeout = 30.seconds; /// The default timeout used for incoming connections.

// public:
	this(Duration timeout = defaultTimeout)
	{
		this(new TcpAcceptor(), timeout);
	} ///

	this(Acceptor acceptor, Duration timeout = defaultTimeout)
	{
		assert(timeout > Duration.zero);
		this.timeout = timeout;
		this.acceptor = acceptor;
		acceptor.handleClose = &onClose;
		acceptor.handleAccept = &onAccept;
	} ///

	/// Listen on the given TCP address and port (convenience for the
	/// common case). Requires the default `TcpAcceptor`; for non-TCP
	/// transports, construct an `Acceptor` explicitly and pass it to
	/// the `HttpServer(Acceptor, ...)` constructor.
	/// If port is 0, listen on a random available port.
	/// Returns the port that the server is actually listening on.
	ushort listen(ushort port, string addr = null)
	{
		auto tcp = cast(TcpAcceptor) acceptor;
		assert(tcp, "HttpServer.listen(port, addr) requires a TcpAcceptor");
		port = tcp.listen(port, addr);
		logListening();
		return port;
	}

	/// ditto
	void listen(AddressInfo[] addresses)
	{
		auto tcp = cast(TcpAcceptor) acceptor;
		assert(tcp, "HttpServer.listen(addresses) requires a TcpAcceptor");
		tcp.listen(addresses);
		logListening();
	}

	deprecated("Use HttpServer.localEndpoints (or your TcpAcceptor's "
	         ~ "server.localAddresses) directly. This accessor is "
	         ~ "TCP-specific and will be removed.")
	@property Address[] localAddresses()
	{
		Address[] r;
		foreach (ep; acceptor.localEndpoints())
			if (auto se = cast(SocketEndpoint) ep)
				r ~= se.address;
		return r;
	}

	/// Returns the endpoints this server's acceptor is bound to.
	/// Replaces the deprecated localAddresses for non-socket transports.
	@property Endpoint[] localEndpoints()
	{
		return acceptor.localEndpoints();
	}

	/// Stop listening, and close idle client connections.
	void close()
	{
		debug(HTTP) stderr.writeln("Shutting down");
		if (log) log("Shutting down.");
		acceptor.close();

		debug(HTTP) stderr.writefln("There still are %d active connections", connections.iterator.walkLength);

		// Close idle connections
		foreach (connection; connections.iterator.array)
			if (connection.idle && connection.conn.state == ConnectionState.connected)
				connection.conn.disconnect("HTTP server shutting down");
	}

	/// Optional HTTP request log.
	Logger log;

	/// Single-ended doubly-linked list of active connections
	SEDListContainer!HttpServerConnection connections;

	/// Callback for when the socket was closed.
	void delegate() handleClose;
	/// Callback for an incoming request.
	void delegate(HttpRequest request, HttpServerConnection conn) handleRequest;

	/// What to send in the `"X-Powered-By"` header.
	string banner = "ae.net.http.server (+https://github.com/CyberShadow/ae)";

	/// If set, the name of the header which will be used to obtain
	/// the actual IP of the connecting peer.  Useful when this
	/// `HttpServer` is behind a reverse proxy.
	string remoteIPHeader;

protected:
	Acceptor acceptor;
	Duration timeout;

	private void logListening()
	{
		if (log)
			foreach (ep; acceptor.localEndpoints())
				log("Listening on " ~ protocol ~ "://" ~ ep.toString());
	}

	void onClose()
	{
		if (handleClose)
			handleClose();
	}

	IConnection adaptConnection(IConnection transport)
	{
		return transport;
	}

	@property string protocol() { return "http"; }

	void onAccept(IConnection incoming, Endpoint local, Endpoint remote)
	{
		try
			new HttpServerConnection(this, incoming, local, remote,
			                         adaptConnection(incoming), protocol);
		catch (Exception e)
		{
			if (log)
				log("Error accepting connection: " ~ e.msg);
			if (incoming.state == ConnectionState.connected)
				incoming.disconnect();
		}
	}
}

/**
   HTTPS server. Set SSL parameters on ctx after instantiation.

   Example:
   ---
   auto s = new HttpsServer();
   // OpenSSL-specific options (cast ctx to OpenSSLContext if needed):
   // (cast(OpenSSLContext)s.ctx).enableDH(4096);
   // (cast(OpenSSLContext)s.ctx).enableECDH();
   s.ctx.setCertificate("server.crt");
   s.ctx.setPrivateKey("server.key");
   ---
*/
class HttpsServer : HttpServer
{
	SSLContext ctx; /// The SSL context.

	this(Duration timeout = HttpServer.defaultTimeout)
	{
		ctx = ssl.createContext(SSLContext.Kind.server);
		super(timeout);
	} ///

	this(Acceptor acceptor, Duration timeout = HttpServer.defaultTimeout)
	{
		ctx = ssl.createContext(SSLContext.Kind.server);
		super(acceptor, timeout);
	} ///

protected:
	override @property string protocol() { return "https"; }

	override IConnection adaptConnection(IConnection transport)
	{
		return ssl.createAdapter(ctx, transport);
	}
}

/// Standard HTTP server connection, supporting any transport via `IConnection`.
final class HttpServerConnection : BaseHttpServerConnection
{
	/// The underlying transport (any IConnection — socket or pipe).
	/// Equivalent to the `c` constructor argument before any adapter
	/// wrapping by `HttpServer.adaptConnection`.
	IConnection transport;

	HttpServer server; /// `HttpServer` owning this connection.

	/// Endpoints describing the connection. Populated for all
	/// transports (socket and named-pipe).
	Endpoint localEndpoint, remoteEndpoint;

	mixin DListLink;

	deprecated("Cast HttpServerConnection.transport to SocketConnection if "
	         ~ "needed; will be removed.")
	@property SocketConnection socket()
	{
		return cast(SocketConnection) transport;
	}

	deprecated("Use localEndpoint / remoteEndpoint. These accessors return "
	         ~ "null for non-socket transports.")
	@property Address localAddress()
	{
		if (auto se = cast(SocketEndpoint) localEndpoint) return se.address;
		return null;
	}

	deprecated("Use localEndpoint / remoteEndpoint.")
	@property Address remoteAddress()
	{
		if (auto se = cast(SocketEndpoint) remoteEndpoint) return se.address;
		return null;
	}

	/// Retrieves the remote peer address, honoring `remoteIPHeader` if set.
	override @property string remoteAddressStr(HttpRequest r)
	{
		if (server.remoteIPHeader)
		{
			if (r)
				if (auto p = server.remoteIPHeader in r.headers)
					return (*p).split(",")[$ - 1];

			if (auto se = cast(SocketEndpoint) remoteEndpoint)
				return "[local:" ~ se.address.toAddrString() ~ "]";
			return "[local:" ~ remoteEndpoint.toString() ~ "]";
		}

		if (auto se = cast(SocketEndpoint) remoteEndpoint)
			return se.address.toAddrString();
		// Non-socket transport (e.g. named pipe): show the URL form.
		return remoteEndpoint.toString();
	}

protected:
	this(HttpServer server, IConnection transport,
	     Endpoint local, Endpoint remote,
	     IConnection c, string protocol = "http")
	{
		this.server = server;
		this.transport = transport;
		this.localEndpoint = local;
		this.remoteEndpoint = remote;
		this.log = server.log;
		this.protocol = protocol;
		this.banner = server.banner;
		this.timeout = server.timeout;
		this.handleRequest = (HttpRequest r) => server.handleRequest(r, this);

		super(c);

		server.connections.pushFront(this);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		server.connections.remove(this);
	}

	override bool acceptMore() { return server.acceptor.isListening; }

	override string formatLocalAddress(HttpRequest r)
	{
		// For socket transports, preserve the existing vhost+port-aware
		// formatting (request "Host:" header → vhost, request "port" → port).
		if (auto se = cast(SocketEndpoint) localEndpoint)
			return formatAddress(protocol, se.address, r.host, r.port);
		// For non-socket transports, just show the URL form.
		return protocol ~ "://" ~ localEndpoint.toString();
	}
}

/// Format a socket address as an HTTP-flavoured URL: applies vhost / log-port
/// overrides, default-port elision, and IPv6 bracketing. Used for the
/// listening banner and for "you reached me at" URLs in HTTP responses.
string formatAddress(string protocol, Address address,
	string vhost = null, ushort logPort = 0)
{
	string addr = address.toAddrString();
	string port =
		address.addressFamily == AddressFamily.UNIX ? null :
		logPort ? text(logPort) :
		address.toPortString();
	return protocol ~ "://" ~
		(vhost ? vhost
		      : addr == "0.0.0.0" || addr == "::" ? "*"
		      : addr.canFind(":") ? "[" ~ addr ~ "]"
		      : addr) ~
		(port is null || port == "80" ? "" : ":" ~ port);
}

/// `BaseHttpServerConnection` implementation with files, allowing to
/// e.g. read a request from standard input and write the response to
/// standard output.
version (Posix)
class FileHttpServerConnection : BaseHttpServerConnection
{
	this(File input = stdin, File output = stdout, string protocol = "stdin")
	{
		this.protocol = protocol;

		auto c = new Duplex(
			new FileConnection(input.fileno),
			new FileConnection(output.fileno),
		);

		super(c);
	} ///

	override @property string remoteAddressStr(HttpRequest r) { return "-"; } /// Stub.

protected:
	import std.stdio : File, stdin, stdout;

	string protocol;

	override string formatLocalAddress(HttpRequest r) { return protocol ~ "://"; }
}

debug (ae_unittest) import ae.net.http.client;
debug (ae_unittest) import ae.net.http.responseex;
debug(ae_unittest) unittest
{
	int[] replies;
	int closeAfter;

	// Sum "a" from GET and "b" from POST
	auto s = new HttpServer;
	s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		auto get  = request.urlParameters;
		auto post = request.decodePostData();
		auto response = new HttpResponseEx;
		auto result = to!int(get["a"]) + to!int(post["b"]);
		replies ~= result;
		conn.sendResponse(response.serveJson(result));
		if (--closeAfter == 0)
			s.close();
	};

	// Test server, client, parameter encoding
	replies = null;
	closeAfter = 1;
	auto port = s.listen(0, "127.0.0.1");
	httpPost("http://127.0.0.1:" ~ to!string(port) ~ "/?" ~ encodeUrlParameters(["a":"2"]), UrlParameters(["b":"3"]), (string s) { assert(s=="5"); }, null);
	socketManager.loop();

	// Test pipelining, protocol errors
	replies = null;
	closeAfter = 2;
	port = s.listen(0, "127.0.0.1");
	TcpConnection c = new TcpConnection;
	c.handleConnect = {
		c.send(Data((
"GET /?a=123456 HTTP/1.1
Content-length: 8
Content-type: application/x-www-form-urlencoded

b=654321" ~
"GET /derp HTTP/1.1
Content-length: potato

" ~
"GET /?a=1234567 HTTP/1.1
Content-length: 9
Content-type: application/x-www-form-urlencoded

b=7654321").asBytes));
		c.disconnect();
	};
	c.connect("127.0.0.1", port);

	socketManager.loop();

	assert(replies == [777777, 8888888]);

	// Test bad headers
	s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		auto response = new HttpResponseEx;
		conn.sendResponse(response.serveText("OK"));
		if (--closeAfter == 0)
			s.close();
	};
	closeAfter = 1;

	port = s.listen(0, "127.0.0.1");
	c = new TcpConnection;
	c.handleConnect = {
		c.send(Data("\n\n\n\n\n".asBytes));
		c.disconnect();

		// Now send a valid request to end the loop
		c = new TcpConnection;
		c.handleConnect = {
			c.send(Data("GET / HTTP/1.0\n\n".asBytes));
			c.disconnect();
		};
		c.connect("127.0.0.1", port);
	};
	c.connect("127.0.0.1", port);

	socketManager.loop();

/+
	void testFile(string fn)
	{
		std.file.write(fn, "42");
		s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
			auto response = new HttpResponseEx;
			conn.sendResponse(response.serveFile(request.resource[1..$], ""));
			if (--closeAfter == 0)
				s.close();
		};
		port = s.listen(0, "127.0.0.1");
		closeAfter = 1;
		httpGet("http://127.0.0.1:" ~ to!string(port) ~ "/" ~ fn, (string s) { assert(s=="42"); }, null);
		socketManager.loop();
		std.file.remove(fn);
	}

	testFile("http-test.bin");
	testFile("http-test.txt");
+/
}

// Test form-data
debug(ae_unittest) unittest
{
	bool ok;
	auto s = new HttpServer;
	s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		auto post = request.decodePostData();
		assert(post["a"] == "b");
		assert(post["c"] == "d");
		assert(post["e"] == "f");
		ok = true;
		conn.conn.disconnect();
		s.close();
	};
	auto port = s.listen(0, "127.0.0.1");

	TcpConnection c = new TcpConnection;
	c.handleConnect = {
		c.send(Data((q"EOF
POST / HTTP/1.1
Host: google.com
User-Agent: curl/8.1.2
Accept: */*
Content-Length: 319
Content-Type: multipart/form-data; boundary=------------------------f7d0ffeae587957a

--------------------------f7d0ffeae587957a
Content-Disposition: form-data; name="a"

b
--------------------------f7d0ffeae587957a
Content-Disposition: form-data; name="c"

d
--------------------------f7d0ffeae587957a
Content-Disposition: form-data; name="e"

f
--------------------------f7d0ffeae587957a--
EOF".replace("\n", "\r\n")).asBytes));
		c.disconnect();
	};
	c.connect("127.0.0.1", port);

	socketManager.loop();

	assert(ok);
}

// Test chunked transfer encoding on requests
debug(ae_unittest) unittest
{
	bool ok;
	auto s = new HttpServer;
	s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		auto post = request.decodePostData();
		assert(post["a"] == "2");
		assert(post["b"] == "3");
		ok = true;
		auto response = new HttpResponseEx;
		conn.sendResponse(response.serveText("OK"));
		s.close();
	};
	auto port = s.listen(0, "127.0.0.1");

	TcpConnection c = new TcpConnection;
	c.handleConnect = {
		c.send(Data(("POST /?x=1 HTTP/1.1\r\n" ~
			"Host: localhost\r\n" ~
			"Transfer-Encoding: chunked\r\n" ~
			"Content-Type: application/x-www-form-urlencoded\r\n" ~
			"\r\n" ~
			"3\r\n" ~
			"a=2\r\n" ~
			"4\r\n" ~
			"&b=3\r\n" ~
			"0\r\n" ~
			"\r\n").asBytes));
		c.disconnect();
	};
	c.connect("127.0.0.1", port);

	socketManager.loop();

	assert(ok);
}

// Endpoint plan Step 8a: TcpAcceptor.localEndpoints() exposes a SocketEndpoint.
debug(ae_unittest) unittest
{
	auto acceptor = new TcpAcceptor();
	acceptor.listen(0, "127.0.0.1");
	scope(exit) acceptor.close();

	auto eps = acceptor.localEndpoints();
	assert(eps.length >= 1, "TCP acceptor must expose at least one endpoint");
	auto se = cast(SocketEndpoint) eps[0];
	assert(se !is null, "TCP acceptor endpoint must be a SocketEndpoint");
	assert(se.address !is null);

	auto url = "http://" ~ se.toString();
	assert(url.startsWith("http://127.0.0.1:") || url.startsWith("http://*:"),
	       "unexpected URL: " ~ url);
}

// Endpoint plan Step 8b: HttpServerConnection.localEndpoint / .remoteEndpoint populated for TCP.
debug(ae_unittest) unittest
{
	Endpoint capturedLocal, capturedRemote;
	bool gotRequest;

	auto s = new HttpServer;
	s.handleRequest = (HttpRequest req, HttpServerConnection conn) {
		capturedLocal  = conn.localEndpoint;
		capturedRemote = conn.remoteEndpoint;
		auto resp = new HttpResponseEx;
		conn.sendResponse(resp.serveText("OK"));
		gotRequest = true;
		s.close();
	};

	auto port = s.listen(0, "127.0.0.1");
	httpGet("http://127.0.0.1:" ~ to!string(port) ~ "/",
	        (string body_) { /* ignore body */ },
	        (string err) { assert(false, "client error: " ~ err); });
	socketManager.loop();

	assert(gotRequest);
	assert(capturedLocal !is null);
	assert(capturedRemote !is null);
	auto sl = cast(SocketEndpoint) capturedLocal;
	auto sr = cast(SocketEndpoint) capturedRemote;
	assert(sl !is null && sl.address !is null);
	assert(sr !is null && sr.address !is null);
	auto url = "http://" ~ capturedLocal.toString();
	assert(url.startsWith("http://127.0.0.1:") || url.startsWith("http://*:"),
	       "unexpected URL: " ~ url);
}

// Parent plan Step 9: HTTP round-trip over a named pipe (Windows only).
debug(ae_unittest) version (Windows) unittest
{
	import ae.net.http.client : HttpClient, NamedPipeConnector;
	import std.format : format;
	import core.sys.windows.windows : GetCurrentProcessId;

	auto name = format(`\\.\pipe\ae-http-test-%s-%s`,
	                   GetCurrentProcessId(), 0);

	bool gotRequest, gotResponse;
	NamedPipeEndpoint capturedLocal;

	auto acceptor = new NamedPipeAcceptor(name);
	acceptor.listen();
	auto s = new HttpServer(acceptor);
	s.handleRequest = (HttpRequest req, HttpServerConnection conn) {
		gotRequest = true;
		capturedLocal = cast(NamedPipeEndpoint) conn.localEndpoint;
		auto r = new HttpResponseEx;
		conn.sendResponse(r.serveText("hello-pipe"));
		s.close();
	};

	auto client = new HttpClient(30.seconds, new NamedPipeConnector(name));
	auto req = new HttpRequest;
	req.resource = "/";
	req.headers["Host"] = "pipe";
	client.handleResponse = (HttpResponse resp, string reason) {
		assert(resp !is null, "no response: " ~ reason);
		assert(resp.getContent().toGC() == "hello-pipe");
		gotResponse = true;
	};
	client.request(req);

	socketManager.loop();
	assert(gotRequest && gotResponse);
	assert(capturedLocal !is null,
	       "HttpServerConnection.localEndpoint should be a NamedPipeEndpoint");
	assert(capturedLocal.pipeName == name);
}

// Parent plan acceptance #7: HTTPS round-trip over a named pipe using SChannel (Windows only).
// PFX bytes: same self-signed cert as net/ssl/schannel.d:1208 (CN=localhost, password "test").
debug(ae_unittest) version (Windows) unittest
{
	import ae.net.http.client : HttpsClient, NamedPipeConnector;
	import ae.net.ssl.schannel : SChannelContext;
	import ae.net.ssl : SSLContext;
	import std.format : format;
	import core.sys.windows.windows : GetCurrentProcessId;

	static immutable ubyte[] testPfxBytes = [
		0x30, 0x82, 0x09, 0xf7, 0x02, 0x01, 0x03, 0x30, 0x82, 0x09, 0xa5, 0x06, 0x09, 0x2a, 0x86, 0x48,
		0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01, 0xa0, 0x82, 0x09, 0x96, 0x04, 0x82, 0x09, 0x92, 0x30, 0x82,
		0x09, 0x8e, 0x30, 0x82, 0x03, 0xfa, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07,
		0x06, 0xa0, 0x82, 0x03, 0xeb, 0x30, 0x82, 0x03, 0xe7, 0x02, 0x01, 0x00, 0x30, 0x82, 0x03, 0xe0,
		0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01, 0x30, 0x5f, 0x06, 0x09, 0x2a,
		0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0d, 0x30, 0x52, 0x30, 0x31, 0x06, 0x09, 0x2a, 0x86,
		0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c, 0x30, 0x24, 0x04, 0x10, 0x91, 0xe0, 0xca, 0x9e, 0x2b,
		0x33, 0xf2, 0xac, 0xa0, 0xfc, 0x3f, 0xe9, 0x4e, 0xb3, 0x3e, 0xc8, 0x02, 0x02, 0x08, 0x00, 0x30,
		0x0c, 0x06, 0x08, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x02, 0x09, 0x05, 0x00, 0x30, 0x1d, 0x06,
		0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2a, 0x04, 0x10, 0xb8, 0x6b, 0x60, 0x5c,
		0xba, 0xdb, 0xa5, 0x50, 0x13, 0xe0, 0x98, 0xdd, 0x23, 0x6c, 0x87, 0xa9, 0x80, 0x82, 0x03, 0x70,
		0x63, 0x7b, 0x29, 0x5f, 0x6f, 0x99, 0x97, 0x4c, 0xa8, 0xb1, 0x9d, 0xc0, 0x95, 0x0b, 0x2d, 0xd0,
		0x93, 0xb8, 0x1c, 0xdb, 0x89, 0x10, 0x99, 0x27, 0x12, 0xcb, 0x07, 0xd5, 0x3f, 0x28, 0x1f, 0x07,
		0x3a, 0xae, 0x31, 0xb4, 0x92, 0x82, 0xda, 0x0c, 0xff, 0xe6, 0x00, 0x28, 0x9c, 0x6f, 0x33, 0x11,
		0x09, 0x9c, 0x04, 0xc3, 0xe2, 0x24, 0xcb, 0xcf, 0xa6, 0x58, 0xa4, 0xa7, 0x77, 0x7c, 0x59, 0xdd,
		0xaf, 0xbd, 0x29, 0xb3, 0xcb, 0x50, 0x73, 0x5e, 0xd1, 0xf1, 0x17, 0x7d, 0x70, 0xfd, 0xa9, 0x76,
		0x9f, 0x3e, 0xfc, 0x5f, 0xc0, 0xbc, 0xdd, 0x6e, 0xdb, 0x72, 0x0b, 0xcc, 0x79, 0x07, 0xc1, 0x89,
		0x8f, 0x17, 0xc0, 0xe0, 0x6e, 0xc2, 0xc0, 0x2b, 0xfa, 0x67, 0x60, 0x56, 0x5f, 0x7a, 0xe8, 0xdf,
		0x41, 0xb3, 0x9a, 0xc4, 0xb4, 0xfd, 0x4c, 0x72, 0xe0, 0x9b, 0x8d, 0x4a, 0x39, 0xaa, 0x11, 0xbc,
		0x96, 0x15, 0xc0, 0xdc, 0xe7, 0xe3, 0x9c, 0xee, 0x07, 0x1d, 0x51, 0x87, 0xaa, 0xbc, 0xc5, 0x8a,
		0xb9, 0x94, 0x24, 0x95, 0x99, 0xee, 0x21, 0xf8, 0x6f, 0x5a, 0x15, 0x5c, 0xc0, 0x6b, 0xde, 0xab,
		0xb4, 0x19, 0x54, 0x2a, 0x05, 0x0a, 0x4a, 0x0f, 0x97, 0x66, 0x46, 0x10, 0xbf, 0x49, 0xa9, 0x82,
		0xe6, 0x2e, 0x75, 0x63, 0x57, 0x5e, 0x3d, 0x0a, 0x6d, 0x1c, 0x52, 0xaa, 0x1c, 0x6c, 0x26, 0x54,
		0xf0, 0x14, 0x8c, 0xe7, 0xc9, 0x9f, 0x68, 0x39, 0xe4, 0xa1, 0xe5, 0xab, 0xc0, 0xb7, 0x9d, 0xd5,
		0x44, 0xec, 0x36, 0x41, 0x74, 0x2f, 0x27, 0x52, 0x35, 0x36, 0x0d, 0xbd, 0x79, 0x10, 0x3a, 0xc4,
		0xee, 0x3d, 0xb2, 0x05, 0x43, 0xbd, 0xd3, 0x6c, 0x9e, 0x6a, 0x6f, 0x64, 0x50, 0x6c, 0x6a, 0x3a,
		0x91, 0x28, 0x0d, 0x2b, 0x86, 0x8c, 0x54, 0xe5, 0x09, 0x1a, 0xf4, 0x6d, 0xab, 0xfa, 0x73, 0x95,
		0x60, 0xce, 0x4b, 0x2f, 0x6b, 0xb5, 0xcc, 0x9b, 0xa2, 0x16, 0xd9, 0xb9, 0x77, 0xae, 0xc3, 0x22,
		0x5c, 0xcd, 0x5a, 0xac, 0xbb, 0x3d, 0xaf, 0x94, 0x59, 0x0d, 0x2a, 0xf7, 0xd4, 0x6d, 0x9e, 0x4c,
		0xbf, 0x72, 0xd6, 0x5a, 0xc8, 0x1a, 0x8f, 0x89, 0x1e, 0x33, 0xc4, 0x6f, 0x16, 0xd1, 0xcf, 0xd9,
		0x1c, 0xfa, 0x3c, 0x45, 0xcb, 0x50, 0x20, 0x2e, 0x5e, 0xec, 0xe7, 0xaa, 0x13, 0x35, 0xc4, 0x2e,
		0x9a, 0xe3, 0xff, 0x39, 0x4d, 0xdd, 0x5d, 0xe6, 0x06, 0x47, 0x77, 0xaf, 0x5c, 0x0d, 0xed, 0x53,
		0x5d, 0x9b, 0xd3, 0xd2, 0x14, 0xe0, 0x03, 0x03, 0xc5, 0xf9, 0x7e, 0xe8, 0x5f, 0x21, 0xa6, 0x59,
		0x11, 0xa2, 0x32, 0x51, 0x16, 0x84, 0x4b, 0x1f, 0x6f, 0xfc, 0x97, 0x9f, 0x68, 0x15, 0xbe, 0xee,
		0x17, 0x3b, 0x81, 0xce, 0x48, 0xc0, 0xd9, 0x9d, 0x6f, 0x76, 0xc5, 0xa8, 0x61, 0x52, 0x7c, 0x78,
		0x9d, 0xfc, 0x0f, 0xeb, 0xd7, 0x97, 0x19, 0x74, 0x62, 0x3f, 0x86, 0x66, 0x35, 0x94, 0xb0, 0x7e,
		0xf2, 0xbf, 0x92, 0x37, 0x1b, 0xe7, 0xdd, 0x10, 0xbf, 0x09, 0xc7, 0x9d, 0x01, 0xb9, 0x56, 0xad,
		0xb6, 0x35, 0x3b, 0x06, 0xbf, 0xe9, 0xdd, 0xa0, 0x2f, 0x52, 0xcc, 0x04, 0xd5, 0x5d, 0xc5, 0x5d,
		0x21, 0xdc, 0x4f, 0xb6, 0xd3, 0xe9, 0x77, 0x9e, 0x7c, 0x0a, 0xc0, 0xdb, 0x1f, 0x01, 0x2c, 0xf3,
		0xcb, 0x04, 0xc4, 0xf2, 0x97, 0x43, 0x0b, 0x29, 0x4b, 0x35, 0x3b, 0xca, 0x9e, 0x2f, 0x04, 0x29,
		0xda, 0x61, 0x5b, 0xc1, 0xf4, 0x12, 0xe5, 0xec, 0x55, 0xce, 0x17, 0x86, 0x37, 0x89, 0x0c, 0xef,
		0xb3, 0x5e, 0x14, 0x93, 0x4f, 0x14, 0x02, 0xfb, 0x79, 0xba, 0xc8, 0x15, 0x2a, 0x21, 0x28, 0x90,
		0x28, 0xc3, 0xa1, 0x9c, 0xbe, 0xb4, 0xc4, 0x9f, 0x6a, 0xb5, 0x1a, 0x67, 0x41, 0x60, 0x9d, 0xbc,
		0xfd, 0x4d, 0x99, 0xf3, 0x77, 0x01, 0x5c, 0x8e, 0x3a, 0xfd, 0xa9, 0x4e, 0x5f, 0x75, 0xc1, 0x07,
		0xed, 0x30, 0x87, 0x23, 0xf6, 0x88, 0xea, 0xba, 0xa5, 0x4a, 0x10, 0x6c, 0x24, 0x5d, 0x28, 0x49,
		0xb8, 0x8d, 0xdf, 0x06, 0xbc, 0xb2, 0x91, 0x78, 0x51, 0x27, 0x24, 0x73, 0x8b, 0x7d, 0x14, 0x75,
		0x5c, 0x56, 0x6d, 0xa7, 0x8a, 0x8e, 0x15, 0x76, 0x7f, 0xd0, 0xfe, 0x39, 0x5d, 0x5a, 0xcd, 0xea,
		0x08, 0x71, 0xec, 0x15, 0x77, 0x36, 0x51, 0xe7, 0x48, 0xa8, 0xce, 0xd2, 0x94, 0x7b, 0x51, 0x31,
		0xb5, 0x61, 0xc8, 0x8b, 0x4a, 0x2a, 0x0e, 0x31, 0x88, 0x3a, 0x6b, 0x2f, 0xdf, 0x71, 0x41, 0xbd,
		0x58, 0xaa, 0x48, 0x0a, 0x98, 0xbf, 0xdc, 0x8e, 0xde, 0xb7, 0x8c, 0x79, 0x9f, 0xb5, 0x36, 0xb5,
		0xd9, 0xe6, 0x92, 0x09, 0xec, 0x6f, 0x14, 0x4d, 0xaf, 0xd2, 0x80, 0xc9, 0x54, 0x43, 0x9d, 0xc8,
		0xeb, 0xf7, 0x69, 0x98, 0x32, 0xb2, 0x3c, 0x7a, 0xef, 0x16, 0xfa, 0xa5, 0x35, 0x41, 0x42, 0x32,
		0x59, 0x8f, 0x08, 0xad, 0xdd, 0x81, 0xca, 0xae, 0xa6, 0x52, 0x48, 0x17, 0x31, 0x74, 0x94, 0x47,
		0x84, 0x3e, 0x16, 0xe2, 0xe1, 0x1a, 0x5a, 0x67, 0xf7, 0x33, 0x6c, 0xbf, 0xc0, 0xd6, 0x9d, 0x1e,
		0xdb, 0x41, 0x90, 0x53, 0x8d, 0xca, 0x28, 0x7e, 0xb5, 0x17, 0xff, 0x41, 0xf7, 0xad, 0xed, 0xb9,
		0x9f, 0x8a, 0xec, 0xe0, 0x31, 0x02, 0x6e, 0xcc, 0xf2, 0x92, 0x07, 0xf2, 0x58, 0xfc, 0xf3, 0x98,
		0x4f, 0x5d, 0x4a, 0x2a, 0x97, 0x1c, 0x2f, 0x90, 0x81, 0xf5, 0xd2, 0xd1, 0x00, 0x3e, 0x01, 0x47,
		0x9f, 0x5c, 0xbc, 0xd6, 0xfe, 0x97, 0xe7, 0xfa, 0xfc, 0xa9, 0x4f, 0xe7, 0x6a, 0x86, 0x09, 0x4b,
		0x43, 0x6e, 0x60, 0xc8, 0x53, 0x17, 0x0f, 0x58, 0x8d, 0xa9, 0x77, 0xc6, 0xd1, 0xeb, 0x7a, 0x96,
		0x94, 0x2a, 0x66, 0x09, 0xd7, 0xc9, 0x24, 0x31, 0x88, 0x43, 0x5b, 0x63, 0x62, 0x02, 0xd6, 0x72,
		0x17, 0x31, 0xf5, 0x9d, 0x12, 0x1b, 0x50, 0xec, 0xdf, 0x84, 0xa2, 0x4e, 0x4d, 0x6a, 0x3a, 0x24,
		0x21, 0xaf, 0x0f, 0x3d, 0xab, 0x07, 0xf1, 0x65, 0x55, 0x00, 0x6c, 0x7a, 0xa5, 0x90, 0xd9, 0x9e,
		0xc4, 0xc9, 0x35, 0x7f, 0x11, 0xcc, 0xbe, 0xe7, 0x90, 0x61, 0x5f, 0x73, 0x43, 0x39, 0x3e, 0x0a,
		0xdf, 0x16, 0x21, 0xe0, 0x0f, 0xba, 0x5f, 0x4f, 0x2d, 0xe5, 0x28, 0x6c, 0xe0, 0x60, 0x2f, 0x5f,
		0x55, 0x55, 0x2f, 0xd5, 0xe6, 0xb2, 0xad, 0x99, 0x20, 0x61, 0xa1, 0x35, 0x3d, 0x54, 0x5a, 0xdf,
		0x3c, 0x4e, 0xe8, 0xca, 0x4f, 0x5e, 0xd1, 0xbc, 0x76, 0x65, 0x33, 0xba, 0x93, 0x38, 0x38, 0x0f,
		0x30, 0x82, 0x05, 0x8c, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01, 0xa0,
		0x82, 0x05, 0x7d, 0x04, 0x82, 0x05, 0x79, 0x30, 0x82, 0x05, 0x75, 0x30, 0x82, 0x05, 0x71, 0x06,
		0x0b, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x0c, 0x0a, 0x01, 0x02, 0xa0, 0x82, 0x05, 0x39,
		0x30, 0x82, 0x05, 0x35, 0x30, 0x5f, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05,
		0x0d, 0x30, 0x52, 0x30, 0x31, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x05, 0x0c,
		0x30, 0x24, 0x04, 0x10, 0xb1, 0xc3, 0x7d, 0xe7, 0xed, 0xff, 0x2f, 0x75, 0x57, 0x6e, 0x0c, 0x63,
		0x25, 0x20, 0xa3, 0xaa, 0x02, 0x02, 0x08, 0x00, 0x30, 0x0c, 0x06, 0x08, 0x2a, 0x86, 0x48, 0x86,
		0xf7, 0x0d, 0x02, 0x09, 0x05, 0x00, 0x30, 0x1d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03,
		0x04, 0x01, 0x2a, 0x04, 0x10, 0x13, 0x4a, 0x8d, 0x42, 0x66, 0x82, 0xf7, 0xc8, 0xe2, 0xb0, 0xb9,
		0xe4, 0x49, 0x15, 0xec, 0x45, 0x04, 0x82, 0x04, 0xd0, 0x98, 0x6e, 0xb5, 0xf4, 0x70, 0x9f, 0x0c,
		0x72, 0x73, 0x86, 0x80, 0xfb, 0xa0, 0x0a, 0x7e, 0x73, 0x24, 0x19, 0xf6, 0x82, 0x6f, 0x10, 0x66,
		0x3d, 0x02, 0x90, 0xa4, 0xee, 0x1f, 0x9a, 0xc9, 0x36, 0x6a, 0x89, 0xc3, 0x84, 0x48, 0x1c, 0x32,
		0xdb, 0x89, 0x44, 0x9f, 0xb7, 0x05, 0x90, 0xff, 0x1c, 0x65, 0x08, 0x47, 0x6f, 0x7b, 0x9a, 0xe1,
		0x5c, 0x89, 0xdb, 0xc6, 0x24, 0x4f, 0x5a, 0xf4, 0xd1, 0x4a, 0xfb, 0x46, 0x06, 0xb5, 0x67, 0xd9,
		0x16, 0x9a, 0x6e, 0x28, 0xdf, 0x65, 0x99, 0x88, 0xda, 0x55, 0xd2, 0xac, 0x18, 0x74, 0x5e, 0xf5,
		0xdf, 0xa0, 0xf8, 0x4e, 0x92, 0x51, 0xef, 0xa1, 0x23, 0x1a, 0x35, 0x89, 0xa5, 0x96, 0xd7, 0x36,
		0x05, 0x14, 0xd5, 0xe8, 0x85, 0x7e, 0xb2, 0x84, 0x38, 0xa1, 0x49, 0xc0, 0x19, 0xde, 0x0a, 0xbb,
		0x00, 0xd1, 0x84, 0x9e, 0x30, 0xfc, 0x9b, 0x34, 0x7a, 0xb7, 0x71, 0xda, 0x14, 0x2c, 0x89, 0x3c,
		0xc9, 0xd8, 0x21, 0x7d, 0xee, 0x87, 0xba, 0xe3, 0x52, 0x84, 0x34, 0x94, 0xc5, 0x24, 0x35, 0x60,
		0xa8, 0x1f, 0x61, 0x13, 0xd6, 0xbd, 0xc8, 0xc5, 0x78, 0xe8, 0x9d, 0x95, 0x0e, 0xbe, 0x0c, 0x22,
		0x6e, 0xc0, 0x49, 0x1f, 0x08, 0x83, 0x58, 0x2e, 0x0b, 0x33, 0xa6, 0x99, 0x0f, 0x27, 0xc8, 0xb0,
		0xea, 0xfe, 0x6d, 0x2d, 0x47, 0x34, 0xd6, 0x01, 0xa8, 0xa7, 0xc1, 0x0a, 0x89, 0xab, 0x75, 0xa6,
		0x3a, 0x4f, 0x25, 0x0e, 0x34, 0xf3, 0x6e, 0xb7, 0xdf, 0xd0, 0xca, 0x16, 0xd0, 0xdb, 0xd3, 0x30,
		0x2f, 0xbd, 0xb5, 0x2a, 0xe9, 0x44, 0xd6, 0xf6, 0x32, 0x20, 0x47, 0xce, 0x2f, 0xe8, 0x83, 0x59,
		0xc2, 0xb2, 0xe3, 0x29, 0xce, 0xa1, 0xab, 0xf4, 0x75, 0x68, 0x67, 0x14, 0x29, 0x86, 0x3d, 0x68,
		0xde, 0xad, 0x4c, 0x9f, 0x15, 0x05, 0xa6, 0xe3, 0xc3, 0x63, 0x80, 0x63, 0x3c, 0xf5, 0xfd, 0x33,
		0x0c, 0x62, 0x42, 0x0e, 0x2a, 0x2c, 0x1c, 0x72, 0xd3, 0xf5, 0x1b, 0x69, 0xc5, 0x41, 0x70, 0x3d,
		0xaa, 0x93, 0xc1, 0x61, 0x45, 0x4b, 0xc2, 0xfd, 0x5b, 0x0c, 0xea, 0xd7, 0x84, 0x40, 0x88, 0x42,
		0x69, 0x85, 0xed, 0xc9, 0x51, 0x9f, 0xd3, 0x97, 0xd9, 0xe6, 0x86, 0xb3, 0x12, 0x9a, 0x9e, 0x1e,
		0x0d, 0xc9, 0xbb, 0x52, 0x0a, 0xba, 0x52, 0x0d, 0x19, 0x29, 0xb1, 0x65, 0x65, 0x27, 0x74, 0x6c,
		0x9c, 0xde, 0x9a, 0x77, 0x05, 0x90, 0xb2, 0xfd, 0xf4, 0x83, 0x69, 0xc0, 0xe6, 0xb9, 0x87, 0x43,
		0xfb, 0x2c, 0xbc, 0x76, 0xc6, 0x6f, 0x27, 0x4f, 0xc1, 0xf3, 0xf8, 0xa0, 0xfd, 0x44, 0x98, 0x59,
		0x59, 0xfe, 0xc6, 0x46, 0xe2, 0x3e, 0x9a, 0x8a, 0xd3, 0xe9, 0x08, 0xc1, 0x77, 0x39, 0x95, 0x88,
		0x73, 0x32, 0x6d, 0x17, 0x14, 0xfe, 0x1c, 0xe0, 0x83, 0x3e, 0xc7, 0x47, 0xf2, 0x19, 0x5c, 0x5e,
		0x24, 0xd5, 0x54, 0xdd, 0xee, 0xe9, 0xd6, 0xba, 0x7f, 0x1b, 0x3f, 0xb7, 0x92, 0x30, 0x3c, 0xdb,
		0x29, 0x7f, 0x0b, 0x5c, 0xe0, 0xf0, 0x95, 0x19, 0xf6, 0x23, 0xc8, 0xb3, 0xea, 0xf9, 0x76, 0xe4,
		0xc8, 0xf9, 0xc5, 0x17, 0xb5, 0xc2, 0xce, 0xab, 0x63, 0xb2, 0x28, 0x9f, 0x1c, 0x73, 0x63, 0x09,
		0x93, 0x84, 0xb1, 0xcb, 0x46, 0xba, 0x9c, 0xb7, 0x38, 0x36, 0xaf, 0x05, 0xa3, 0x03, 0x1c, 0x55,
		0xfe, 0xc7, 0x54, 0x3d, 0xde, 0xfa, 0x31, 0xec, 0x76, 0x0b, 0x0a, 0x88, 0xd9, 0x1c, 0x73, 0xdf,
		0xfc, 0x7a, 0x2e, 0xdf, 0xc4, 0x99, 0x97, 0xb6, 0xc7, 0x6b, 0x92, 0x79, 0x15, 0xe8, 0x79, 0x0e,
		0xe7, 0x3f, 0xa5, 0x09, 0xdf, 0x5a, 0xd0, 0x5a, 0xb0, 0xe8, 0x6e, 0x58, 0x62, 0x71, 0x89, 0x9a,
		0xee, 0x42, 0xd8, 0x2c, 0x1e, 0x9d, 0xfe, 0xe6, 0x82, 0xec, 0xb1, 0xe8, 0x20, 0x03, 0xaa, 0x37,
		0xfd, 0x88, 0xc5, 0x80, 0xe8, 0xd3, 0x75, 0xac, 0xec, 0x50, 0xe7, 0x35, 0x8e, 0xa6, 0x22, 0xc1,
		0xa7, 0xb9, 0x4e, 0x1e, 0x94, 0x51, 0x59, 0x8e, 0x61, 0x10, 0xd5, 0x7c, 0xd7, 0x4e, 0xc7, 0x22,
		0x53, 0xc7, 0x71, 0x58, 0xf5, 0xd7, 0xc7, 0xc3, 0x60, 0xa1, 0x6a, 0x14, 0xb0, 0x11, 0x13, 0x5e,
		0xf3, 0x5c, 0xe8, 0xd0, 0xca, 0x72, 0xaf, 0x0f, 0x45, 0x9e, 0x15, 0x34, 0x0a, 0x65, 0xdf, 0x6b,
		0x64, 0xc9, 0xdd, 0xb0, 0x28, 0x81, 0xdc, 0x54, 0x7a, 0x6b, 0x68, 0xa4, 0x6e, 0xac, 0xea, 0xb5,
		0x8b, 0xdb, 0xaf, 0x3a, 0xee, 0xd7, 0x99, 0x75, 0xb4, 0x41, 0x2f, 0xe0, 0x25, 0x0b, 0xc6, 0x91,
		0xff, 0xa0, 0x7a, 0x02, 0x0a, 0x96, 0x76, 0x5b, 0xd8, 0x2f, 0x08, 0x0c, 0xc0, 0xc1, 0xa2, 0xd8,
		0x35, 0x78, 0xda, 0x53, 0xd1, 0x5a, 0xe2, 0x89, 0xe0, 0x2c, 0x62, 0xac, 0x76, 0x0c, 0x7f, 0xfa,
		0xe8, 0xe4, 0x1d, 0xbe, 0xb4, 0x9c, 0xf2, 0x2c, 0xa2, 0xf5, 0x11, 0x2f, 0xbe, 0x91, 0x5d, 0xe0,
		0x41, 0xa5, 0x9d, 0x95, 0x3c, 0xed, 0x24, 0x4b, 0x4e, 0x99, 0x2d, 0x78, 0x28, 0xbc, 0x82, 0x0a,
		0x3f, 0x18, 0x90, 0xbf, 0x1c, 0x90, 0x8b, 0x26, 0xe6, 0x7f, 0xdf, 0x57, 0x10, 0xce, 0x0b, 0x84,
		0xaa, 0xde, 0x2a, 0xae, 0xa0, 0xac, 0x8d, 0x69, 0x26, 0x0e, 0xac, 0xee, 0xa7, 0x43, 0x29, 0xc1,
		0x22, 0x84, 0x37, 0xa9, 0x5f, 0x87, 0x8e, 0x12, 0xdf, 0x6b, 0x30, 0xd0, 0x23, 0x93, 0xfc, 0xa2,
		0x06, 0xf6, 0x8b, 0x60, 0xc4, 0x76, 0x1b, 0x78, 0xf8, 0x82, 0x3e, 0x69, 0x5b, 0x75, 0x19, 0x76,
		0xc8, 0x88, 0x0b, 0xa5, 0x3d, 0x3e, 0xa1, 0x1d, 0x73, 0x7f, 0x75, 0x99, 0xb8, 0x6a, 0x0c, 0x00,
		0xfc, 0x06, 0x06, 0x10, 0x8d, 0x27, 0x5c, 0x83, 0xc0, 0x55, 0xeb, 0x22, 0xe1, 0x55, 0x14, 0x3e,
		0xf4, 0x4b, 0x8a, 0xe8, 0xb4, 0x53, 0x78, 0xe2, 0x02, 0x5e, 0x08, 0xe3, 0x96, 0x14, 0x08, 0x90,
		0x23, 0x5c, 0x0d, 0xee, 0x8e, 0xde, 0xc2, 0x08, 0xe9, 0x1c, 0xc5, 0x24, 0x70, 0x72, 0x5e, 0x5f,
		0xa4, 0x12, 0x29, 0x37, 0x54, 0x8c, 0xbd, 0x4a, 0x54, 0x13, 0x2c, 0xf1, 0x2e, 0x4b, 0x6a, 0x05,
		0x6c, 0xa0, 0x62, 0xd1, 0x0c, 0xf2, 0x94, 0x18, 0x0f, 0xca, 0x8f, 0x7a, 0xe4, 0x43, 0x9c, 0x65,
		0x85, 0xea, 0xe4, 0xae, 0x0e, 0x22, 0x13, 0x7b, 0x7e, 0x8d, 0xfb, 0x0b, 0x23, 0x24, 0x61, 0x8d,
		0x23, 0x59, 0xb9, 0x4b, 0x23, 0xdd, 0x80, 0x60, 0x00, 0xa7, 0x6c, 0xb8, 0x8b, 0x9a, 0xce, 0x37,
		0x14, 0x00, 0xa4, 0x31, 0x46, 0x26, 0x58, 0x3a, 0x34, 0xb6, 0xbb, 0xef, 0xd8, 0x27, 0x87, 0xba,
		0x25, 0x29, 0xa4, 0xc6, 0xf9, 0x8a, 0x79, 0x81, 0x8b, 0x98, 0xd4, 0x30, 0xf2, 0x1d, 0xa3, 0xe4,
		0x94, 0x15, 0xfa, 0x08, 0xd0, 0x52, 0x37, 0x3f, 0x5f, 0x59, 0x4e, 0x8b, 0x1a, 0x62, 0x78, 0xd8,
		0x76, 0x1a, 0x00, 0x9c, 0x08, 0x13, 0x0c, 0x05, 0x14, 0x48, 0x5a, 0x39, 0xd9, 0x18, 0x59, 0x50,
		0x5b, 0x52, 0x9e, 0x6d, 0xe3, 0xa2, 0xdc, 0xd4, 0xc0, 0x98, 0xbc, 0x79, 0xce, 0x7e, 0x88, 0x9f,
		0x70, 0xbb, 0x67, 0x9d, 0x6e, 0xa1, 0x5b, 0x71, 0x8a, 0x60, 0xb7, 0xbb, 0x8f, 0x38, 0x7f, 0xb3,
		0x84, 0xe3, 0x55, 0x95, 0x89, 0xd5, 0x8a, 0x44, 0x74, 0x76, 0x7b, 0xe7, 0x59, 0x37, 0x5b, 0x2c,
		0xdf, 0xda, 0xbb, 0x3c, 0x73, 0x45, 0xf7, 0x0f, 0x4d, 0xda, 0x56, 0xa4, 0x9b, 0xdc, 0xaf, 0xa1,
		0xfa, 0x3c, 0x97, 0x57, 0x59, 0xa3, 0x77, 0x4b, 0x4d, 0xc0, 0x9d, 0xe6, 0x20, 0xd2, 0xd0, 0xc0,
		0x14, 0x62, 0x02, 0x3e, 0x7b, 0xc6, 0x91, 0xe1, 0x35, 0xa7, 0x76, 0xac, 0x7f, 0x04, 0x4d, 0x57,
		0xd8, 0x78, 0xd6, 0xbe, 0x72, 0x60, 0x96, 0x33, 0x66, 0x90, 0x12, 0x54, 0x39, 0xdb, 0xb5, 0xe8,
		0x53, 0x07, 0x2f, 0xad, 0x65, 0xfd, 0x58, 0x2a, 0x44, 0xd2, 0x6c, 0x0d, 0xca, 0x3e, 0xa5, 0xbd,
		0xa4, 0x1b, 0x33, 0x07, 0x11, 0x4b, 0x62, 0x77, 0xdf, 0xfa, 0x83, 0xc1, 0xa4, 0x3f, 0xbf, 0xec,
		0xe0, 0x82, 0xed, 0x4a, 0xc4, 0x9f, 0x15, 0x14, 0x63, 0x90, 0x54, 0x15, 0x5a, 0x26, 0x25, 0xc6,
		0x2c, 0x74, 0xd8, 0xf3, 0x70, 0x26, 0xb8, 0x22, 0xef, 0xea, 0x39, 0xb9, 0x20, 0xb3, 0x10, 0x84,
		0x37, 0xa4, 0x30, 0x8c, 0x12, 0x2d, 0x43, 0x3b, 0xbb, 0xf2, 0x79, 0xb6, 0x57, 0x9d, 0x8d, 0x1b,
		0x50, 0xd6, 0x38, 0x16, 0xd8, 0x8e, 0xf7, 0xc4, 0xaa, 0x2b, 0xda, 0x76, 0x2d, 0xce, 0x86, 0x31,
		0x8c, 0x55, 0x1a, 0xe0, 0x5d, 0x9a, 0x4d, 0x73, 0x36, 0x36, 0x60, 0x30, 0x44, 0xda, 0x64, 0x02,
		0xbc, 0x67, 0xbf, 0x22, 0x2c, 0xdf, 0x46, 0xf0, 0x37, 0x0a, 0x34, 0x3f, 0x8c, 0x8e, 0x6a, 0xcd,
		0x1d, 0xa4, 0xf1, 0xa8, 0x1a, 0x99, 0x01, 0xc0, 0x93, 0x6a, 0x47, 0x49, 0x5d, 0x37, 0xbe, 0x67,
		0xb6, 0x15, 0x40, 0x7c, 0xe3, 0x43, 0x5f, 0xe5, 0xfd, 0x09, 0xd4, 0xe1, 0x88, 0xa3, 0x22, 0x9a,
		0x66, 0xbb, 0xf6, 0x92, 0xa7, 0xbe, 0xd8, 0x8d, 0xb6, 0x43, 0xd1, 0xdb, 0x8e, 0xe8, 0x7b, 0x16,
		0x23, 0xee, 0xb7, 0xc5, 0x88, 0x09, 0x44, 0x5b, 0x9a, 0x31, 0x25, 0x30, 0x23, 0x06, 0x09, 0x2a,
		0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x15, 0x31, 0x16, 0x04, 0x14, 0xd3, 0xbf, 0x52, 0xee,
		0xa6, 0x66, 0xf3, 0xb2, 0xa5, 0xf7, 0xfe, 0x5d, 0xe7, 0x1a, 0x28, 0xfc, 0xe7, 0x30, 0xc8, 0xc5,
		0x30, 0x49, 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02,
		0x01, 0x05, 0x00, 0x04, 0x20, 0xef, 0x1a, 0xa6, 0x35, 0x11, 0xaa, 0x97, 0x3b, 0x4b, 0x4e, 0x80,
		0x59, 0x72, 0x35, 0xa6, 0x2f, 0x00, 0xbd, 0x64, 0xab, 0x17, 0x79, 0x23, 0x7a, 0x7f, 0xe4, 0x7c,
		0x08, 0x31, 0x89, 0x2e, 0x62, 0x04, 0x10, 0xf4, 0x83, 0x83, 0x8b, 0x95, 0x85, 0xf7, 0x5f, 0x4d,
		0x11, 0xcc, 0x45, 0xa4, 0xb8, 0xf3, 0x8d, 0x02, 0x02, 0x08, 0x00,
	];

	auto name = format(`\\.\pipe\ae-https-test-%s-%s`,
	                   GetCurrentProcessId(), 0);

	auto acceptor = new NamedPipeAcceptor(name);
	acceptor.listen();
	auto s = new HttpsServer(acceptor);
	(cast(SChannelContext) s.ctx).setIdentityFromPKCS12(testPfxBytes, "test");

	bool gotResponse;
	s.handleRequest = (HttpRequest req, HttpServerConnection conn) {
		auto r = new HttpResponseEx;
		conn.sendResponse(r.serveText("hello-https-pipe"));
		s.close();
	};

	auto client = new HttpsClient(30.seconds, new NamedPipeConnector(name));
	(cast(SChannelContext) client.ctx).setPeerVerify(SSLContext.Verify.none);
	auto req = new HttpRequest;
	req.resource = "/";
	req.headers["Host"] = "localhost";
	client.handleResponse = (HttpResponse resp, string reason) {
		assert(resp !is null, "no response: " ~ reason);
		assert(resp.getContent().toGC() == "hello-https-pipe");
		gotResponse = true;
	};
	client.request(req);

	socketManager.loop();
	assert(gotResponse);
}
