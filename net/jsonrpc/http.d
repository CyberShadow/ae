/**
 * JSON-RPC over HTTP transport.
 *
 * Provides JSON-RPC transport implementations using HTTP as the
 * underlying protocol.
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

module ae.net.jsonrpc.http;

import std.algorithm.searching : startsWith;
import std.conv : to;
import std.typecons : Nullable;

import ae.net.asockets : ConnectionState, DisconnectType, IConnection, socketManager, onNextTick;
import ae.net.http.client;
import ae.net.http.common;
import ae.net.http.server;
import ae.sys.data;
import ae.sys.dataset : DataVec, joinData;
import ae.utils.array : asBytes;
import ae.utils.json;
import ae.utils.jsonrpc;

// ************************************************************************

/// HTTP client transport for JSON-RPC as an IConnection.
///
/// Implements IConnection over HTTP POST requests, enabling JSON-RPC
/// clients to work transparently over HTTP.
///
/// Each `send()` call results in an HTTP POST request to the endpoint.
/// The HTTP response body is delivered via `handleReadData`.
///
/// Example:
/// ---
/// auto conn = new HttpJsonRpcConnection("http://example.com/rpc");
/// auto client = jsonRpcClient!Calculator(conn);
/// client.add(2, 3).then((result) { ... });
/// ---
class HttpJsonRpcConnection : IConnection
{
	private string endpoint;
	private HttpClient client;
	private ConnectionState _state = ConnectionState.connected;

	@property void handleConnect(IConnection.ConnectHandler value) { connectHandler = value; }
	private IConnection.ConnectHandler connectHandler;

	@property void handleReadData(IConnection.ReadDataHandler value) { readDataHandler = value; }
	private IConnection.ReadDataHandler readDataHandler;

	@property void handleDisconnect(IConnection.DisconnectHandler value) { disconnectHandler = value; }
	private IConnection.DisconnectHandler disconnectHandler;

	@property void handleBufferFlushed(IConnection.BufferFlushedHandler value) { bufferFlushedHandler = value; }
	private IConnection.BufferFlushedHandler bufferFlushedHandler;

	/// Create an HTTP JSON-RPC connection for the given endpoint URL.
	this(string endpoint)
	{
		this.endpoint = endpoint;
		this.client = new HttpClient();
		this.client.handleResponse = &onResponse;
	}

	/// Get connection state.
	@property ConnectionState state()
	{
		return _state;
	}

	/// Send data via HTTP POST request.
	void send(scope Data[] data, int priority = IConnection.DEFAULT_PRIORITY)
	{
		if (_state != ConnectionState.connected)
			return;

		auto request = new HttpRequest();
		request.resource = endpoint;
		request.method = "POST";
		request.headers["Content-Type"] = "application/json";
		request.data = DataVec(data);

		client.request(request);
	}

	alias send = IConnection.send;

	/// Close the connection.
	void disconnect(string reason = IConnection.defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		if (_state == ConnectionState.disconnected)
			return;

		_state = ConnectionState.disconnected;
		if (client.connected)
			client.disconnect(reason);
		if (disconnectHandler)
			disconnectHandler(reason, type);
	}

private:
	void onResponse(HttpResponse response, string disconnectReason) nothrow
	{
		try
		{
			if (!response)
			{
				callDisconnectHandler(disconnectReason, DisconnectType.error);
				return;
			}

			if (response.status != HttpStatusCode.OK && response.status != HttpStatusCode.NoContent)
			{
				callDisconnectHandler("HTTP error: " ~ response.statusMessage, DisconnectType.error);
				return;
			}

			// Call buffer flushed after successful send
			callBufferFlushedHandler();

			if (response.status == HttpStatusCode.NoContent)
			{
				// No content (all notifications) - nothing to read
				return;
			}

			callReadDataHandler(response.getContent());
		}
		catch (Exception e)
		{
			callDisconnectHandler(e.msg, DisconnectType.error);
		}
	}

	void callDisconnectHandler(string reason, DisconnectType type) nothrow
	{
		if (disconnectHandler)
		{
			try
				disconnectHandler(reason, type);
			catch (Exception e)
				assert(false, e.msg); // Disconnect handler should not throw
		}
	}

	void callBufferFlushedHandler() nothrow
	{
		if (bufferFlushedHandler)
		{
			try
				bufferFlushedHandler();
			catch (Exception e)
				callDisconnectHandler(e.msg, DisconnectType.error);
		}
	}

	void callReadDataHandler(Data data) nothrow
	{
		if (readDataHandler)
		{
			try
				readDataHandler(data);
			catch (Exception e)
				callDisconnectHandler(e.msg, DisconnectType.error);
		}
	}
}

// ************************************************************************

/// HTTP server-side connection for JSON-RPC as an IConnection.
///
/// Wraps an HTTP request/response pair as an IConnection, enabling JSON-RPC
/// servers to work transparently over HTTP.
///
/// The HTTP request body is delivered via `handleReadData`.
/// The first `send()` call sends the HTTP response.
///
/// Example:
/// ---
/// auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());
/// auto server = new HttpServer();
/// server.handleRequest = (request, conn) {
///     auto codec = new JsonRpcServerCodec(new HttpServerJsonRpcConnection(request, conn));
///     codec.handleRequest = &dispatcher.dispatch;
/// };
/// ---
class HttpServerJsonRpcConnection : IConnection
{
	private BaseHttpServerConnection httpConn;
	private ConnectionState _state = ConnectionState.connected;
	private bool responseSent = false;

	@property void handleConnect(IConnection.ConnectHandler value) { connectHandler = value; }
	private IConnection.ConnectHandler connectHandler;

	@property void handleReadData(IConnection.ReadDataHandler value) { readDataHandler = value; }
	private IConnection.ReadDataHandler readDataHandler;

	@property void handleDisconnect(IConnection.DisconnectHandler value) { disconnectHandler = value; }
	private IConnection.DisconnectHandler disconnectHandler;

	@property void handleBufferFlushed(IConnection.BufferFlushedHandler value) { bufferFlushedHandler = value; }
	private IConnection.BufferFlushedHandler bufferFlushedHandler;

	/// Create an HTTP server JSON-RPC connection.
	///
	/// Validates the HTTP request and prepares to deliver the body
	/// via handleReadData. Call this from your HTTP server's request handler.
	this(HttpRequest request, BaseHttpServerConnection conn)
	{
		import ae.sys.timing : setTimeout;
		import core.time : Duration;

		this.httpConn = conn;

		// Validate and deliver on next tick to allow handler setup
		socketManager.onNextTick({
			if (_state != ConnectionState.connected)
				return;

			// Validate method
			if (request.method != "POST")
			{
				sendHttpError(HttpStatusCode.MethodNotAllowed, "Method Not Allowed");
				return;
			}

			// Validate content type
			auto contentType = "Content-Type" in request.headers;
			if (contentType is null || !(*contentType).startsWith("application/json"))
			{
				sendHttpError(HttpStatusCode.UnsupportedMediaType, "Unsupported Media Type");
				return;
			}

			// Deliver request body
			if (readDataHandler)
			{
				auto body_ = request.data[].joinData();
				readDataHandler(body_);
			}
		});
	}

	/// Get connection state.
	@property ConnectionState state()
	{
		return _state;
	}

	/// Send data as HTTP response.
	///
	/// Sends an HTTP 200 response with the data as body.
	/// Can only be called once per connection (HTTP is one-response-per-request).
	void send(scope Data[] data, int priority = IConnection.DEFAULT_PRIORITY)
	{
		assert(_state == ConnectionState.connected, "Cannot send on disconnected connection");
		assert(!responseSent, "HTTP response already sent");

		responseSent = true;

		auto response = new HttpResponse();
		response.status = HttpStatusCode.OK;
		response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.OK);
		response.headers["Content-Type"] = "application/json";
		response.data = DataVec(data);
		httpConn.sendResponse(response);

		if (bufferFlushedHandler) // TODO: should be called when the HTTP response is actually sent
			bufferFlushedHandler();
	}

	alias send = IConnection.send;

	/// Close the connection.
	///
	/// If no response has been sent yet, sends 204 No Content.
	void disconnect(string reason = IConnection.defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		if (_state == ConnectionState.disconnected)
			return;

		_state = ConnectionState.disconnected;

		// If no response sent yet, send 204 No Content (all notifications case)
		if (!responseSent)
		{
			responseSent = true;
			auto response = new HttpResponse();
			response.status = HttpStatusCode.NoContent;
			response.statusMessage = HttpResponse.getStatusMessage(HttpStatusCode.NoContent);
			httpConn.sendResponse(response);
		}

		if (disconnectHandler)
			disconnectHandler(reason, type);
	}

private:
	void sendHttpError(HttpStatusCode status, string message)
	{
		if (responseSent)
			return;

		responseSent = true;
		_state = ConnectionState.disconnected;

		auto response = new HttpResponse();
		response.status = status;
		response.statusMessage = message.length ? message : HttpResponse.getStatusMessage(status);
		httpConn.sendResponse(response);

		if (disconnectHandler)
			disconnectHandler(message, DisconnectType.error);
	}
}

// ************************************************************************

// Test JSON-RPC over HTTP transport.
// Tests both HttpJsonRpcConnection (client) and HttpServerJsonRpcConnection (server).
debug(ae_unittest) unittest
{
	import std.exception : assumeUnique;

	import ae.net.asockets : socketManager;
	import ae.net.jsonrpc.binding : jsonRpcDispatcher;
	import ae.net.jsonrpc.codec : JsonRpcServerCodec;
	import ae.utils.promise : Promise, resolve;
	import ae.utils.text : asText;

	interface Calculator
	{
		Promise!int add(int a, int b);
	}

	static class CalculatorImpl : Calculator
	{
		Promise!int add(int a, int b)
		{
			return resolve(a + b);
		}
	}

	// HTTP server with JSON-RPC
	auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());
	auto server = new HttpServer();
	server.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		auto codec = new JsonRpcServerCodec(new HttpServerJsonRpcConnection(request, conn));
		codec.handleRequest = &dispatcher.dispatch;
	};
	auto port = server.listen(0, "127.0.0.1");

	bool ok;

	// HTTP client - each send() is an HTTP POST, response comes via handleReadData
	auto conn = new HttpJsonRpcConnection("http://127.0.0.1:" ~ port.to!string);

	conn.handleReadData = (Data data) nothrow {
		try
		{
			auto rpcResponse = data.toGC.asText.assumeUnique.parseResponse();
			assert(!rpcResponse.isError, "Expected success response");
			assert(rpcResponse.getResult!int == 5, "Expected 5");

			ok = true;
			server.close();
			conn.disconnect();
		}
		catch (Exception e)
		{
			assert(false, e.msg);
		}
	};

	conn.handleDisconnect = (string reason, DisconnectType type) nothrow {
		if (type == DisconnectType.error)
			assert(false, "Transport error: " ~ reason);
	};

	auto req = JsonRpcRequest.create("add", JSONFragment(`1`), 2, 3);
	conn.send(Data(req.toJson().asBytes));

	socketManager.loop();
	assert(ok, "Test did not complete");
}
