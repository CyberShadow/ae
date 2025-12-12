/**
 * JSON-RPC 2.0 protocol implementation.
 *
 * Provides data structures and utilities for JSON-RPC 2.0 messages.
 * Supports both single requests and batch requests.
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

module ae.utils.jsonrpc;

import std.conv : to;
import std.typecons : Nullable;

import ae.utils.json;

// ************************************************************************

/// JSON-RPC 2.0 version string
enum JSONRPC_VERSION = "2.0";

/// Standard JSON-RPC 2.0 error codes
enum JsonRpcErrorCode : int
{
	/// Parse error - Invalid JSON was received
	parseError = -32700,

	/// Invalid Request - The JSON sent is not a valid Request object
	invalidRequest = -32600,

	/// Method not found - The method does not exist / is not available
	methodNotFound = -32601,

	/// Invalid params - Invalid method parameter(s)
	invalidParams = -32602,

	/// Internal error - Internal JSON-RPC error
	internalError = -32603,

	// -32000 to -32099 are reserved for implementation-defined server errors
}

/// Returns the default error message for a standard error code
string getDefaultErrorMessage(int code)
{
	switch (code)
	{
		case JsonRpcErrorCode.parseError: return "Parse error";
		case JsonRpcErrorCode.invalidRequest: return "Invalid Request";
		case JsonRpcErrorCode.methodNotFound: return "Method not found";
		case JsonRpcErrorCode.invalidParams: return "Invalid params";
		case JsonRpcErrorCode.internalError: return "Internal error";
		default:
			if (code >= -32099 && code <= -32000)
				return "Server error";
			return "Unknown error";
	}
}

// ************************************************************************

/// JSON-RPC 2.0 Error object
struct JsonRpcError
{
	/// Error code
	int code;

	/// Human-readable error message
	string message;

	/// Additional error data (optional)
	@JSONOptional
	JSONFragment data;

	/// Create an error with a standard error code
	static JsonRpcError fromCode(JsonRpcErrorCode code, string message = null)
	{
		JsonRpcError err;
		err.code = code;
		err.message = message.length ? message : getDefaultErrorMessage(code);
		return err;
	}

	/// Create an error with additional data
	static JsonRpcError fromCode(T)(JsonRpcErrorCode code, string message, T data)
	{
		JsonRpcError err;
		err.code = code;
		err.message = message.length ? message : getDefaultErrorMessage(code);
		err.data = JSONFragment(data.toJson());
		return err;
	}
}

/// Exception representing a JSON-RPC error
class JsonRpcException : Exception
{
	JsonRpcError error;

	this(JsonRpcError error, string file = __FILE__, size_t line = __LINE__)
	{
		this.error = error;
		super(error.message, file, line);
	}

	this(int code, string message, string file = __FILE__, size_t line = __LINE__)
	{
		this(JsonRpcError(code, message), file, line);
	}

	this(JsonRpcErrorCode code, string message = null, string file = __FILE__, size_t line = __LINE__)
	{
		this(JsonRpcError.fromCode(code, message), file, line);
	}
}

// ************************************************************************

/// JSON-RPC 2.0 Request object
struct JsonRpcRequest
{
	/// Protocol version (always "2.0")
	string jsonrpc = JSONRPC_VERSION;

	/// Method name to invoke
	string method;

	/// Parameters - can be array (positional) or object (named)
	@JSONOptional
	JSONFragment params;

	/// Request ID - omit for notifications
	@JSONOptional
	JSONFragment id;

	/// Returns true if this is a notification (no response expected)
	@property bool isNotification() const
	{
		return !id;
	}

	/// Create a request with positional parameters
	static JsonRpcRequest create(T...)(string method, JSONFragment id, T params)
	{
		JsonRpcRequest req;
		req.method = method;
		req.id = id;
		static if (T.length > 0)
			req.params = JSONFragment([params].toJson());
		return req;
	}

	/// Create a notification (request without id)
	static JsonRpcRequest notification(T...)(string method, T params)
	{
		JsonRpcRequest req;
		req.method = method;
		static if (T.length > 0)
			req.params = JSONFragment([params].toJson());
		return req;
	}
}

/// JSON-RPC 2.0 Response object
struct JsonRpcResponse
{
	/// Protocol version (always "2.0")
	string jsonrpc = JSONRPC_VERSION;

	/// Result on success (mutually exclusive with error)
	@JSONOptional
	JSONFragment result;

	/// Error on failure (mutually exclusive with result)
	@JSONOptional
	Nullable!JsonRpcError error;

	/// Request ID this response corresponds to
	@JSONOptional
	JSONFragment id;

	/// Create a success response
	static JsonRpcResponse success(T)(JSONFragment id, T result)
	{
		JsonRpcResponse r;
		r.id = id;
		r.result = JSONFragment(result.toJson());
		return r;
	}

	/// Create a success response with no result (for void methods)
	static JsonRpcResponse success(JSONFragment id)
	{
		JsonRpcResponse r;
		r.id = id;
		r.result = JSONFragment("null");
		return r;
	}

	/// Create an error response
	static JsonRpcResponse failure(JSONFragment id, JsonRpcError error)
	{
		JsonRpcResponse r;
		r.id = id;
		r.error = error;
		return r;
	}

	/// Create an error response with a standard error code
	static JsonRpcResponse failure(JSONFragment id, JsonRpcErrorCode code, string message = null)
	{
		return failure(id, JsonRpcError.fromCode(code, message));
	}

	/// Check if this is an error response
	@property bool isError() const
	{
		return !error.isNull;
	}

	/// Get the result deserialized to type T
	/// Throws JsonRpcException if this is an error response
	T getResult(T)() const
	{
		if (isError)
			throw new JsonRpcException(error.get);
		return result.json.jsonParse!T;
	}
}

// ************************************************************************

/// Result of parsing JSON-RPC message(s)
struct JsonRpcParsedRequests
{
	/// Parsed requests
	JsonRpcRequest[] requests;

	/// Whether the original message was a batch
	bool isBatch;
}

/// Parse JSON-RPC request(s) from a JSON string.
/// Handles both single requests and batch requests (arrays).
JsonRpcParsedRequests parseRequests(C)(C[] json)
{
	JsonRpcParsedRequests result;

	// Check for batch (array) vs single request
	size_t i = 0;
	while (i < json.length && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r'))
		i++;

	if (i < json.length && json[i] == '[')
	{
		result.isBatch = true;
		result.requests = json.jsonParse!(JsonRpcRequest[]);
	}
	else
	{
		result.isBatch = false;
		result.requests = [json.jsonParse!JsonRpcRequest];
	}

	return result;
}

/// Parse a single JSON-RPC request
JsonRpcRequest parseRequest(C)(C[] json)
{
	return json.jsonParse!JsonRpcRequest;
}

/// Result of parsing JSON-RPC response(s)
struct JsonRpcParsedResponses
{
	/// Parsed responses
	JsonRpcResponse[] responses;

	/// Whether the original message was a batch
	bool isBatch;
}

/// Parse JSON-RPC response(s) from a JSON string.
/// Handles both single responses and batch responses (arrays).
JsonRpcParsedResponses parseResponses(C)(C[] json)
{
	JsonRpcParsedResponses result;

	// Check for batch (array) vs single response
	size_t i = 0;
	while (i < json.length && (json[i] == ' ' || json[i] == '\t' || json[i] == '\n' || json[i] == '\r'))
		i++;

	if (i < json.length && json[i] == '[')
	{
		result.isBatch = true;
		result.responses = json.jsonParse!(JsonRpcResponse[]);
	}
	else
	{
		result.isBatch = false;
		result.responses = [json.jsonParse!JsonRpcResponse];
	}

	return result;
}

/// Parse a single JSON-RPC response
JsonRpcResponse parseResponse(C)(C[] json)
{
	return json.jsonParse!JsonRpcResponse;
}

/// Format a batch of requests or responses as JSON
string formatBatch(T)(T[] items) if (is(T == JsonRpcRequest) || is(T == JsonRpcResponse))
{
	return items.toJson();
}

// ************************************************************************

debug(ae_unittest) unittest
{
	// Test request creation and serialization
	auto req = JsonRpcRequest.create("add", JSONFragment(`1`), 2, 3);
	assert(req.method == "add");
	assert(!req.isNotification);
	auto json = req.toJson();
	assert(json.jsonParse!JsonRpcRequest.method == "add");

	// Test notification
	auto notif = JsonRpcRequest.notification("log", "hello");
	assert(notif.isNotification);
	assert(notif.method == "log");
}

debug(ae_unittest) unittest
{
	// Test request parsing
	auto req = `{"jsonrpc":"2.0","method":"subtract","params":[42,23],"id":1}`.parseRequest();
	assert(req.method == "subtract");
	assert(!req.isNotification);
	assert(req.params.json == "[42,23]");

	// Test notification parsing
	auto notif = `{"jsonrpc":"2.0","method":"update","params":[1,2,3]}`.parseRequest();
	assert(notif.isNotification);
	assert(notif.method == "update");
}

debug(ae_unittest) unittest
{
	// Test response parsing - success
	auto resp = `{"jsonrpc":"2.0","result":19,"id":1}`.parseResponse();
	assert(!resp.isError);
	assert(resp.getResult!int == 19);

	// Test response parsing - error
	auto errResp = `{"jsonrpc":"2.0","error":{"code":-32600,"message":"Invalid Request"},"id":null}`.parseResponse();
	assert(errResp.isError);
	assert(errResp.error.get.code == JsonRpcErrorCode.invalidRequest);
}

debug(ae_unittest) unittest
{
	// Test batch parsing
	auto parsed = parseRequests(`[{"jsonrpc":"2.0","method":"a","id":1},{"jsonrpc":"2.0","method":"b","id":2}]`);
	assert(parsed.isBatch);
	assert(parsed.requests.length == 2);
	assert(parsed.requests[0].method == "a");
	assert(parsed.requests[1].method == "b");
}

debug(ae_unittest) unittest
{
	// Test response creation
	auto resp = JsonRpcResponse.success(JSONFragment(`1`), 42);
	assert(!resp.isError);
	assert(resp.result.json == "42");

	auto errResp = JsonRpcResponse.failure(JSONFragment(`1`), JsonRpcErrorCode.methodNotFound);
	assert(errResp.isError);
	assert(errResp.error.get.code == JsonRpcErrorCode.methodNotFound);
}

debug(ae_unittest) unittest
{
	// Test error with data
	auto err = JsonRpcError.fromCode(JsonRpcErrorCode.invalidParams, "Missing required field", ["field": "name"]);
	assert(err.code == JsonRpcErrorCode.invalidParams);
	assert(err.data);
}
