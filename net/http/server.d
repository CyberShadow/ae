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

	this()
	{
		ctx = ssl.createContext(SSLContext.Kind.server);
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
