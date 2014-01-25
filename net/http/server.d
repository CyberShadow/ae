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

import std.string;
import std.conv;
import std.datetime;
import std.uri;
import std.exception;

import ae.net.asockets;
import ae.net.ietf.headers;
import ae.net.ietf.headerparse;
import ae.sys.data;
import ae.sys.log;
import ae.utils.text;
import ae.utils.textout;

public import ae.net.http.common;

debug (HTTP) import std.stdio, std.datetime;

final class HttpServer
{
public:
	Logger log;

private:
	ServerSocket conn;
	Duration timeout;

private:
	void onClose()
	{
		if (handleClose)
			handleClose();
	}

	void onAccept(ClientSocket incoming)
	{
		debug (HTTP) writefln("[%s] New connection from %s", Clock.currTime(), incoming.remoteAddress);
		new HttpServerConnection(this, incoming);
	}

public:
	this(Duration timeout = 30.seconds)
	{
		assert(timeout > Duration.zero);
		this.timeout = timeout;

		conn = new ServerSocket();
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
		if (log) log("Shutting down.");
		conn.close();
	}

public:
	/// Callback for when the socket was closed.
	void delegate() handleClose;
	/// Callback for an incoming request.
	void delegate(HttpRequest request, HttpServerConnection conn) handleRequest;
}

final class HttpServerConnection
{
public:
	HttpServer server;
	ClientSocket conn;
	HttpRequest currentRequest;
	Address localAddress, remoteAddress;
	bool persistent;

private:
	Data[] inBuffer;
	sizediff_t expect;
	bool requestProcessing; // user code is asynchronously processing current request

	this(HttpServer server, ClientSocket conn)
	{
		this.server = server;
		this.conn = conn;
		conn.handleReadData = &onNewRequest;
		conn.setIdleTimeout(server.timeout);
		localAddress = conn.localAddress;
		remoteAddress = conn.remoteAddress;
		debug (HTTP) conn.handleDisconnect = &onDisconnect;
	}

	void onNewRequest(ClientSocket sender, Data data)
	{
		try
		{
			debug (HTTP) writefln("[%s] Receiving start of request: \n%s---", Clock.currTime(), cast(string)data.contents);
			inBuffer ~= data;

			string reqLine;
			Headers headers;

			if (!parseHeaders(inBuffer, reqLine, headers))
			{
				debug (HTTP) writefln("[%s] Headers not yet received. Data in buffer:\n%s---", Clock.currTime(), cast(string)inBuffer.joinToHeap());
				return;
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
			debug (HTTP) writefln("[%s] This %s connection %s persistent", Clock.currTime(), currentRequest.protocolVersion, persistent ? "IS" : "is NOT");

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
			debug (HTTP) writefln("[%s] Exception onNewRequest: %s", Clock.currTime(), e);
			sendResponse(null);
		}
	}

	debug (HTTP)
	void onDisconnect(ClientSocket sender, string reason, DisconnectType type)
	{
		writefln("[%s] Disconnect: %s", Clock.currTime(), reason);
	}

	void onContinuation(ClientSocket sender, Data data)
	{
		debug (HTTP) writefln("[%s] Receiving continuation of request: \n%s---", Clock.currTime(), cast(string)data.contents);
		inBuffer ~= data;

		if (!requestProcessing && inBuffer.bytes.length >= expect)
		{
			debug (HTTP) writefln("[%s] %s/%s", Clock.currTime(), inBuffer.bytes.length, expect);
			processRequest(inBuffer.popFront(expect));
		}
	}

	void processRequest(Data[] data)
	{
		currentRequest.data = data;
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

		if ("Accept-Encoding" in currentRequest.headers)
			response.optimizeData(currentRequest.headers["Accept-Encoding"]);
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

		respMessage.put("\r\n");

		conn.send(Data(respMessage.get()));
		if (response && response.data.length)
			conn.send(response.data);

		debug (HTTP) writefln("[%s] Sent response (%d bytes headers, %d bytes data)",
			Clock.currTime(), respMessage.length, response ? response.data.bytes.length : 0);

		if (persistent)
		{
			// reset for next request
			conn.handleReadData = &onNewRequest;
			if (inBuffer.length) // a second request has been pipelined
				onNewRequest(conn, Data());
		}
		else
			conn.disconnect();

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
	ClientSocket c = new ClientSocket;
	c.handleConnect = (ClientSocket sender) {
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
}
