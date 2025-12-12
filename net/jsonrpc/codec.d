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

/// Server-side JSON-RPC codec.
///
/// Wraps an IConnection and handles decoding incoming Data to JsonRpcRequest
/// and encoding JsonRpcResponse back to Data. Handles batches transparently.
///
/// Example:
/// ---
/// auto codec = new JsonRpcServerCodec(conn);
/// codec.handleRequest = (request) {
///     return dispatcher.dispatch(request);
/// };
/// ---
class JsonRpcServerCodec
{
	private IConnection conn;

	/// Handler for incoming requests.
	/// Returns a promise that resolves to the response.
	/// Called once per request (multiple times for batches).
	Promise!JsonRpcResponse delegate(JsonRpcRequest request) handleRequest;

	/// Create a server codec wrapping the given connection.
	this(IConnection conn)
	{
		this.conn = conn;
		conn.handleReadData = &onReadData;
	}

	private void onReadData(Data data) nothrow
	{
		string message;
		try
			message = data.toGC.asText.assumeUnique;
		catch (Exception e)
		{
			try
				conn.disconnect(e.msg, DisconnectType.error);
			catch (Exception e2)
				assert(false, e2.msg);
			return;
		}

		processMessage(message);
	}

	private void processMessage(string message) nothrow
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
			assert(false, "Unexpected exception in processMessage: " ~ e.msg);
	}
}

// ************************************************************************

/// Client-side JSON-RPC codec.
///
/// Wraps an IConnection and handles encoding JsonRpcRequest to Data
/// and decoding Data back to JsonRpcResponse. Handles request/response
/// correlation via request IDs.
///
/// Example:
/// ---
/// auto codec = new JsonRpcClientCodec(conn);
/// codec.sendRequest(request).then((response) { ... });
/// ---
class JsonRpcClientCodec
{
	private IConnection conn;
	private Promise!JsonRpcResponse[string] pendingRequests;
	private uint nextId = 1;

	/// Create a client codec wrapping the given connection.
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
		// Ensure no ID is set for notifications
		if (request.id)
			assert(false, "Notification must not have an ID");
		conn.send(Data(request.toJson().asBytes));
	}

	private void onReadData(Data data) nothrow
	{
		try
		{
			auto message = data.toGC.asText.assumeUnique;
			auto response = message.parseResponse();

			if (!response.id)
			{
				// Response without ID indicates server couldn't parse request
				string reason = "Server error without request ID";
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
		catch (Exception e)
			return doDisconnect("Malformed response: " ~ e.msg);
	}

	private void doDisconnect(string reason) nothrow
	{
		try
			conn.disconnect(reason, DisconnectType.error);
		catch (Exception e)
			assert(false, e.msg);
	}
}

