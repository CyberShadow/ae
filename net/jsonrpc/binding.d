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
import ae.utils.serialization.json;
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

/// UDA to make the client serialize params as a named JSON object
/// instead of a positional array. Can be applied to individual methods
/// or to the interface (applies to all methods).
/// On the server side, both formats are always accepted regardless of this UDA.
struct RPCNamedParams {}

/// UDA to apply to a struct type. When a method has exactly one parameter
/// of a struct type with this UDA, the struct's fields become the top-level
/// params keys instead of being nested under the parameter name.
struct RPCFlatten {}

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

/// Check if named params should be used for a method.
/// Checks the method first, falls back to the interface.
template isRpcNamedParams(I, alias method)
{
	enum isRpcNamedParams = hasAttribute!(RPCNamedParams, method)
		|| hasAttribute!(RPCNamedParams, I);
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
		alias ParamNames = ParameterIdentifierTuple!method;
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
			if (!request.params)
				return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.invalidParams,
					"Missing required parameters"));

			auto paramsJson = request.params.json;

			Params args;
			try
			{
				if (isJsonObject(paramsJson))
				{
					// Named params (JSON object)
					static if (Params.length == 1
						&& is(Params[0] == struct)
						&& hasAttribute!(RPCFlatten, Params[0]))
					{
						// @RPCFlatten: parse entire object as the struct
						args[0] = paramsJson.jsonParse!(Params[0]);
					}
					else
					{
						// Look up each parameter by name
						auto paramsObj = paramsJson.jsonParse!(JSONFragment[string]);
						static foreach (i, P; Params)
						{{
							enum paramName = ParamNames[i];
							auto val = paramName in paramsObj;
							if (val is null)
								return resolve(JsonRpcResponse.failure(id,
									JsonRpcErrorCode.invalidParams,
									"Missing required parameter: " ~ paramName));
							args[i] = (*val).json.jsonParse!P;
						}}
					}
				}
				else
				{
					// Positional params (JSON array)
					static if (Params.length == 1
						&& is(Params[0] == struct)
						&& hasAttribute!(RPCFlatten, Params[0]))
					{
						// @RPCFlatten: parse array elements into struct fields via .tupleof
						auto paramsArray = paramsJson.jsonParse!(JSONFragment[]);
						if (paramsArray.length < Params[0].tupleof.length)
							return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.invalidParams,
								"Expected " ~ Params[0].tupleof.length.to!string ~ " parameters, got " ~
								paramsArray.length.to!string));
						args[0] = rpcFlattenFromArray!(Params[0])(paramsArray);
					}
					else
					{
						auto paramsArray = paramsJson.jsonParse!(JSONFragment[]);
						if (paramsArray.length < Params.length)
							return resolve(JsonRpcResponse.failure(id, JsonRpcErrorCode.invalidParams,
								"Expected " ~ Params.length.to!string ~ " parameters, got " ~
								paramsArray.length.to!string));

						static foreach (i, P; Params)
							args[i] = paramsArray[i].json.jsonParse!P;
					}
				}
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

/// Check if a JSON string represents an object (starts with '{').
/// Used by the server to accept both array and object params.
private bool isJsonObject(string json) pure nothrow @nogc
{
	foreach (c; json)
	{
		switch (c)
		{
			case '{': return true;
			case '[': return false;
			case ' ', '\t', '\n', '\r': continue;
			default: return false;
		}
	}
	return false;
}

/// Validate at compile time that an @RPCFlatten struct has no NonSerialized or JSONExtras fields.
private template validateRpcFlatten(S)
{
	static foreach (i; 0 .. S.tupleof.length)
	{
		static assert(!__traits(hasMember, S, __traits(identifier, S.tupleof[i]) ~ "_nonSerialized"),
			"@RPCFlatten struct " ~ S.stringof ~ " must not have NonSerialized field '"
			~ __traits(identifier, S.tupleof[i]) ~ "'");
		static assert(!is(typeof(S.tupleof[i]) == JSONExtras),
			"@RPCFlatten struct " ~ S.stringof ~ " must not have JSONExtras field");
	}
	enum validateRpcFlatten = true;
}

/// Serialize a struct's fields as a flat JSON array (one element per field).
/// Used by @RPCFlatten in positional (array) mode.
private JSONFragment rpcFlattenToArray(S)(auto ref S s)
{
	enum _ = validateRpcFlatten!S;

	JSONFragment[] result;
	foreach (i, ref field; s.tupleof)
		result ~= JSONFragment(field.toJson());
	return JSONFragment(result.toJson());
}

/// Deserialize a flat JSON array into a struct's fields (one element per field).
/// Used by @RPCFlatten in positional (array) mode on the server side.
private S rpcFlattenFromArray(S)(JSONFragment[] arr)
{
	enum _ = validateRpcFlatten!S;

	S result;
	foreach (i, ref field; result.tupleof)
	{
		if (i < arr.length)
			field = arr[i].json.jsonParse!(typeof(field));
	}
	return result;
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
			enum useNamedParams = isRpcNamedParams!(I, method);
			enum useFlatten = Params.length == 1
				&& is(Params[0] == struct)
				&& hasAttribute!(RPCFlatten, Params[0]);

			static if (useFlatten && useNamedParams)
			{
				// @RPCNamedParams + @RPCFlatten: serialize struct directly as params object
				code ~= "\t\treq.params = JSONFragment(" ~ ParamNames[0] ~ ".toJson());\n";
			}
			else static if (useFlatten)
			{
				// @RPCFlatten only: serialize struct fields as flat positional array
				code ~= "\t\treq.params = rpcFlattenToArray(" ~ ParamNames[0] ~ ");\n";
			}
			else static if (useNamedParams)
			{
				// @RPCNamedParams: build JSON object with param names as keys
				code ~= "\t\tJSONFragment[string] __jsonrpc_params;\n";
				static foreach (i, P; Params)
				{
					code ~= "\t\t__jsonrpc_params[\"" ~ ParamNames[i]
						~ "\"] = JSONFragment(" ~ ParamNames[i] ~ ".toJson());\n";
				}
				code ~= "\t\treq.params = JSONFragment(__jsonrpc_params.toJson());\n";
			}
			else
			{
				// Default: positional array (existing behavior)
				code ~= "\t\treq.params = JSONFragment([";
				static foreach (i, P; Params)
				{
					static if (i > 0)
						code ~= ", ";
					code ~= "JSONFragment(" ~ ParamNames[i] ~ ".toJson())";
				}
				code ~= "].toJson());\n";
			}
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

// Test named params (object) — server accepts both formats for all methods
debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	interface Calculator
	{
		Promise!int add(int a, int b);
	}

	static class CalculatorImpl : Calculator
	{
		Promise!int add(int a, int b) { return resolve(a + b); }
	}

	auto impl = new CalculatorImpl();
	auto dispatcher = jsonRpcDispatcher!Calculator(impl);

	bool done;

	// Named params (object)
	auto req1 = JsonRpcRequest();
	req1.method = "add";
	req1.params = JSONFragment(`{"a": 10, "b": 20}`);
	req1.id = JSONFragment(`1`);

	dispatcher.dispatch(req1).then((JsonRpcResponse resp1) {
		assert(!resp1.isError, resp1.error.get.message);
		assert(resp1.getResult!int == 30);

		// Missing named param should error
		auto req2 = JsonRpcRequest();
		req2.method = "add";
		req2.params = JSONFragment(`{"a": 1, "x": 2}`);
		req2.id = JSONFragment(`2`);

		dispatcher.dispatch(req2).then((JsonRpcResponse resp2) {
			assert(resp2.isError);
			assert(resp2.error.get.code == JsonRpcErrorCode.invalidParams);

			// Array params still work (existing behavior)
			auto req3 = JsonRpcRequest();
			req3.method = "add";
			req3.params = JSONFragment(`[5, 6]`);
			req3.id = JSONFragment(`3`);

			dispatcher.dispatch(req3).then((JsonRpcResponse resp3) {
				assert(!resp3.isError, resp3.error.get.message);
				assert(resp3.getResult!int == 11);
				done = true;
			});
		});
	});

	socketManager.loop();
	assert(done, "Named params test did not complete");
}

// Test @RPCNamedParams on interface
debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	@RPCNamedParams
	interface NamedApi
	{
		Promise!int add(int a, int b);
	}

	static class NamedApiImpl : NamedApi
	{
		Promise!int add(int a, int b) { return resolve(a + b); }
	}

	auto impl = new NamedApiImpl();
	auto dispatcher = jsonRpcDispatcher!NamedApi(impl);

	bool done;

	// Server accepts object params
	auto req = JsonRpcRequest();
	req.method = "add";
	req.params = JSONFragment(`{"a": 7, "b": 3}`);
	req.id = JSONFragment(`1`);

	dispatcher.dispatch(req).then((JsonRpcResponse resp) {
		assert(!resp.isError, resp.error.get.message);
		assert(resp.getResult!int == 10);

		// Server still accepts array params too
		auto req2 = JsonRpcRequest();
		req2.method = "add";
		req2.params = JSONFragment(`[7, 3]`);
		req2.id = JSONFragment(`2`);

		dispatcher.dispatch(req2).then((JsonRpcResponse resp2) {
			assert(!resp2.isError, resp2.error.get.message);
			assert(resp2.getResult!int == 10);
			done = true;
		});
	});

	socketManager.loop();
	assert(done, "Named params interface test did not complete");
}

// Test @RPCFlatten with named params
debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	@RPCFlatten
	static struct Point
	{
		int x;
		int y;
	}

	@RPCNamedParams
	interface GeometryApi
	{
		Promise!int manhattan(Point p);
	}

	static class GeometryApiImpl : GeometryApi
	{
		Promise!int manhattan(Point p) { return resolve(p.x + p.y); }
	}

	auto impl = new GeometryApiImpl();
	auto dispatcher = jsonRpcDispatcher!GeometryApi(impl);

	bool done;

	// Object params with flattened struct — fields are top-level keys
	auto req = JsonRpcRequest();
	req.method = "manhattan";
	req.params = JSONFragment(`{"x": 3, "y": 4}`);
	req.id = JSONFragment(`1`);

	dispatcher.dispatch(req).then((JsonRpcResponse resp) {
		assert(!resp.isError, resp.error.get.message);
		assert(resp.getResult!int == 7);

		// Array params still work with flatten (positional tupleof)
		auto req2 = JsonRpcRequest();
		req2.method = "manhattan";
		req2.params = JSONFragment(`[5, 6]`);
		req2.id = JSONFragment(`2`);

		dispatcher.dispatch(req2).then((JsonRpcResponse resp2) {
			assert(!resp2.isError, resp2.error.get.message);
			assert(resp2.getResult!int == 11);
			done = true;
		});
	});

	socketManager.loop();
	assert(done, "RPCFlatten test did not complete");
}

// Test @RPCFlatten with positional (array) params — no @RPCNamedParams
debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	@RPCFlatten
	static struct Point
	{
		int x;
		int y;
	}

	interface FlatPosApi
	{
		Promise!int manhattan(Point p);
	}

	static class FlatPosApiImpl : FlatPosApi
	{
		Promise!int manhattan(Point p) { return resolve(p.x + p.y); }
	}

	auto impl = new FlatPosApiImpl();
	auto dispatcher = jsonRpcDispatcher!FlatPosApi(impl);

	bool done;

	// Flat positional: array elements map to struct fields
	auto req = JsonRpcRequest();
	req.method = "manhattan";
	req.params = JSONFragment(`[10, 20]`);
	req.id = JSONFragment(`1`);

	dispatcher.dispatch(req).then((JsonRpcResponse resp) {
		assert(!resp.isError, resp.error.get.message);
		assert(resp.getResult!int == 30);

		// Object params also work (server always accepts both)
		auto req2 = JsonRpcRequest();
		req2.method = "manhattan";
		req2.params = JSONFragment(`{"x": 1, "y": 2}`);
		req2.id = JSONFragment(`2`);

		dispatcher.dispatch(req2).then((JsonRpcResponse resp2) {
			assert(!resp2.isError, resp2.error.get.message);
			assert(resp2.getResult!int == 3);
			done = true;
		});
	});

	socketManager.loop();
	assert(done, "RPCFlatten positional test did not complete");
}

// Test per-method @RPCNamedParams in a mixed interface
debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager;

	interface MixedApi
	{
		Promise!int positional(int a, int b);

		@RPCNamedParams
		Promise!int named(int a, int b);
	}

	static class MixedApiImpl : MixedApi
	{
		Promise!int positional(int a, int b) { return resolve(a + b); }
		Promise!int named(int a, int b) { return resolve(a * b); }
	}

	auto impl = new MixedApiImpl();
	auto dispatcher = jsonRpcDispatcher!MixedApi(impl);

	bool done;

	// positional method with array params
	auto req1 = JsonRpcRequest();
	req1.method = "positional";
	req1.params = JSONFragment(`[3, 4]`);
	req1.id = JSONFragment(`1`);

	dispatcher.dispatch(req1).then((JsonRpcResponse resp1) {
		assert(!resp1.isError, resp1.error.get.message);
		assert(resp1.getResult!int == 7);

		// named method with object params
		auto req2 = JsonRpcRequest();
		req2.method = "named";
		req2.params = JSONFragment(`{"a": 3, "b": 4}`);
		req2.id = JSONFragment(`2`);

		dispatcher.dispatch(req2).then((JsonRpcResponse resp2) {
			assert(!resp2.isError, resp2.error.get.message);
			assert(resp2.getResult!int == 12);

			// named method also accepts array params (server accepts both)
			auto req3 = JsonRpcRequest();
			req3.method = "named";
			req3.params = JSONFragment(`[5, 6]`);
			req3.id = JSONFragment(`3`);

			dispatcher.dispatch(req3).then((JsonRpcResponse resp3) {
				assert(!resp3.isError, resp3.error.get.message);
				assert(resp3.getResult!int == 30);
				done = true;
			});
		});
	});

	socketManager.loop();
	assert(done, "Mixed API test did not complete");
}

// Round-trip test: client with @RPCNamedParams serializes object params,
// server deserializes by name, verifying the __jsonrpc_params code path.
debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpConnection, TcpServer;
	import ae.net.jsonrpc.codec : JsonRpcServerCodec;
	import ae.net.jsonrpc.ndjson : lineDelimitedJsonRpcConnection;

	@RPCNamedParams
	interface NamedRoundTripApi
	{
		Promise!int subtract(int a, int b);
	}

	static class NamedRoundTripImpl : NamedRoundTripApi
	{
		Promise!int subtract(int a, int b) { return resolve(a - b); }
	}

	auto dispatcher = jsonRpcDispatcher!NamedRoundTripApi(new NamedRoundTripImpl());
	auto tcpServer = new TcpServer();
	tcpServer.handleAccept = (TcpConnection conn) {
		auto codec = new JsonRpcServerCodec(lineDelimitedJsonRpcConnection(conn));
		codec.handleRequest = &dispatcher.dispatch;
	};
	auto port = tcpServer.listen(0, "127.0.0.1");

	auto clientConn = new TcpConnection();
	bool done;

	clientConn.handleConnect = {
		auto conn = lineDelimitedJsonRpcConnection(clientConn);
		auto client = new JsonRpcClient!NamedRoundTripApi(conn);

		// Client sends {"a": 10, "b": 3} — server looks up by name
		client.subtract(10, 3).then((int r) {
			assert(r == 7);
			done = true;
			conn.disconnect();
			tcpServer.close();
		});
	};

	clientConn.connect("127.0.0.1", port);
	socketManager.loop();
	assert(done, "Named params round-trip test did not complete");
}

// ************************************************************************

version (HAVE_JSONRPC_PEER)
debug(ae_unittest) unittest
{
	// Integration test, Phase 1: D acts as HTTP JSON-RPC server.
	// Validates that the D server correctly handles both positional and named
	// params, and @RPCFlatten struct params from an external Python peer
	// (jsonrpclib-pelix).
	import std.process : environment;
	if (environment.get("JSONRPC_TEST_MODE", "") != "server") return;

	import ae.net.asockets : socketManager;
	import ae.net.http.common : HttpRequest;
	import ae.net.http.server : HttpServer, HttpServerConnection;
	import ae.net.jsonrpc.codec : JsonRpcServerCodec;
	import ae.net.jsonrpc.http : HttpServerJsonRpcConnection;
	import std.file : fileWrite = write;

	@RPCFlatten struct Vec2 { int x; int y; }

	interface CalcApi
	{
		Promise!int add(int a, int b);
		Promise!int addVec(Vec2 v);
	}

	static class CalcImpl : CalcApi
	{
		Promise!int add(int a, int b) { return resolve(a + b); }
		Promise!int addVec(Vec2 v)    { return resolve(v.x + v.y); }
	}

	auto dispatcher = jsonRpcDispatcher!CalcApi(new CalcImpl());
	auto server = new HttpServer();
	server.handleRequest = (HttpRequest request, HttpServerConnection conn) {
		auto rpcConn = new HttpServerJsonRpcConnection(request, conn);
		auto codec = new JsonRpcServerCodec(rpcConn);
		codec.handleRequest = &dispatcher.dispatch;
	};
	auto port = server.listen(0, "127.0.0.1");

	fileWrite(environment.get("JSONRPC_READY_FILE", "/tmp/jsonrpc_ready"), port.to!string);

	socketManager.loop();
}

version (HAVE_JSONRPC_PEER)
debug(ae_unittest) unittest
{
	// Integration test, Phase 2: D acts as HTTP JSON-RPC client.
	// Validates that the D client with @RPCNamedParams sends correct wire
	// format understood by an external Python peer (jsonrpclib-pelix).
	import std.process : environment;
	if (environment.get("JSONRPC_TEST_MODE", "") != "client") return;

	import ae.net.asockets : socketManager;
	import ae.net.jsonrpc.http : HttpJsonRpcConnection;

	auto port = environment.get("JSONRPC_SERVER_PORT", "8080");

	@RPCNamedParams
	interface CalcClient
	{
		Promise!int add(int a, int b);
	}

	bool done;
	auto conn = new HttpJsonRpcConnection("http://127.0.0.1:" ~ port);
	auto client = new JsonRpcClient!CalcClient(conn);

	client.add(10, 7).then((int result) {
		assert(result == 17, "Expected 17 for add(10, 7) with named params, got " ~ result.to!string);
		done = true;
		conn.disconnect();
	});

	socketManager.loop();
	assert(done, "D client integration test did not complete");
}
