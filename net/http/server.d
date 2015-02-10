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
import std.string;
import std.uri;

import ae.net.asockets;
import ae.net.ietf.headerparse;
import ae.net.ietf.headers;
import ae.sys.data;
import ae.sys.log;
import ae.utils.container.listnode;
import ae.utils.text;
import ae.utils.textout;

public import ae.net.http.common;

debug(HTTP) import std.stdio : stderr;

final class HttpServer
{
public:
	Logger log;

private:
	TcpServer conn;
	Duration timeout;

private:
	void onClose()
	{
		if (handleClose)
			handleClose();
	}

	void onAccept(TcpConnection incoming)
	{
		new HttpServerConnection(this, incoming);
	}

public:
	this(Duration timeout = 30.seconds)
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
				log("Listening on " ~ formatAddress(address) ~ " [" ~ to!string(address.addressFamily) ~ "]");
		return port;
	}

	void close()
	{
		debug(HTTP) stderr.writeln("Shutting down");
		if (log) log("Shutting down.");
		conn.close();

		debug(HTTP) stderr.writefln("There still are %d active connections", connections.iterator.walkLength);

		// Close idle connections
		foreach (connection; connections.iterator.array)
			if (connection.idle && connection.conn.connected && !connection.conn.disconnecting)
				connection.conn.disconnect("HTTP server shutting down");
	}

public:
	/// Single-ended doubly-linked list of active connections
	SEDListContainer!HttpServerConnection connections;

	/// Callback for when the socket was closed.
	void delegate() handleClose;
	/// Callback for an incoming request.
	void delegate(HttpRequest request, HttpServerConnection conn) handleRequest;
}

final class HttpServerConnection
{
public:
	TcpConnection tcp;
	TimeoutAdapter timer;
	IConnection conn;

	HttpServer server;
	HttpRequest currentRequest;
	Address localAddress, remoteAddress;
	bool persistent;

	mixin DListLink;

private:
	Data[] inBuffer;
	sizediff_t expect;
	bool requestProcessing; // user code is asynchronously processing current request
	bool timeoutActive;

	this(HttpServer server, TcpConnection incoming)
	{
		debug (HTTP) debugLog("New connection from %s", incoming.remoteAddress);
		this.server = server;
		IConnection c = tcp = incoming;

		timer = new TimeoutAdapter(c);
		timer.setIdleTimeout(server.timeout);
		c = timer;

		this.conn = c;
		conn.handleReadData = &onNewRequest;
		conn.handleDisconnect = &onDisconnect;

		timeoutActive = true;
		localAddress = tcp.localAddress;
		remoteAddress = tcp.remoteAddress;
		server.connections.pushFront(this);
	}

	debug (HTTP)
	final void debugLog(Args...)(Args args)
	{
		stderr.writef("[%s %s] ", Clock.currTime(), cast(void*)this);
		stderr.writefln(args);
	}

	void onNewRequest(Data data)
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
		catch (Exception e)
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
		server.connections.remove(this);
	}

	void onContinuation(Data data)
	{
		debug (HTTP) debugLog("Receiving continuation of request: \n%s---", cast(string)data.contents);
		inBuffer ~= data;

		if (!requestProcessing && inBuffer.bytes.length >= expect)
		{
			debug (HTTP) debugLog("%s/%s", inBuffer.bytes.length, expect);
			processRequest(inBuffer.popFront(expect));
		}
	}

	void processRequest(Data[] data)
	{
		currentRequest.data = data;
		timeoutActive = false;
		timer.cancelIdleTimeout();
		if (server.handleRequest)
		{
			// Log unhandled exceptions, but don't mess up the stack trace
			//scope(failure) logRequest(currentRequest, null);

			// sendResponse may be called immediately, or later
			requestProcessing = true;
			server.handleRequest(currentRequest, this);
		}
	}

	void logRequest(HttpRequest request, HttpResponse response)
	{
		debug // avoid linewrap in terminal during development
			enum DEBUG = true;
		else
			enum DEBUG = false;

		if (server.log) server.log(([
			"", // align IP to tab
			request.remoteHosts(remoteAddress.toAddrString())[0],
			response ? text(response.status) : "-",
			format("%9.2f ms", request.age.total!"usecs" / 1000f),
			request.method,
			formatAddress(localAddress, request.host) ~ request.resource,
			response ? response.headers.get("Content-Type", "-") : "-",
		] ~ (DEBUG ? [] : [
			request.headers.get("Referer", "-"),
			request.headers.get("User-Agent", "-"),
		])).join("\t"));
	}

	@property bool idle()
	{
		if (requestProcessing)
			return false;
		foreach (datum; inBuffer)
			if (datum.length)
				return false;
		return true;
	}

public:
	void sendResponse(HttpResponse response)
	{
		requestProcessing = false;
		StringBuilder respMessage;
		respMessage.put("HTTP/", currentRequest.protocolVersion, " ");
		if (!response)
		{
			response = new HttpResponse();
			response.status = HttpStatusCode.InternalServerError;
			response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.InternalServerError);
			response.data = [Data("Internal Server Error")];
		}

		response.optimizeData(currentRequest.headers);
		response.sliceData(currentRequest.headers);
		response.headers["Content-Length"] = response ? to!string(response.data.bytes.length) : "0";
		response.headers["X-Powered-By"] = "ae.net.http.server (+https://github.com/CyberShadow/ae)";
		response.headers["Date"] = httpTime(Clock.currTime());
		if (persistent && currentRequest.protocolVersion=="1.0")
			response.headers["Connection"] = "Keep-Alive";
		else
		if (!persistent && currentRequest.protocolVersion=="1.1")
			response.headers["Connection"] = "close";

		respMessage.put(to!string(response.status), " ", response.statusMessage, "\r\n");
		foreach (string header, string value; response.headers)
			respMessage.put(header, ": ", value, "\r\n");

		debug (HTTP) debugLog("Response headers:\n> %s", respMessage.get().chomp().replace("\r\n", "\n> "));

		respMessage.put("\r\n");

		conn.send(Data(respMessage.get()));
		if (response && response.data.length && currentRequest.method != "HEAD")
			conn.send(response.data);

		debug (HTTP) debugLog("Sent response (%d bytes headers, %d bytes data)",
			respMessage.length, response ? response.data.bytes.length : 0);

		if (persistent && server.conn.isListening)
		{
			// reset for next request
			debug (HTTP) debugLog("  Waiting for next request.");
			conn.handleReadData = &onNewRequest;
			if (!timeoutActive)
			{
				timer.resumeIdleTimeout();
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

		logRequest(currentRequest, response);
	}
}

string formatAddress(Address address, string vhost = null)
{
	string addr = address.toAddrString();
	string port = address.toPortString();
	return "http://" ~
		(vhost ? vhost : addr == "0.0.0.0" || addr == "::" ? "*" : addr.contains(":") ? "[" ~ addr ~ "]" : addr) ~
		(port == "80" ? "" : ":" ~ port);
}

unittest
{
	import ae.net.http.client;
	import ae.net.http.responseex;

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
	auto port = s.listen(0, "localhost");
	httpPost("http://localhost:" ~ to!string(port) ~ "/?" ~ encodeUrlParameters(["a":"2"]), ["b":"3"], (string s) { assert(s=="5"); }, null);
	socketManager.loop();

	// Test pipelining, protocol errors
	replies = null;
	closeAfter = 2;
	port = s.listen(0, "localhost");
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
	c.connect("localhost", port);

	socketManager.loop();

	assert(replies == [777777, 8888888]);

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
		port = s.listen(0, "localhost");
		closeAfter = 1;
		httpGet("http://localhost:" ~ to!string(port) ~ "/" ~ fn, (string s) { assert(s=="42"); }, null);
		socketManager.loop();
		std.file.remove(fn);
	}

	testFile("http-test.bin");
	testFile("http-test.txt");
+/
}
