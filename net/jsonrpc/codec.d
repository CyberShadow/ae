/**
 * JSON-RPC codec layer.
 *
 * Handles encoding and decoding between Data (bytes) and JSON-RPC
 * request/response structures. This is the middle layer between
 * transport/framing (IConnection) and binding (D interface wrappers).
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

module ae.net.jsonrpc.codec;

import std.exception : assumeUnique;

import ae.net.asockets : IConnection, DisconnectType;
import ae.sys.data : Data;
import ae.utils.array : asBytes;
import ae.utils.json;
import ae.utils.jsonrpc;
import ae.utils.promise : Promise, all;
import ae.utils.text : asText;

// ************************************************************************

/// Bidirectional JSON-RPC codec.
///
/// Wraps an IConnection and handles encoding/decoding of JSON-RPC messages.
/// Supports both client and server roles simultaneously, enabling bidirectional
/// RPC on transports like TCP or stdio.
///
/// Incoming messages are automatically distinguished by the presence of the
/// `method` field (requests) vs `result`/`error` fields (responses).
///
/// Example (server only):
/// ---
/// auto codec = new JsonRpcCodec(conn);
/// codec.handleRequest = &dispatcher.dispatch;
/// ---
///
/// Example (client only):
/// ---
/// auto codec = new JsonRpcCodec(conn);
/// codec.sendRequest(request).then((response) { ... });
/// ---
///
/// Example (bidirectional):
/// ---
/// auto codec = new JsonRpcCodec(conn);
/// codec.handleRequest = &dispatcher.dispatch;  // Handle incoming requests
/// codec.sendRequest(request);  // Send outgoing requests
/// ---
class JsonRpcCodec
{
	private IConnection conn;
	private Promise!JsonRpcResponse[string] pendingRequests;
	private uint nextId = 1;

	/// Handler for incoming requests.
	/// Returns a promise that resolves to the response.
	/// Called once per request (multiple times for batches).
	Promise!JsonRpcResponse delegate(JsonRpcRequest request) handleRequest;

	/// Create a codec wrapping the given connection.
	this(IConnection conn)
	{
		this.conn = conn;
		conn.handleReadData = &onReadData;
	}

	/// Send a request and return a promise for the response.
	/// Automatically assigns a request ID for correlation.
	Promise!JsonRpcResponse sendRequest(JsonRpcRequest request)
	{
		auto id = nextId++;
		auto idJson = id.toJson();
		request.id = JSONFragment(idJson);

		auto responsePromise = new Promise!JsonRpcResponse;
		pendingRequests[idJson] = responsePromise;
		conn.send(Data(request.toJson().asBytes));

		return responsePromise;
	}

	/// Send a notification (no response expected).
	void sendNotification(JsonRpcRequest request)
	{
		if (request.id)
			assert(false, "Notification must not have an ID");
		conn.send(Data(request.toJson().asBytes));
	}

private:
	void onReadData(Data data) nothrow
	{
		string message;
		try
			message = data.toGC.asText.assumeUnique;
		catch (Exception e)
			return doDisconnect(e.msg);

		processMessage(message);
	}

	void processMessage(string message) nothrow
	{
		try
		{
			if (isRequest(message))
				processRequests(message);
			else
				processResponse(message);
		}
		catch (Exception e)
			return doDisconnect("Malformed message: " ~ e.msg);
	}

	// Check if message is a request (has "method" field) or response
	static bool isRequest(string message)
	{
		// Skip whitespace
		size_t i = 0;
		while (i < message.length && (message[i] == ' ' || message[i] == '\t' ||
				message[i] == '\n' || message[i] == '\r'))
			i++;

		if (i >= message.length)
			return false;

		// For batches, check first element
		if (message[i] == '[')
		{
			i++;
			while (i < message.length && (message[i] == ' ' || message[i] == '\t' ||
					message[i] == '\n' || message[i] == '\r'))
				i++;
		}

		// Parse as object and check for "method" key
		if (i < message.length && message[i] == '{')
		{
			auto obj = message[i .. $].jsonParse!(JSONFragment[string]);
			return "method" in obj ? true : false;
		}

		return false;
	}

	void processRequests(string message) nothrow
	{
		try
		{
			auto parsed = parseRequests(message);

			if (parsed.requests.length == 0)
				return;

			if (handleRequest is null)
				return;

			// Dispatch all requests
			Promise!JsonRpcResponse[] responsePromises;
			foreach (request; parsed.requests)
				responsePromises ~= handleRequest(request);

			// Wait for all responses, then send
			all(responsePromises).then((JsonRpcResponse[] responses) {
				// Filter out notification responses
				JsonRpcResponse[] actualResponses;
				foreach (i, response; responses)
					if (!parsed.requests[i].isNotification)
						actualResponses ~= response;

				if (actualResponses.length > 0)
				{
					string responseJson;
					if (parsed.isBatch)
						responseJson = actualResponses.toJson();
					else
					{
						assert(actualResponses.length == 1);
						responseJson = actualResponses[0].toJson();
					}
					conn.send(Data(responseJson.asBytes));
				}
			});
		}
		catch (Exception e)
			assert(false, "Unexpected exception in processRequests: " ~ e.msg);
	}

	void processResponse(string message)
	{
		auto response = message.parseResponse();

		if (!response.id)
		{
			// Response without ID indicates peer couldn't parse request
			string reason = "Peer error without request ID";
			if (response.isError)
				reason = response.error.get.message;
			return doDisconnect(reason);
		}

		auto idJson = response.id.json;

		if (auto pending = idJson in pendingRequests)
		{
			pending.fulfill(response);
			pendingRequests.remove(idJson);
		}
		else
			return doDisconnect("Unexpected response ID: " ~ idJson);
	}

	void doDisconnect(string reason) nothrow
	{
		try
			conn.disconnect(reason, DisconnectType.error);
		catch (Exception e)
			assert(false, e.msg);
	}
}

/// Convenience alias for server-only usage.
alias JsonRpcServerCodec = JsonRpcCodec;

/// Convenience alias for client-only usage.
alias JsonRpcClientCodec = JsonRpcCodec;
