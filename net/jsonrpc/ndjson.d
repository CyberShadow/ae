/**
 * JSON-RPC over NDJSON (Newline Delimited JSON) transport.
 *
 * Provides JSON-RPC transport using newline-delimited JSON framing,
 * suitable for streaming connections like TCP or Unix sockets.
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

module ae.net.jsonrpc.ndjson;

import std.exception : assumeUnique;

import ae.net.asockets;
import ae.net.jsonrpc.codec : JsonRpcServerCodec;
import ae.sys.data : Data;
import ae.utils.array : asBytes;
import ae.utils.json;
import ae.utils.jsonrpc;
import ae.utils.text : asText;

/// Create a JSON-RPC connection with newline-delimited framing.
///
/// Wraps a connection with LineBufferedAdapter for newline-delimited
/// JSON-RPC messages. The returned connection:
/// - Delivers complete messages via handleReadData
/// - Automatically appends newline when sending
///
/// Example:
/// ---
/// auto conn = lineDelimitedJsonRpcConnection(tcpConn);
/// auto codec = new JsonRpcServerCodec(conn);
/// codec.handleRequest = &dispatcher.dispatch;
/// ---
LineBufferedAdapter lineDelimitedJsonRpcConnection(IConnection conn)
{
	return new LineBufferedAdapter(conn, "\n");
}

// ************************************************************************

// Test JSON-RPC full stack: TCP transport, codec, dispatcher, and client proxy.
// Demonstrates idiomatic usage with multiple methods and @RPCName attribute.
debug(ae_unittest) unittest
{
	import ae.net.jsonrpc.binding : jsonRpcDispatcher, jsonRpcClient, RPCName;
	import ae.utils.promise : Promise, resolve;

	// Define interface - all methods must return Promise!T
	interface Calculator
	{
		Promise!int add(int a, int b);
		@RPCName("math.multiply") Promise!int multiply(int a, int b);
	}

	// Server implementation
	static class CalculatorImpl : Calculator
	{
		Promise!int add(int a, int b)
		{
			return resolve(a + b);
		}

		Promise!int multiply(int a, int b)
		{
			return resolve(a * b);
		}
	}

	// Server setup
	auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());
	auto tcpServer = new TcpServer();
	tcpServer.handleAccept = (TcpConnection conn) {
		auto codec = new JsonRpcServerCodec(lineDelimitedJsonRpcConnection(conn));
		codec.handleRequest = &dispatcher.dispatch;
	};
	auto port = tcpServer.listen(0, "127.0.0.1");

	// Client setup
	auto clientConn = new TcpConnection();
	bool ok;

	clientConn.handleConnect = {
		auto conn = lineDelimitedJsonRpcConnection(clientConn);
		auto client = jsonRpcClient!Calculator(conn);

		// Client implements the interface - call methods directly
		client.add(2, 3).then((int result) {
			assert(result == 5, "Expected 5");

			// Test @RPCName - D method name differs from wire method name
			client.multiply(6, 7).then((int result2) {
				assert(result2 == 42, "Expected 42");
				ok = true;
				conn.disconnect();
				tcpServer.close();
			});
		});
	};

	clientConn.connect("127.0.0.1", port);

	socketManager.loop();
	assert(ok, "Test did not complete");
}

// Test JSON-RPC batch request
debug(ae_unittest) unittest
{
	import ae.net.jsonrpc.binding : jsonRpcDispatcher;
	import ae.utils.promise : Promise, resolve;

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

	// Set up TCP server
	auto tcpServer = new TcpServer();
	auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());

	tcpServer.handleAccept = (TcpConnection conn) {
		auto codec = new JsonRpcServerCodec(lineDelimitedJsonRpcConnection(conn));
		codec.handleRequest = &dispatcher.dispatch;
	};

	auto port = tcpServer.listen(0, "127.0.0.1");

	// Set up client - manually send raw batch request
	auto clientConn = new TcpConnection();
	bool ok;

	clientConn.handleConnect = {
		auto conn = lineDelimitedJsonRpcConnection(clientConn);

		conn.handleReadData = (Data data) nothrow {
			try
			{
				auto message = data.toGC.asText.assumeUnique;
				auto parsed = parseResponses(message);
				assert(parsed.isBatch, "Expected batch response");
				assert(parsed.responses.length == 2, "Expected 2 responses");
				assert(parsed.responses[0].getResult!int == 3, "Expected 3");
				assert(parsed.responses[1].getResult!int == 7, "Expected 7");

				ok = true;
				conn.disconnect();
				tcpServer.close();
			}
			catch (Exception e)
			{
				assert(false, e.msg);
			}
		};

		// Send batch request
		JsonRpcRequest[] batch = [
			JsonRpcRequest.create("add", JSONFragment(`1`), 1, 2),
			JsonRpcRequest.create("add", JSONFragment(`2`), 3, 4),
		];
		conn.send(Data(formatBatch(batch).asBytes));
	};

	clientConn.connect("127.0.0.1", port);

	socketManager.loop();
	assert(ok, "Test did not complete");
}

// Test error marshalling end-to-end using async/await
debug(ae_unittest) unittest
{
	import ae.net.jsonrpc.binding : jsonRpcDispatcher, jsonRpcClient;
	import ae.utils.promise : Promise, resolve, reject;
	import ae.utils.promise.await : async, await;

	interface Calculator
	{
		Promise!int divide(int a, int b);
	}

	static class CalculatorImpl : Calculator
	{
		Promise!int divide(int a, int b)
		{
			if (b == 0)
				return reject!int(new Exception("Division by zero"));
			return resolve(a / b);
		}
	}

	// Set up TCP server
	auto tcpServer = new TcpServer();
	auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());

	tcpServer.handleAccept = (TcpConnection conn) {
		auto codec = new JsonRpcServerCodec(lineDelimitedJsonRpcConnection(conn));
		codec.handleRequest = &dispatcher.dispatch;
	};

	auto port = tcpServer.listen(0, "127.0.0.1");

	// Set up client
	auto clientConn = new TcpConnection();
	bool ok;

	clientConn.handleConnect = {
		auto conn = lineDelimitedJsonRpcConnection(clientConn);
		auto client = jsonRpcClient!Calculator(conn);

		// Use async/await to test error handling in fiber context
		async({
			// Test successful division
			auto result = client.divide(10, 2).await;
			assert(result == 5, "Expected 5");

			// Test division by zero - should throw
			bool caught = false;
			try
			{
				client.divide(10, 0).await;
				assert(false, "Expected exception");
			}
			catch (Exception e)
			{
				caught = true;
				assert(e.msg == "Division by zero", "Expected 'Division by zero', got: " ~ e.msg);
			}
			assert(caught, "Exception was not caught");

			ok = true;
			conn.disconnect();
			tcpServer.close();
		});
	};

	clientConn.connect("127.0.0.1", port);

	socketManager.loop();
	assert(ok, "Test did not complete");
}
