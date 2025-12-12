/**
 * JSON-RPC 2.0 support.
 *
 * This package provides a complete JSON-RPC 2.0 implementation with:
 *
 * - Core protocol data structures and parsing (`ae.utils.jsonrpc`)
 * - Multiple connection implementations (HTTP, stdio, generic IConnection)
 * - D interface wrappers for client/server generation
 *
 * All interface methods must return `Promise!T`. For synchronous implementations,
 * use `resolve(value)` to create an immediately fulfilled promise.
 *
 * Example server using D interface:
 * ---
 * interface Calculator
 * {
 *     Promise!int add(int a, int b);
 *     Promise!int subtract(int a, int b);
 * }
 *
 * class CalculatorImpl : Calculator
 * {
 *     Promise!int add(int a, int b) { return resolve(a + b); }
 *     Promise!int subtract(int a, int b) { return resolve(a - b); }
 * }
 *
 * // Simple server setup over TCP:
 * auto dispatcher = jsonRpcDispatcher!Calculator(new CalculatorImpl());
 * auto tcpServer = new TcpServer();
 * tcpServer.handleAccept = (conn) {
 *     auto codec = new JsonRpcServerCodec(lineDelimitedJsonRpcConnection(conn));
 *     codec.handleRequest = &dispatcher.dispatch;
 * };
 * tcpServer.listen(8080);
 * ---
 *
 * Example client using D interface:
 * ---
 * auto conn = new TcpConnection();
 * conn.handleConnect = {
 *     auto rpcConn = lineDelimitedJsonRpcConnection(conn);
 *     auto client = jsonRpcClient!Calculator(rpcConn);
 *
 *     client.add(2, 3).then((int result) {
 *         assert(result == 5);
 *     });
 * };
 * conn.connect("localhost", 8080);
 * ---
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

module ae.net.jsonrpc;

// Core protocol
public import ae.utils.jsonrpc;

// Transport/framing
public import ae.net.jsonrpc.ndjson;
public import ae.net.jsonrpc.http;

version (Posix)
	public import ae.net.jsonrpc.stdio;

// Codec (encoding/decoding)
public import ae.net.jsonrpc.codec;

// Binding (D interface wrappers)
public import ae.net.jsonrpc.binding;
