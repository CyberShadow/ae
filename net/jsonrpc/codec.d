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
version(unittest) import ae.net.asockets : ConnectionState;
import ae.sys.data : Data;
import ae.utils.array : asBytes;
import ae.utils.serialization.json;
import ae.utils.serialization.store : SerializedObject;
import ae.utils.jsonrpc;
import ae.utils.promise : Promise, all;
import ae.utils.text : asText;

private alias SO = SerializedObject!(immutable(char));

/// Normalize a JSON-RPC ID value to a canonical JSON string for use as
/// an associative array key. Handles differences in number formatting
/// (1 vs 1.0) and string encoding ("A" vs "\u0041").
private string normalizeJsonId(ref SO id)
{
	if (!id) return null;
	return toJson(id);
}

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
		request.id = SO(id);

		auto responsePromise = new Promise!JsonRpcResponse;
		pendingRequests[toJson(request.id)] = responsePromise;
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
			auto so = message.jsonParse!SO;
			bool isBatch = so.type == SO.Type.array;

			// Peek at the first element to distinguish request from response
			SO* first = isBatch
				? (so.length > 0 ? &so[0] : null)
				: (so.type == SO.Type.object ? &so : null);

			if (first is null)
				return;

			if (first.type == SO.Type.object && ("method" in *first))
				processRequests(so, isBatch);
			else
				processResponse(so, isBatch);
		}
		catch (Exception e)
			return doDisconnect("Malformed message: " ~ e.msg);
	}

	void processRequests(ref SO so, bool isBatch) nothrow
	{
		try
		{
			if (handleRequest is null)
				return;

			JsonRpcRequest[] requests;
			if (isBatch)
			{
				foreach (i; 0 .. so.length)
					requests ~= so[i].deserializeTo!JsonRpcRequest;
			}
			else
				requests ~= so.deserializeTo!JsonRpcRequest;

			// Dispatch all requests
			Promise!JsonRpcResponse[] responsePromises;
			foreach (request; requests)
				responsePromises ~= handleRequest(request);

			// Wait for all responses, then send
			all(responsePromises).then((JsonRpcResponse[] responses) {
				// Filter out notification responses
				JsonRpcResponse[] actualResponses;
				foreach (i, response; responses)
					if (!requests[i].isNotification)
						actualResponses ~= response;

				if (actualResponses.length > 0)
				{
					string responseJson;
					if (isBatch)
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

	void processResponse(ref SO so, bool isBatch)
	{
		auto response = so.deserializeTo!JsonRpcResponse;

		if (!response.id)
		{
			// Response without ID indicates peer couldn't parse request
			string reason = "Peer error without request ID";
			if (response.isError)
				reason = response.error.get.message;
			return doDisconnect(reason);
		}

		auto idKey = normalizeJsonId(response.id);

		if (auto pending = idKey in pendingRequests)
		{
			pending.fulfill(response);
			pendingRequests.remove(idKey);
		}
		else
			return doDisconnect("Unexpected response ID: " ~ toJson(response.id));
	}

	void doDisconnect(string reason) nothrow
	{
		try
			conn.disconnect(reason, DisconnectType.error);
		catch (Exception e)
			assert(false, e.msg);
	}
}

debug(ae_unittest) unittest
{
	import ae.utils.promise : resolve;

	// A peer may add members to the request object as its protocol
	// evolves. JSON-RPC 2.0 specifies the member set but does not oblige
	// implementations to reject extra members, and a codec that fails on
	// them cannot interoperate across peer versions.
	static class MockConnection : IConnection
	{
		ReadDataHandler readHandler;
		string disconnectReason;
		bool disconnected;

		@property ConnectionState state() { return ConnectionState.connected; }

		void send(scope Data[] data, int priority = DEFAULT_PRIORITY) {}
		alias send = IConnection.send;

		void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
		{
			disconnected = true;
			disconnectReason = reason;
		}
		@property void handleConnect(ConnectHandler value) {}
		@property void handleReadData(ReadDataHandler value) { readHandler = value; }
		@property void handleDisconnect(DisconnectHandler value) {}
		@property void handleBufferFlushed(BufferFlushedHandler value) {}
	}

	string[] dispatched;
	auto conn = new MockConnection;
	auto codec = new JsonRpcCodec(conn);
	codec.handleRequest = (JsonRpcRequest request) {
		dispatched ~= request.method;
		return resolve(JsonRpcResponse.success(request.id, 0));
	};

	// Unknown top-level member, and no "jsonrpc" member at all.
	conn.readHandler(Data(
		`{"method":"peer/notify","params":{},"emittedAtMs":1}`.asBytes));
	assert(dispatched == ["peer/notify"], dispatched.length ? dispatched[0] : "(none)");
	assert(!conn.disconnected, conn.disconnectReason);

	// Same, in a batch.
	dispatched = null;
	conn.readHandler(Data(
		`[{"method":"a","extra":1},{"method":"b","extra":2}]`.asBytes));
	assert(dispatched == ["a", "b"]);
	assert(!conn.disconnected, conn.disconnectReason);
}

/// Convenience alias for server-only usage.
alias JsonRpcServerCodec = JsonRpcCodec;

/// Convenience alias for client-only usage.
alias JsonRpcClientCodec = JsonRpcCodec;
