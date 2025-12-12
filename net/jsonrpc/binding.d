/**
 * JSON-RPC D interface wrappers.
 *
 * Provides compile-time generation of JSON-RPC client proxies and
 * server dispatchers from D interface definitions.
 *
 * All interface methods must return `Promise!T`. For simple synchronous
 * implementations, use `resolve(value)` to create an immediately fulfilled
 * promise.
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

module ae.net.jsonrpc.binding;

import std.conv : to;
import std.meta : AliasSeq;
import std.traits;
import std.typecons : Nullable;

import ae.net.asockets : IConnection;
import ae.net.jsonrpc.codec;
import ae.utils.json;
import ae.utils.jsonrpc;
import ae.utils.meta : hasAttribute, getAttribute;
import ae.utils.promise : Promise, PromiseValue, resolve;

// ************************************************************************

/// UDA to customize the JSON-RPC method name.
/// Use this when the method name differs from the D function name.
struct RPCName
{
	string name;
}

/// UDA to mark a method as a notification (no response expected).
struct RPCNotification {}

// ************************************************************************

/// Get the RPC method name for a given method.
/// Uses @RPCName if present, otherwise uses the D method name.
template getRpcMethodName(alias method, string defaultName)
{
	static if (hasAttribute!(RPCName, method))
		enum getRpcMethodName = getAttribute!(RPCName, method).name;
	else
		enum getRpcMethodName = defaultName;
}

/// Check if a method is marked as a notification.
template isRpcNotification(alias method)
{
	enum isRpcNotification = hasAttribute!(RPCNotification, method);
}

// ************************************************************************

/// Server-side JSON-RPC dispatcher.
///
/// Dispatches incoming JSON-RPC requests to methods on a D interface
/// implementation using compile-time reflection.
///
/// Interface methods must return `Promise!T`. For synchronous implementations,
/// use `resolve(value)` to create an immediately fulfilled promise.
///
/// Example:
/// ---
/// interface Calculator
/// {
///     Promise!int add(int a, int b);
///     @RPCName("math.subtract") Promise!int subtract(int a, int b);
/// }
///
/// class CalculatorImpl : Calculator
/// {
///     Promise!int add(int a, int b) { return resolve(a + b); }
///     Promise!int subtract(int a, int b) { return resolve(a - b); }
/// }
///
/// auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());
///
/// // Wire up to a codec
/// auto codec = new JsonRpcServerCodec(conn);
/// codec.handleRequest = &dispatcher.dispatch;
/// ---
struct JsonRpcDispatcher(I) if (is(I == interface))
{
	private I impl;

	/// Create a dispatcher for the given interface implementation.
	this(I implementation)
	{
		this.impl = implementation;
	}

	/// Dispatch a JSON-RPC request to the implementation.
	/// Returns a promise that resolves to the response.
	/// For notifications, the promise resolves to a response with null id.
	Promise!JsonRpcResponse dispatch(JsonRpcRequest request)
	{
		auto id = request.id ? request.id : JSONFragment(`null`);

		switch (request.method)
		{
			static foreach (memberName; __traits(allMembers, I))
			{
				static if (isCallableMember!(I, memberName))
				{
					case getRpcMethodName!(__traits(getMember, I, memberName), memberName):
						return callMethod!memberName(request, id);
				}
			}

			default:
				return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.methodNotFound,
					"Method not found: " ~ request.method));
		}
	}

	private Promise!JsonRpcResponse callMethod(string memberName)(JsonRpcRequest request, JSONFragment id)
	{
		alias method = __traits(getMember, I, memberName);
		alias Params = Parameters!method;
		alias Return = ReturnType!method;

		// Verify return type is a Promise
		static assert(is(Return == Promise!(T, E), T, E),
			"RPC interface method " ~ memberName ~ " must return a Promise, not " ~ Return.stringof);

		alias ValueType = PromiseValue!Return;

		// Parse parameters
		static if (Params.length == 0)
		{
			// No parameters expected - call method directly
			return callAndWrapResult!ValueType(id, () => __traits(getMember, impl, memberName)());
		}
		else
		{
			// Parse params from JSON array
			if (!request.params)
				return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.invalidParams,
					"Missing required parameters"));

			auto paramsJson = request.params.json;

			// Try to parse as array
			Params args;
			try
			{
				auto paramsArray = paramsJson.jsonParse!(JSONFragment[]);
				if (paramsArray.length < Params.length)
					return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.invalidParams,
						"Expected " ~ Params.length.to!string ~ " parameters, got " ~
						paramsArray.length.to!string));

				static foreach (i, P; Params)
					args[i] = paramsArray[i].json.jsonParse!P;
			}
			catch (Exception e)
				return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.invalidParams, e.msg));

			return callAndWrapResult!ValueType(id, () => __traits(getMember, impl, memberName)(args));
		}
	}

	/// Call the method and wrap its result in a JsonRpcResponse promise
	private Promise!JsonRpcResponse callAndWrapResult(ValueType)(
		JSONFragment id, scope Promise!ValueType delegate() callMethod)
	{
		Promise!ValueType resultPromise;
		try
			resultPromise = callMethod();
		catch (JsonRpcException e)
			return resolve(JsonRpcResponse.failure(id, e.error));
		catch (Exception e)
			return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.internalError, e.msg));

		auto responsePromise = new Promise!JsonRpcResponse;

		static if (is(ValueType == void))
			alias Result = AliasSeq!();
		else
			alias Result = AliasSeq!(ValueType);

		resultPromise.then((Result result) {
			responsePromise.fulfill(JsonRpcResponse.success(id, result));
		}).except((Exception e) {
			if (auto rpcEx = cast(JsonRpcException) e)
				responsePromise.fulfill(JsonRpcResponse.failure(id, rpcEx.error));
			else
				responsePromise.fulfill(JsonRpcResponse.failure(id, JsonRpcErrorCode.internalError, e.msg));
		});

		return responsePromise;
	}
}

/// Helper to check if a member is a callable method
private template isCallableMember(I, string memberName)
{
	static if (__traits(compiles, __traits(getMember, I, memberName)))
	{
		alias member = __traits(getMember, I, memberName);
		enum isCallableMember = isCallable!member && !is(member == delegate);
	}
	else
		enum isCallableMember = false;
}

/// Create a JSON-RPC dispatcher for an interface implementation.
JsonRpcDispatcher!I jsonRpcDispatcher(I)(I impl) if (is(I == interface))
{
	return JsonRpcDispatcher!I(impl);
}

// ************************************************************************

/// Client-side JSON-RPC proxy generator.
///
/// Generates a client implementation of a D interface that forwards
/// method calls as JSON-RPC requests over a codec.
///
/// Interface methods must return `Promise!T`.
///
/// Example:
/// ---
/// interface Calculator
/// {
///     Promise!int add(int a, int b);
/// }
///
/// auto codec = new JsonRpcClientCodec(conn);
/// auto client = new JsonRpcClient!Calculator(codec);
///
/// client.add(2, 3).then((result) {
///     assert(result == 5);
/// });
/// // Or with await in a fiber:
/// assert(client.add(2, 3).await == 5);
/// ---
class JsonRpcClient(I) : I if (is(I == interface))
{
	private JsonRpcClientCodec codec;

	/// Create a client proxy using a codec.
	this(JsonRpcClientCodec codec)
	{
		this.codec = codec;
	}

	/// Convenience: create a client proxy over a framed connection.
	///
	/// The connection should be a framed connection (e.g., LineBufferedAdapter)
	/// that delivers complete messages and handles framing on send.
	this(IConnection conn)
	{
		this(new JsonRpcClientCodec(conn));
	}

	// Generate implementations for all interface methods
	static foreach (memberName; __traits(allMembers, I))
	{
		static if (isCallableMember!(I, memberName))
		{
			mixin(generateMethodImpl!memberName());
		}
	}

	private static string generateMethodImpl(string memberName)()
	{
		alias method = __traits(getMember, I, memberName);
		alias Params = Parameters!method;
		alias ParamNames = ParameterIdentifierTuple!method;
		alias Return = ReturnType!method;
		enum rpcName = getRpcMethodName!(method, memberName);
		enum isNotification = isRpcNotification!method;

		// Verify return type is a Promise
		static assert(is(Return == Promise!(T, E), T, E),
			"RPC interface method " ~ memberName ~ " must return a Promise");

		alias ValueType = PromiseValue!Return;

		string code = "override ";
		code ~= Return.stringof ~ " " ~ memberName ~ "(";

		// Parameter list
		static foreach (i, P; Params)
		{
			static if (i > 0)
				code ~= ", ";
			code ~= P.stringof ~ " " ~ ParamNames[i];
		}
		code ~= ") {\n";

		// Build request
		code ~= "\t\tJsonRpcRequest req;\n";
		code ~= "\t\treq.method = \"" ~ rpcName ~ "\";\n";

		static if (Params.length > 0)
		{
			code ~= "\t\treq.params = JSONFragment([";
			static foreach (i, P; Params)
			{
				static if (i > 0)
					code ~= ", ";
				code ~= "JSONFragment(" ~ ParamNames[i] ~ ".toJson())";
			}
			code ~= "].toJson());\n";
		}

		static if (isNotification)
		{
			// Notification - no response expected
			code ~= "\t\tcodec.sendNotification(req);\n";
			code ~= "\t\treturn resolve();\n";
		}
		else
		{
			// Request - send via codec and transform response
			code ~= "\t\tauto responsePromise = codec.sendRequest(req);\n";
			code ~= "\t\tauto resultPromise = new Promise!(" ~ ValueType.stringof ~ ");\n";
			code ~= "\t\tresponsePromise.then((JsonRpcResponse response) {\n";
			static if (is(ValueType == void))
			{
				code ~= "\t\t\tif (response.isError)\n";
				code ~= "\t\t\t\tresultPromise.reject(new JsonRpcException(response.error.get));\n";
				code ~= "\t\t\telse\n";
				code ~= "\t\t\t\tresultPromise.fulfill();\n";
			}
			else
			{
				code ~= "\t\t\tif (response.isError)\n";
				code ~= "\t\t\t\tresultPromise.reject(new JsonRpcException(response.error.get));\n";
				code ~= "\t\t\telse\n";
				code ~= "\t\t\t\tresultPromise.fulfill(response.getResult!(" ~ ValueType.stringof ~ ")());\n";
			}
			code ~= "\t\t});\n";
			code ~= "\t\treturn resultPromise;\n";
		}

		code ~= "\t}";
		return code;
	}
}

/// Create a JSON-RPC client proxy for an interface.
///
/// The connection should be a framed connection (e.g., LineBufferedAdapter)
/// that delivers complete messages and handles framing on send.
JsonRpcClient!I jsonRpcClient(I)(IConnection conn) if (is(I == interface))
{
	return new JsonRpcClient!I(conn);
}

// ************************************************************************

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	// Define test interface with Promise returns
	interface Calculator
	{
		Promise!int add(int a, int b);

		@RPCName("math.subtract")
		Promise!int subtract(int a, int b);

		Promise!void logMessage(string msg);
	}

	// Test server dispatcher
	static class CalculatorImpl : Calculator
	{
		string lastLog;

		Promise!int add(int a, int b)
		{
			return resolve(a + b);
		}

		Promise!int subtract(int a, int b)
		{
			return resolve(a - b);
		}

		Promise!void logMessage(string msg)
		{
			lastLog = msg;
			return resolve();
		}
	}

	auto impl = new CalculatorImpl();
	auto dispatcher = jsonRpcDispatcher!Calculator(impl);

	bool done;

	// Test add method
	auto req1 = JsonRpcRequest();
	req1.method = "add";
	req1.params = JSONFragment(`[2, 3]`);
	req1.id = JSONFragment(`1`);

	dispatcher.dispatch(req1).then((JsonRpcResponse resp1) {
		assert(!resp1.isError);
		assert(resp1.getResult!int == 5);

		// Test RPCName attribute
		auto req2 = JsonRpcRequest();
		req2.method = "math.subtract";
		req2.params = JSONFragment(`[10, 4]`);
		req2.id = JSONFragment(`2`);

		dispatcher.dispatch(req2).then((JsonRpcResponse resp2) {
			assert(!resp2.isError);
			assert(resp2.getResult!int == 6);

			// Test void method
			auto req3 = JsonRpcRequest();
			req3.method = "logMessage";
			req3.params = JSONFragment(`["hello"]`);
			req3.id = JSONFragment(`3`);

			dispatcher.dispatch(req3).then((JsonRpcResponse resp3) {
				assert(!resp3.isError);
				assert(impl.lastLog == "hello");

				// Test method not found
				auto req4 = JsonRpcRequest();
				req4.method = "unknown";
				req4.id = JSONFragment(`4`);

				dispatcher.dispatch(req4).then((JsonRpcResponse resp4) {
					assert(resp4.isError);
					assert(resp4.error.get.code == JsonRpcErrorCode.methodNotFound);
					done = true;
				});
			});
		});
	});

	socketManager.loop();
	assert(done, "Test did not complete");
}
