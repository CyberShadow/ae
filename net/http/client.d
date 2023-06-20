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
 *   Vladimir Panteleev <ae@cy.md>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.http.client;

import std.algorithm.comparison : among;
import std.algorithm.mutation : move, swap;
import std.exception : enforce;
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
import ae.sys.dataset : DataVec, bytes, joinToHeap;
import ae.utils.array : toArray, shift;
import ae.utils.exception : CaughtException;
import ae.sys.data;

debug(HTTP_CLIENT) debug = HTTP;
debug(HTTP) import std.stdio : stderr;

public import ae.net.http.common;

/// Implements a HTTP client connection to a single server.
class HttpClient
{
protected:
	Connector connector;  // Bottom-level transport factory.
	TimeoutAdapter timer; // Timeout adapter.
	IConnection conn;     // Top-level abstract connection. Reused for new connections.

	HttpRequest[] requestQueue; // Requests that have been enqueued to send after the connection is established.

	HttpResponse currentResponse; // Response to the currently-processed request.
	ulong sentRequests, receivedResponses; // Used to know when we're still waiting for something.
										   // sentRequests is incremented when requestQueue is shifted.

	DataVec headerBuffer; // Received but un-parsed headers
	size_t expect;    // How much data do we expect to receive in the current request (size_t.max if until disconnect)

	/// Connect to a request's destination.
	void connect(HttpRequest request)
	{
		assert(conn.state == ConnectionState.disconnected);

		// We must install a data read handler to indicate that we want to receive readable events.
		// Though, this isn't going to be actually called.
		// TODO: this should probably be fixed in OpenSSLAdapter instead.
		conn.handleReadData = (Data _/*data*/) { assert(false); };

		if (request.proxy !is null)
			connector.connect(request.proxyHost, request.proxyPort);
		else
			connector.connect(request.host, request.port);
		assert(conn.state.among(ConnectionState.connecting, ConnectionState.disconnected));
	}

	/// Pop off a request from the queue and return it, while incrementing `sentRequests`.
	final HttpRequest getNextRequest()
	{
		assert(requestQueue.length);
		sentRequests++;
		return requestQueue.shift();
	}

	/// Called when the underlying connection (TCP, TLS...) is established.
	void onConnect()
	{
		onIdle();
	}

	/// Called when we're ready to send a request.
	void onIdle()
	{
		assert(isIdle);

		if (pipelining)
		{
			assert(keepAlive, "keepAlive is required for pipelining");
			// Pipeline all queued requests
			while (requestQueue.length)
				sendRequest(getNextRequest());
		}
		else
		{
			// One request at a time
			if (requestQueue.length)
				sendRequest(getNextRequest());
		}

		expectResponse();
	}

	/// Returns true when we are connected but not waiting for anything.
	/// Requests can always be sent immediately when this is true.
	bool isIdle()
	{
		if (conn.state == ConnectionState.connected && sentRequests == receivedResponses)
		{
			assert(!currentResponse);
			return true;
		}
		return false;
	}

	/// Encode and send a request (headers and body) to the connection.
	/// Has no other side effects.
	void sendRequest(HttpRequest request)
	{
		string reqMessage = request.method ~ " ";
		if (request.proxy !is null) {
			reqMessage ~= "http://" ~ request.host;
			if (request.port != 80)
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
		conn.send(request.data[]);
	}

	/// Called to set up the client to be ready to receive a response.
	void expectResponse()
	{
		//assert(conn.handleReadData is null);
		if (receivedResponses < sentRequests)
		{
			conn.handleReadData = &onNewResponse;
			expect = 0;
		}
	}

	/// Received data handler used while we are receiving headers.
	void onNewResponse(Data data)
	{
		if (timer)
			timer.markNonIdle();

		onHeaderData(data.toArray);
	}

	/// Called when we've received some data from the response headers.
	void onHeaderData(scope Data[] data)
	{
		try
		{
			headerBuffer ~= data;

			string statusLine;
			Headers headers;

			debug(HTTP) auto oldData = headerBuffer.dup;

			if (!parseHeaders(headerBuffer, statusLine, headers))
				return;

			debug(HTTP)
			{
				stderr.writefln("Got response:");
				auto reqMessage = cast(string)oldData.bytes[0..oldData.bytes.length-headerBuffer.bytes.length].joinToHeap();
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
				throw new Exception("Unhandled exception after connection was closed: " ~ e.msg, e);
		}
	}

	/// Called when we've read all headers (currentResponse.headers is populated).
	void onHeadersReceived()
	{
		expect = size_t.max;
		// TODO: HEAD responses have Content-Length but no data!
		// We need to save a copy of the request (or at least the method) for that...
		if ("Content-Length" in currentResponse.headers)
			expect = currentResponse.headers["Content-Length"].strip().to!size_t();

		conn.handleReadData = &onContinuation;

		// Any remaining data in headerBuffer is now part of the response body
		// (and maybe even the headers of the next pipelined response).
		auto rest = move(headerBuffer);
		onData(rest[]);
	}

	/// Received data handler used while we are receiving the response body.
	void onContinuation(Data data)
	{
		if (timer)
			timer.markNonIdle();
		onData(data.toArray);
	}

	/// Called when we've received some data from the response body.
	void onData(scope Data[] data)
	{
		assert(!headerBuffer.length);

		currentResponse.data ~= data;

		auto received = currentResponse.data.bytes.length;
		if (expect != size_t.max && received >= expect)
		{
			// Any data past expect is part of the next response
			auto rest = currentResponse.data.bytes[expect .. received];
			currentResponse.data = currentResponse.data.bytes[0 .. expect];
			onDone(rest[], null, false);
		}
	}

	/// Called when we've read the entirety of the response.
	/// Any left-over data is in `rest`.
	/// `disconnectReason` is `null` if there was no disconnect.
	void onDone(scope Data[] rest, string disconnectReason, bool error)
	{
		auto response = finalizeResponse();
		if (error)
			response = null; // Discard partial response

		if (disconnectReason)
		{
			assert(rest is null);
		}
		else
		{
			if (keepAlive)
			{
				if (isIdle())
					onIdle();
				else
					expectResponse();
			}
			else
			{
				enforce(rest.bytes.length == 0, "Left-over data after non-keepalive response");
				conn.disconnect("All data read");
			}
		}

		// This is done as the (almost) last step, so that we don't
		// have to worry about the user response handler changing our
		// state while we are in the middle of a function.
		submitResponse(response, disconnectReason);

		// We still have to handle any left-over data as the last
		// step, because otherwise recursion will cause us to call the
		// handleResponse functions in the wrong order.
		if (rest.bytes.length)
			onHeaderData(rest);
	}

	/// Wrap up and return the current response,
	/// and clean up the client for another request.
	HttpResponse finalizeResponse()
	{
		auto response = currentResponse;
		currentResponse = null;
		expect = -1;

		if (!response || response.status != HttpStatusCode.Continue)
			receivedResponses++;

		conn.handleReadData = null;

		return response;
	}

	/// Submit a received response.
	void submitResponse(HttpResponse response, string reason)
	{
		if (!reason)
			reason = "All data read";
		if (handleResponse)
			handleResponse(response, reason);
	}

	/// Disconnect handler
	void onDisconnect(string reason, DisconnectType type)
	{
		// If an error occurred, drain the entire queue, otherwise we
		// will retry indefinitely.  Retrying is not our responsibility.
		if (type == DisconnectType.error)
			while (requestQueue.length)
				cast(void) getNextRequest();

		// If we were expecting any more responses, we're not getting them.
		while (receivedResponses < sentRequests)
			onDone(null, reason, type == DisconnectType.error);

		// If there are more requests queued (keepAlive == false),
		// reconnect and keep going.
		if (requestQueue.length)
			connect(requestQueue[0]);
	}

	IConnection adaptConnection(IConnection conn)
	{
		return conn;
	}

public:
	/// User-Agent header to advertise.
	string agent = "ae.net.http.client (+https://github.com/CyberShadow/ae)";
	/// Keep connection alive after one request.
	bool keepAlive = false;
	/// Send requests without waiting for a response. Requires keepAlive.
	bool pipelining = false;

	/// Constructor.
	this(Duration timeout = 30.seconds, Connector connector = new TcpConnector)
	{
		assert(timeout >= Duration.zero);

		this.connector = connector;
		IConnection c = connector.getConnection();

		c = adaptConnection(c);

		if (timeout > Duration.zero)
		{
			timer = new TimeoutAdapter(c);
			timer.setIdleTimeout(timeout);
			c = timer;
		}

		conn = c;
		conn.handleConnect = &onConnect;
		conn.handleDisconnect = &onDisconnect;
	}

	/// Fix up a response to set up required headers, etc.
	/// Done automatically by `request`, unless called with `normalize == false`.
	void normalizeRequest(HttpRequest request)
	{
		if ("User-Agent" !in request.headers && agent)
			request.headers["User-Agent"] = agent;
		if ("Accept-Encoding" !in request.headers)
		{
			static if (haveZlib)
				request.headers["Accept-Encoding"] = "gzip, deflate, identity;q=0.5, *;q=0";
			else
				request.headers["Accept-Encoding"] = "identity;q=0.5, *;q=0";
		}
		if (request.data)
			request.headers["Content-Length"] = to!string(request.data.bytes.length);
		if ("Connection" !in request.headers)
			request.headers["Connection"] = keepAlive ? "keep-alive" : "close";
	}

	/// Send a HTTP request.
	void request(HttpRequest request, bool normalize = true)
	{
		if (normalize)
			normalizeRequest(request);

		requestQueue ~= request;

		assert(conn.state <= ConnectionState.connected, "Attempting a HTTP request on a %s connection".format(conn.state));
		if (conn.state == ConnectionState.disconnected)
		{
			connect(request);
			return; // onConnect will do the rest
		}

		// |---------+------------+------------+---------------------------------------------------------------|
		// | enqueue | keep-alive | pipelining | outcome                                                       |
		// |---------+------------+------------+---------------------------------------------------------------|
		// | no      | no         | no         | one request and one connection at a time                      |
		// | no      | no         | yes        | error, need keep-alive for pipelining                         |
		// | no      | yes        | no         | keep connection alive so that we can send more requests later |
		// | no      | yes        | yes        | keep-alive + pipelining                                       |
		// | yes     | no         | no         | disconnect and connect again, once per queued request         |
		// | yes     | no         | yes        | error, need keep-alive for pipelining                         |
		// | yes     | yes        | no         | when one response is processed, send the next queued request  |
		// | yes     | yes        | yes        | send all requests at once after connecting                    |
		// |---------+------------+------------+---------------------------------------------------------------|

		// |------------+------------+-----------------------------------------------------------------|
		// | keep-alive | pipelining | wat do in request()                                             |
		// |------------+------------+-----------------------------------------------------------------|
		// | no         | no         | assert(!connected), connect, enqueue                            |
		// | no         | yes        | assert                                                          |
		// | yes        | no         | enqueue or send now if connected; enqueue and connect otherwise |
		// | yes        | yes        | send now if connected; enqueue and connect otherwise            |
		// |------------+------------+-----------------------------------------------------------------|

		if (!keepAlive)
		{
			if (!pipelining)
			{}
			else
				assert(false, "keepAlive is required for pipelining");
		}
		else
		{
			if (!pipelining)
			{
				// Can we send it now?
				if (isIdle())
					onIdle();
			}
			else
			{
				// Can we send it now?
				if (conn.state == ConnectionState.connected)
				{
					bool wasIdle = isIdle();
					assert(requestQueue.length == 1);
					while (requestQueue.length)
						sendRequest(getNextRequest());
					if (wasIdle)
						expectResponse();
				}
			}
		}
	}

	/// Returns true if a connection is active
	/// (whether due to an in-flight request or due to keep-alive).
	bool connected()
	{
		if (receivedResponses < sentRequests)
			return true;
		if (keepAlive && conn.state == ConnectionState.connected)
			return true;
		return false;
	}

	/// Close the connection to the HTTP server.
	void disconnect(string reason = IConnection.defaultDisconnectReason)
	{
		conn.disconnect(reason);
	}

	/// User-supplied callback for handling the response.
	void delegate(HttpResponse response, string disconnectReason) handleResponse;
}

/// HTTPS client.
class HttpsClient : HttpClient
{
	/// SSL context and adapter to use for TLS.
	SSLContext ctx;
	SSLAdapter adapter; /// ditto

	/// Constructor.
	this(Duration timeout = 30.seconds)
	{
		ctx = ssl.createContext(SSLContext.Kind.client);
		super(timeout);
	}

	protected override IConnection adaptConnection(IConnection conn)
	{
		adapter = ssl.createAdapter(ctx, conn);
		return adapter;
	}

	protected override void connect(HttpRequest request)
	{
		super.connect(request);
		if (conn.state != ConnectionState.connecting)
		{
			assert(conn.state == ConnectionState.disconnected);
			return; // synchronous connection error
		}
		adapter.setHostName(request.host);
	}
}

// Experimental for now
class Connector
{
	abstract IConnection getConnection();
	abstract void connect(string host, ushort port);
}

// ditto
class SocketConnector(SocketType) : Connector
{
	protected SocketType conn;

	this()
	{
		conn = new SocketType();
	}

	override IConnection getConnection()
	{
		return conn;
	}
}

// ditto
class TcpConnector : SocketConnector!TcpConnection
{
	override void connect(string host, ushort port)
	{
		conn.connect(host, port);
	}
}

// ditto
version(Posix)
class UnixConnector : SocketConnector!SocketConnection
{
	string path;

	this(string path)
	{
		this.path = path;
	}

	override void connect(string host, ushort port)
	{
		import std.socket;
		auto addr = new UnixAddress(path);
		conn.connect([AddressInfo(AddressFamily.UNIX, SocketType.STREAM, cast(ProtocolType)0, addr, path)]);
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
void httpGet(string url, void delegate(HttpResponse response, string disconnectReason) responseHandler)
{
	httpRequest(new HttpRequest(url), responseHandler);
}

/// ditto
void httpGet(string url, void delegate(Data) resultHandler, void delegate(string) errorHandler)
{
	httpRequest(new HttpRequest(url), resultHandler, errorHandler);
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
void httpPost(string url, DataVec postData, string contentType, void delegate(Data) resultHandler, void delegate(string) errorHandler)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.method = "POST";
	if (contentType)
		request.headers["Content-Type"] = contentType;
	request.data = move(postData);
	httpRequest(request, resultHandler, errorHandler);
}

/// ditto
void httpPost(string url, DataVec postData, string contentType, void delegate(string) resultHandler, void delegate(string) errorHandler)
{
	httpPost(url, move(postData), contentType,
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
	return httpPost(url, DataVec(Data(encodeUrlParameters(vars))), "application/x-www-form-urlencoded", resultHandler, errorHandler);
}

// https://issues.dlang.org/show_bug.cgi?id=7016
version (unittest)
{
	static import ae.net.http.server;
	static import ae.net.http.responseex;
}

unittest
{
	import ae.net.http.common : HttpRequest, HttpResponse;
	import ae.net.http.server : HttpServer, HttpServerConnection;
	import ae.net.http.responseex : HttpResponseEx;

	foreach (enqueue; [false, true])
	foreach (keepAlive; [false, true])
	foreach (pipelining; [false, true])
	{
		if (pipelining && !keepAlive)
			continue;
		debug (HTTP) stderr.writefln("===== Testing enqueue=%s keepAlive=%s pipelining=%s", enqueue, keepAlive, pipelining);

		auto s = new HttpServer;
		s.handleRequest = (HttpRequest _/*request*/, HttpServerConnection conn) {
			auto response = new HttpResponseEx;
			conn.sendResponse(response.serveText("Hello!"));
		};
		auto port = s.listen(0, "127.0.0.1");

		auto c = new HttpClient;
		c.keepAlive = keepAlive;
		c.pipelining = pipelining;
		auto r = new HttpRequest("http://127.0.0.1:" ~ to!string(port));
		int count;
		c.handleResponse =
			(HttpResponse response, string _/*disconnectReason*/)
			{
				assert(response, "HTTP server error");
				assert(cast(string)response.getContent.toHeap == "Hello!");
				if (++count == 5)
				{
					s.close();
					if (keepAlive)
						c.disconnect();
				}
				else
					if (!enqueue)
						c.request(r);
			};
		foreach (n; 0 .. enqueue ? 5 : 1)
			c.request(r);

		socketManager.loop();

		assert(count == 5);
	}
}
