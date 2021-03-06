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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.net.http.server;

import std.conv;
import std.datetime;
import std.exception;
import std.range;
import std.socket;
import std.string;
import std.uri;

import ae.net.asockets;
import ae.net.ietf.headerparse;
import ae.net.ietf.headers;
import ae.net.ssl;
import ae.sys.data;
import ae.sys.log;
import ae.utils.container.listnode;
import ae.utils.exception;
import ae.utils.text;
import ae.utils.textout;

public import ae.net.http.common;

debug(HTTP) import std.stdio : stderr;

class BaseHttpServerConnection
{
public:
	TimeoutAdapter timer;
	IConnection conn;

	HttpRequest currentRequest;
	bool persistent;

	bool connected = true;
	Logger log;

	void delegate(HttpRequest request) handleRequest;

protected:
	Data[] inBuffer;
	sizediff_t expect;
	size_t responseSize;
	bool requestProcessing; // user code is asynchronously processing current request
	Duration timeout = HttpServer.defaultTimeout;
	bool timeoutActive;
	string banner;

	this(IConnection c)
	{
		debug (HTTP) debugLog("New connection from %s", remoteAddressStr(null));

		timer = new TimeoutAdapter(c);
		timer.setIdleTimeout(timeout);
		c = timer;

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
				debug (HTTP) debugLog("Headers not yet received. Data in buffer:\n%s---", cast(string)inBuffer.joinToHeap());
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

			expect = 0;
			if ("Content-Length" in currentRequest.headers)
				expect = to!size_t(currentRequest.headers["Content-Length"]);

			if (expect > 0)
			{
				if (expect > inBuffer.bytes.length)
					conn.handleReadData = &onContinuation;
				else
					processRequest(inBuffer.popFront(expect));
			}
			else
				processRequest(null);
		}
		catch (CaughtException e)
		{
			debug (HTTP) debugLog("Exception onNewRequest: %s", e);
			HttpResponse response;
			debug
			{
				response = new HttpResponse();
				response.status = HttpStatusCode.InternalServerError;
				response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.InternalServerError);
				response.headers["Content-Type"] = "text/plain";
				response.data = [Data(e.toString())];
			}
			sendResponse(response);
		}
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		debug (HTTP) debugLog("Disconnect: %s", reason);
		connected = false;
	}

	final void onContinuation(Data data)
	{
		debug (HTTP) debugLog("Receiving continuation of request: \n%s---", cast(string)data.contents);
		inBuffer ~= data;

		if (!requestProcessing && inBuffer.bytes.length >= expect)
		{
			debug (HTTP) debugLog("%s/%s", inBuffer.bytes.length, expect);
			processRequest(inBuffer.popFront(expect));
		}
	}

	final void processRequest(Data[] data)
	{
		debug (HTTP) debugLog("processRequest (%d bytes)", data.bytes.length);
		currentRequest.data = data;
		timeoutActive = false;
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

	final @property bool idle()
	{
		if (requestProcessing)
			return false;
		foreach (datum; inBuffer)
			if (datum.length)
				return false;
		return true;
	}

public:
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
		conn.send(Data(respMessage.get()));
	}

	final void sendHeaders(HttpResponse response)
	{
		sendHeaders(response.headers, response.status, response.statusMessage);
	}

	final void sendResponse(HttpResponse response)
	{
		assert(response.status != 0);

		requestProcessing = false;
		if (!response)
		{
			debug (HTTP) debugLog("sendResponse(null) - generating dummy response");
			response = new HttpResponse();
			response.status = HttpStatusCode.InternalServerError;
			response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.InternalServerError);
			response.data = [Data("Internal Server Error")];
		}

		if (currentRequest)
		{
			response.optimizeData(currentRequest.headers);
			response.sliceData(currentRequest.headers);
		}

		if ("Content-Length" !in response.headers)
			response.headers["Content-Length"] = text(response.data.bytes.length);

		sendHeaders(response);

		bool isHead = currentRequest ? currentRequest.method == "HEAD" : false;
		if (response && response.data.length && !isHead)
			sendData(response.data);

		responseSize = response ? response.data.bytes.length : 0;
		debug (HTTP) debugLog("Sent response (%d bytes data)", responseSize);

		closeResponse();

		logRequest(currentRequest, response);
	}

	final void sendData(Data[] data)
	{
		conn.send(data);
	}

	/// Accept more requests on the same connection?
	bool acceptMore() { return true; }

	final void closeResponse()
	{
		if (persistent && acceptMore)
		{
			// reset for next request
			debug (HTTP) debugLog("  Waiting for next request.");
			conn.handleReadData = &onNewRequest;
			if (!timeoutActive)
			{
				// Give the client time to download large requests.
				// Assume a minimal speed of 1kb/s.
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

	abstract @property string remoteAddressStr(HttpRequest r);
}

class HttpServer
{
	enum defaultTimeout = 30.seconds;
public:
	this(Duration timeout = defaultTimeout)
	{
		assert(timeout > Duration.zero);
		this.timeout = timeout;

		conn = new TcpServer();
		conn.handleClose = &onClose;
		conn.handleAccept = &onAccept;
	}

	ushort listen(ushort port, string addr = null)
	{
		port = conn.listen(port, addr);
		if (log)
			foreach (address; conn.localAddresses)
				log("Listening on " ~ formatAddress(protocol, address) ~ " [" ~ to!string(address.addressFamily) ~ "]");
		return port;
	}

	void listen(AddressInfo[] addresses)
	{
		conn.listen(addresses);
		if (log)
			foreach (address; conn.localAddresses)
				log("Listening on " ~ formatAddress(protocol, address) ~ " [" ~ to!string(address.addressFamily) ~ "]");
	}

	void close()
	{
		debug(HTTP) stderr.writeln("Shutting down");
		if (log) log("Shutting down.");
		conn.close();

		debug(HTTP) stderr.writefln("There still are %d active connections", connections.iterator.walkLength);

		// Close idle connections
		foreach (connection; connections.iterator.array)
			if (connection.idle && connection.conn.state == ConnectionState.connected)
				connection.conn.disconnect("HTTP server shutting down");
	}

	Logger log;

	/// Single-ended doubly-linked list of active connections
	SEDListContainer!HttpServerConnection connections;

	/// Callback for when the socket was closed.
	void delegate() handleClose;
	/// Callback for an incoming request.
	void delegate(HttpRequest request, HttpServerConnection conn) handleRequest;

	string banner = "ae.net.http.server (+https://github.com/CyberShadow/ae)";
	string remoteIPHeader; // For reverse proxies

protected:
	TcpServer conn;
	Duration timeout;

	void onClose()
	{
		if (handleClose)
			handleClose();
	}

	IConnection createConnection(TcpConnection tcp)
	{
		return tcp;
	}

	@property string protocol() { return "http"; }

	void onAccept(TcpConnection incoming)
	{
		try
			new HttpServerConnection(this, incoming, createConnection(incoming), protocol);
		catch (Exception e)
		{
			if (log)
				log("Error accepting connection: " ~ e.msg);
			if (incoming.state == ConnectionState.connected)
				incoming.disconnect();
		}
	}
}

/// HTTPS server. Set SSL parameters on ctx after instantiation.
/// Example:
/// ---
///	auto s = new HttpsServer();
///	s.ctx.enableDH(4096);
///	s.ctx.enableECDH();
///	s.ctx.setCertificate("server.crt");
///	s.ctx.setPrivateKey("server.key");
/// ---
class HttpsServer : HttpServer
{
	SSLContext ctx;

	this()
	{
		ctx = ssl.createContext(SSLContext.Kind.server);
	}

protected:
	override @property string protocol() { return "https"; }

	override IConnection createConnection(TcpConnection tcp)
	{
		return ssl.createAdapter(ctx, tcp);
	}
}

final class HttpServerConnection : BaseHttpServerConnection
{
	TcpConnection tcp;
	HttpServer server;
	Address localAddress, remoteAddress;

	mixin DListLink;

	override @property string remoteAddressStr(HttpRequest r)
	{
		if (server.remoteIPHeader)
		{
			if (r)
				if (auto p = server.remoteIPHeader in r.headers)
					return (*p).split(",")[$ - 1];

			return "[local:" ~ remoteAddress.toAddrString() ~ "]";
		}

		return remoteAddress.toAddrString();
	}

protected:
	string protocol;

	this(HttpServer server, TcpConnection tcp, IConnection c, string protocol = "http")
	{
		this.server = server;
		this.tcp = tcp;
		this.log = server.log;
		this.protocol = protocol;
		this.banner = server.banner;
		this.timeout = server.timeout;
		this.handleRequest = (HttpRequest r) => server.handleRequest(r, this);
		this.localAddress = tcp.localAddress;
		this.remoteAddress = tcp.remoteAddress;

		super(c);

		server.connections.pushFront(this);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		server.connections.remove(this);
	}

	override bool acceptMore() { return server.conn.isListening; }
	override string formatLocalAddress(HttpRequest r) { return formatAddress(protocol, localAddress, r.host, r.port); }
}

version (Posix)
final class FileHttpServerConnection : BaseHttpServerConnection
{
	this(File input = stdin, File output = stdout, string protocol = "stdin")
	{
		this.protocol = protocol;

		auto c = new Duplex(
			new FileConnection(input.fileno),
			new FileConnection(output.fileno),
		);

		super(c);
	}

	override @property string remoteAddressStr(HttpRequest r) { return "-"; }

protected:
	import std.stdio : File, stdin, stdout;

	string protocol;

	override string formatLocalAddress(HttpRequest r) { return protocol ~ "://"; }
}

string formatAddress(string protocol, Address address, string vhost = null, ushort logPort = 0)
{
	string addr = address.toAddrString();
	string port =
		address.addressFamily == AddressFamily.UNIX ? null :
		logPort ? text(logPort) :
		address.toPortString();
	return protocol ~ "://" ~
		(vhost ? vhost : addr == "0.0.0.0" || addr == "::" ? "*" : addr.contains(":") ? "[" ~ addr ~ "]" : addr) ~
		(port is null || port == "80" ? "" : ":" ~ port);
}

version (unittest) import ae.net.http.client;
version (unittest) import ae.net.http.responseex;
unittest
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
		c.send(Data(
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

b=7654321"));
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
		c.send(Data("\n\n\n\n\n"));
		c.disconnect();

		// Now send a valid request to end the loop
		c = new TcpConnection;
		c.handleConnect = {
			c.send(Data("GET / HTTP/1.0\n\n"));
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
