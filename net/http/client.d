/**
 * A simple HTTP client.
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
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.http.client;

import std.string;
import std.conv;
import std.datetime;
import std.uri;
import std.utf;

import ae.net.asockets;
import ae.net.ietf.headers;
import ae.net.ietf.headerparse;
import ae.net.ietf.url;
import ae.net.ssl;
import ae.utils.array : toArray;
import ae.utils.exception : CaughtException;
import ae.sys.data;
debug(HTTP) import std.stdio : stderr;

public import ae.net.http.common;

class HttpClient
{
private:
	TcpConnection tcp;    // Bottom-level transport. Reused for new connections.
	TimeoutAdapter timer; // Timeout adapter.
	IConnection conn;     // Top-level abstract connection.

	Data[] inBuffer;

protected:
	HttpRequest currentRequest;

	HttpResponse currentResponse;
	size_t expect;

	void onConnect()
	{
		sendRequest(currentRequest);
	}

	void sendRequest(HttpRequest request)
	{
		if ("User-Agent" !in request.headers && agent)
			request.headers["User-Agent"] = agent;
		if (!compat) {
			if ("Accept-Encoding" !in request.headers)
				request.headers["Accept-Encoding"] = "gzip, deflate, *;q=0";
			if (request.data)
				request.headers["Content-Length"] = to!string(request.data.bytes.length);
		} else {
			if ("Pragma" !in request.headers)
				request.headers["Pragma"] = "No-Cache";
		}
		if ("Connection" !in request.headers)
			request.headers["Connection"] = keepAlive ? "keep-alive" : "close";

		sendRawRequest(request);
	}

	void sendRawRequest(HttpRequest request)
	{
		string reqMessage = request.method ~ " ";
		if (request.proxy !is null) {
			reqMessage ~= "http://" ~ request.host;
			if (compat || request.port != 80)
				reqMessage ~= format(":%d", request.port);
		}
		reqMessage ~= request.resource ~ " HTTP/1.0\r\n";

		foreach (string header, string value; request.headers)
			if (value !is null)
				reqMessage ~= header ~ ": " ~ value ~ "\r\n";

		reqMessage ~= "\r\n";
		debug(HTTP)
		{
			stderr.writefln("Sending request:");
			foreach (line; reqMessage.split("\r\n"))
				stderr.writeln("> ", line);
			if (request.data)
				stderr.writefln("} (%d bytes data follow)", request.data.bytes.length);
		}

		conn.send(Data(reqMessage));
		conn.send(request.data);
	}

	void onNewResponse(Data data)
	{
		try
		{
			inBuffer ~= data;
			timer.markNonIdle();

			string statusLine;
			Headers headers;

			debug(HTTP) auto oldData = inBuffer.dup;

			if (!parseHeaders(inBuffer, statusLine, headers))
				return;

			debug(HTTP)
			{
				stderr.writefln("Got response:");
				auto reqMessage = cast(string)oldData.bytes[0..oldData.bytes.length-inBuffer.bytes.length].joinToHeap();
				foreach (line; reqMessage.split("\r\n"))
					stderr.writeln("< ", line);
			}

			currentResponse = new HttpResponse;
			currentResponse.parseStatusLine(statusLine);
			currentResponse.headers = headers;

			onHeadersReceived();
		}
		catch (CaughtException e)
		{
			if (conn.state == ConnectionState.connected)
				conn.disconnect(e.msg.length ? e.msg : e.classinfo.name, DisconnectType.error);
			else
				throw new Exception("Unhandled exception after connection was closed", e);
		}
	}

	void onHeadersReceived()
	{
		expect = size_t.max;
		if ("Content-Length" in currentResponse.headers)
			expect = to!size_t(strip(currentResponse.headers["Content-Length"]));

		if (inBuffer.bytes.length < expect)
		{
			onData(inBuffer);
			conn.handleReadData = &onContinuation;
		}
		else
		{
			onData(inBuffer.bytes[0 .. expect]); // TODO: pipelining
			onDone();
		}

		inBuffer.destroy();
	}

	void onData(Data[] data)
	{
		currentResponse.data ~= data;
	}

	void onContinuation(Data data)
	{
		onData(data.toArray);
		timer.markNonIdle();

		auto received = currentResponse.data.bytes.length;
		if (expect!=size_t.max && received >= expect)
		{
			inBuffer = currentResponse.data.bytes[expect..received];
			currentResponse.data = currentResponse.data.bytes[0..expect];
			onDone();
		}
	}

	void onDone()
	{
		if (keepAlive)
			processResponse();
		else
			conn.disconnect("All data read");
	}

	void processResponse(string reason = "All data read")
	{
		auto response = currentResponse;

		currentRequest = null;
		currentResponse = null;
		expect = -1;
		conn.handleReadData = null;

		if (handleResponse)
			handleResponse(response, reason);
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		if (type == DisconnectType.error)
			currentResponse = null;

		if (currentRequest)
			processResponse(reason);
	}

	IConnection adaptConnection(IConnection conn)
	{
		return conn;
	}

public:
	string agent = "ae.net.http.client (+https://github.com/CyberShadow/ae)";
	bool compat = false;
	bool keepAlive = false;
	string[] cookies;

public:
	this(Duration timeout = 30.seconds)
	{
		assert(timeout > Duration.zero);

		IConnection c = tcp = new TcpConnection;

		c = adaptConnection(c);

		timer = new TimeoutAdapter(c);
		timer.setIdleTimeout(timeout);
		c = timer;

		conn = c;
		conn.handleConnect = &onConnect;
		conn.handleDisconnect = &onDisconnect;
	}

	void request(HttpRequest request)
	{
		//debug writefln("New HTTP request: %s", request.url);
		currentRequest = request;
		currentResponse = null;
		conn.handleReadData = &onNewResponse;
		expect = 0;

		if (conn.state != ConnectionState.disconnected)
		{
			assert(conn.state == ConnectionState.connected, "Attempting a HTTP request on a %s connection".format(conn.state));
			assert(keepAlive, "Attempting a second HTTP request on a connected non-keepalive connection");
			sendRequest(request);
		}
		else
		{
			if (request.proxy !is null)
				tcp.connect(request.proxyHost, request.proxyPort);
			else
				tcp.connect(request.host, request.port);
		}
	}

	bool connected()
	{
		if (currentRequest !is null)
			return true;
		if (keepAlive && conn.state == ConnectionState.connected)
			return true;
		return false;
	}

	void disconnect(string reason = IConnection.defaultDisconnectReason)
	{
		conn.disconnect(reason);
	}

public:
	// Provide the following callbacks
	void delegate(HttpResponse response, string disconnectReason) handleResponse;
}

class HttpsClient : HttpClient
{
	SSLContext ctx;
	SSLAdapter adapter;

	this(Duration timeout = 30.seconds)
	{
		ctx = ssl.createContext(SSLContext.Kind.client);
		super(timeout);
	}

	override IConnection adaptConnection(IConnection conn)
	{
		adapter = ssl.createAdapter(ctx, conn);
		return adapter;
	}

	override void request(HttpRequest request)
	{
		super.request(request);
		adapter.setHostName(request.host);
	}
}

/// Asynchronous HTTP request
void httpRequest(HttpRequest request, void delegate(HttpResponse response, string disconnectReason) responseHandler)
{
	HttpClient client;
	if (request.protocol == "https")
		client = new HttpsClient;
	else
		client = new HttpClient;

	client.handleResponse = responseHandler;
	client.request(request);
}

/// ditto
void httpRequest(HttpRequest request, void delegate(Data) resultHandler, void delegate(string) errorHandler, int redirectCount = 0)
{
	void responseHandler(HttpResponse response, string disconnectReason)
	{
		if (!response)
			if (errorHandler)
				errorHandler(disconnectReason);
			else
				throw new Exception(disconnectReason);
		else
		if (response.status >= 300 && response.status < 400 && "Location" in response.headers)
		{
			if (redirectCount == 15)
				throw new Exception("HTTP redirect loop: " ~ request.url);
			request.resource = applyRelativeURL(request.url, response.headers["Location"]);
			if (response.status == HttpStatusCode.SeeOther)
			{
				request.method = "GET";
				request.data = null;
			}
			httpRequest(request, resultHandler, errorHandler, redirectCount+1);
		}
		else
			if (errorHandler)
				try
					resultHandler(response.getContent());
				catch (Exception e)
					errorHandler(e.msg);
			else
				resultHandler(response.getContent());
	}

	httpRequest(request, &responseHandler);
}

/// ditto
void httpGet(string url, void delegate(Data) resultHandler, void delegate(string) errorHandler)
{
	auto request = new HttpRequest;
	request.resource = url;
	httpRequest(request, resultHandler, errorHandler);
}

/// ditto
void httpGet(string url, void delegate(string) resultHandler, void delegate(string) errorHandler)
{
	httpGet(url,
		(Data data)
		{
			auto result = (cast(char[])data.contents).idup;
			std.utf.validate(result);
			resultHandler(result);
		},
		errorHandler);
}

/// ditto
void httpPost(string url, Data[] postData, string contentType, void delegate(string) resultHandler, void delegate(string) errorHandler)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.method = "POST";
	request.headers["Content-Type"] = contentType;
	request.data = postData;
	httpRequest(request,
		(Data data)
		{
			auto result = (cast(char[])data.contents).idup;
			std.utf.validate(result);
			resultHandler(result);
		},
		errorHandler);
}

/// ditto
void httpPost(string url, UrlParameters vars, void delegate(string) resultHandler, void delegate(string) errorHandler)
{
	return httpPost(url, [Data(encodeUrlParameters(vars))], "application/x-www-form-urlencoded", resultHandler, errorHandler);
}

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
version (unittest)
{
	static import ae.net.http.server;
	static import ae.net.http.responseex;
}

unittest
{
	import ae.net.http.server;
	import ae.net.http.responseex;

	void test(bool keepAlive)
	{
		auto s = new HttpServer;
		s.handleRequest = (HttpRequest request, HttpServerConnection conn) {
			auto response = new HttpResponseEx;
			conn.sendResponse(response.serveText("Hello!"));
		};
		auto port = s.listen(0, "127.0.0.1");

		auto c = new HttpClient;
		c.keepAlive = keepAlive;
		auto r = new HttpRequest("http://127.0.0.1:" ~ to!string(port));
		int count;
		c.handleResponse =
			(HttpResponse response, string disconnectReason)
			{
				assert(response, "HTTP server error");
				assert(cast(string)response.getContent.toHeap == "Hello!");
				if (++count == 5)
				{
					s.close();
					if (c.connected)
						c.disconnect();
				}
				else
					c.request(r);
			};
		c.request(r);

		socketManager.loop();

		assert(count == 5);
	}

	test(false);
	test(true);
}
