/**
 * HTTP chunked transfer encoding.
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

module ae.net.http.chunked;

import ae.net.asockets : ConnectionAdapter, IConnection, DisconnectType, ConnectionState;
import ae.sys.data : Data;
import ae.sys.dataset : bytes;
import ae.utils.array : asBytes, asSlice;

/// Adapter which encodes outgoing data as HTTP chunked transfer encoding.
///
/// Each `send` call produces one HTTP chunk. Disconnecting the connection
/// sends the terminal chunk (`0\r\n\r\n`).
///
/// Can be composed with other adapters:
/// ---
/// Application → ChunkedEncodingAdapter → TimeoutAdapter → TcpConnection
/// ---
///
/// See_Also: `startChunkedResponse` for a convenience function that
/// sets up a chunked response on an HTTP server connection.
class ChunkedEncodingAdapter : ConnectionAdapter
{
	this(IConnection next)
	{
		super(next);
	}

	alias send = typeof(super).send;

	override void send(scope Data[] data, int priority)
	{
		auto totalLen = data.bytes.length;
		if (totalLen == 0)
			return;

		// Build chunk header: "<hex-length>\r\n"
		char[size_t.sizeof * 2 + 2] buf;
		int pos = cast(int) buf.length;
		buf[--pos] = '\n';
		buf[--pos] = '\r';
		auto n = totalLen;
		do
		{
			buf[--pos] = "0123456789ABCDEF"[n & 0xF];
			n >>= 4;
		}
		while (n);

		next.send(Data(cast(const(ubyte)[]) buf[pos .. $]), priority);
		next.send(data, priority);
		next.send(Data("\r\n".asBytes), priority);
	}

	override void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		if (next.state == ConnectionState.connected)
			next.send(Data("0\r\n\r\n".asBytes));
		super.disconnect(reason, type);
	}
}

import ae.net.http.common : HttpResponse, HttpStatusCode;
import ae.net.http.server : BaseHttpServerConnection;

/// Start a chunked transfer-encoded response on the given HTTP server connection.
///
/// Sends the response headers with `Transfer-Encoding: chunked` and returns
/// an `IConnection`. Data sent to the returned connection is chunked-encoded.
/// Disconnecting it sends the terminal chunk and closes the connection.
///
/// This uses `upgrade` internally, so the HTTP connection is fully detached
/// and will not accept further requests (no keep-alive).
///
/// Usage:
/// ---
/// server.handleRequest = (request, conn) {
///     auto response = new HttpResponse();
///     response.status = HttpStatusCode.OK;
///     response.headers["Content-Type"] = "text/event-stream";
///     auto stream = startChunkedResponse(conn, response);
///
///     // stream is now an IConnection
///     stream.send(Data("hello".asBytes));
///     // ...
///     stream.disconnect(); // sends terminal chunk
/// };
/// ---
///
/// See_Also: The WebSockets implementation in `ae.net.http.websocket`
/// which uses the same `upgrade` pattern.
ChunkedEncodingAdapter startChunkedResponse(BaseHttpServerConnection conn, HttpResponse response)
{
	response.headers["Transfer-Encoding"] = "chunked";
	conn.persistent = false;
	conn.sendHeaders(response);
	auto upgrade = conn.upgrade();
	return new ChunkedEncodingAdapter(upgrade.conn);
}

debug(ae_unittest) unittest
{
	import ae.sys.dataset : joinToGC;
	import ae.utils.array : as;

	// Collect data sent through the adapter.
	Data[] sent;

	// Use a ChunkedEncodingAdapter over a mock connection.
	auto inner = new class IConnection
	{
		@property ConnectionState state() { return ConnectionState.connected; }
		void send(scope Data[] data, int priority)
		{
			foreach (d; data)
				sent ~= d;
		}
		void disconnect(string reason, DisconnectType type) {}
		@property void handleConnect(ConnectHandler value) {}
		@property void handleReadData(ReadDataHandler value) {}
		@property void handleDisconnect(DisconnectHandler value) {}
		@property void handleBufferFlushed(BufferFlushedHandler value) {}
	};

	auto adapter = new ChunkedEncodingAdapter(inner);

	// Send "Hello" (5 bytes).
	adapter.send(Data("Hello".asBytes));
	auto result = sent.bytes[].joinToGC().as!string;
	assert(result == "5\r\nHello\r\n", result);

	// Send multiple fragments as one chunk.
	sent = null;
	adapter.send([Data("ab".asBytes), Data("cd".asBytes)]);
	result = sent.bytes[].joinToGC().as!string;
	assert(result == "4\r\nabcd\r\n", result);

	// Empty send produces no output.
	sent = null;
	adapter.send(Data());
	assert(sent.length == 0);
}
