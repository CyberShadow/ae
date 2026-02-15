/**
 * HTTP Server-Sent Events (SSE).
 *
 * Sends events over an HTTP connection using the `text/event-stream` format,
 * layered on top of chunked transfer encoding.
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

module ae.net.http.sse;

import core.time : Duration;

import std.conv : to;

import ae.net.asockets : IConnection, DisconnectType;
import ae.sys.data : Data;
import ae.utils.array : asBytes;

/// An SSE (Server-Sent Events) connection that formats and sends events
/// over an underlying connection (typically a `ChunkedEncodingAdapter`).
///
/// SSE is a unidirectional protocol — this class only sends events, it does
/// not read from the connection. Each method sends a complete SSE message
/// (terminated by a blank line) as a single write to the underlying connection.
///
/// Usage:
/// ---
/// server.handleRequest = (request, conn) {
///     auto sse = startSseResponse(conn);
///     sse.sendEvent("hello");
///     sse.sendEvent(`{"temp": 42}`, "update");
///     sse.sendComment();  // keep-alive
///     sse.disconnect("done");
/// };
/// ---
///
/// See_Also: `startSseResponse` for a convenience function that sets up
/// the response headers and chunked encoding.
class SseConnection
{
	private IConnection conn;

	this(IConnection conn)
	{
		this.conn = conn;
	}

	/// Send an event with optional type and id fields.
	///
	/// Multi-line `data` is split on `'\n'`, and each line is sent as a
	/// separate `data:` field.
	void sendEvent(scope const(char)[] data, scope const(char)[] event = null, scope const(char)[] id = null)
	{
		char[] buf;

		if (event.length > 0)
		{
			buf ~= "event: ";
			buf ~= event;
			buf ~= '\n';
		}

		if (id.length > 0)
		{
			buf ~= "id: ";
			buf ~= id;
			buf ~= '\n';
		}

		// Split data on newlines; each line gets its own "data: " prefix.
		size_t start = 0;
		foreach (i, c; data)
		{
			if (c == '\n')
			{
				buf ~= "data: ";
				buf ~= data[start .. i];
				buf ~= '\n';
				start = i + 1;
			}
		}
		buf ~= "data: ";
		buf ~= data[start .. $];
		buf ~= "\n\n";

		conn.send(Data(cast(const(ubyte)[]) buf));
	}

	/// Send a comment (typically used as a keep-alive ping).
	///
	/// Format: `": <text>\n\n"` (or `":\n\n"` if `text` is empty).
	void sendComment(scope const(char)[] text = null)
	{
		if (text.length > 0)
		{
			char[] buf;
			buf ~= ": ";
			buf ~= text;
			buf ~= "\n\n";
			conn.send(Data(cast(const(ubyte)[]) buf));
		}
		else
			conn.send(Data(":\n\n".asBytes));
	}

	/// Send a retry directive telling the client to wait the given interval
	/// before reconnecting.
	///
	/// Format: `"retry: <ms>\n\n"`
	void sendRetry(Duration interval)
	{
		auto ms = interval.total!"msecs";
		auto str = "retry: " ~ ms.to!string ~ "\n\n";
		conn.send(Data(cast(const(ubyte)[]) str));
	}

	/// Close the event stream.
	void disconnect(string reason = IConnection.defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		conn.disconnect(reason, type);
	}
}

import ae.net.http.chunked : startChunkedResponse;
import ae.net.http.common : HttpResponse, HttpStatusCode;
import ae.net.http.server : BaseHttpServerConnection;

/// Start an SSE response on the given HTTP server connection.
///
/// Sends response headers with `Content-Type: text/event-stream`,
/// `Cache-Control: no-cache`, and `Transfer-Encoding: chunked`, then returns
/// an `SseConnection`. Events sent to the returned connection are formatted
/// as SSE and chunked-encoded.
///
/// Usage:
/// ---
/// server.handleRequest = (request, conn) {
///     auto sse = startSseResponse(conn);
///     sse.sendEvent("hello");
///     sse.disconnect("done");
/// };
/// ---
///
/// See_Also: `startChunkedResponse` which this builds on.
SseConnection startSseResponse(BaseHttpServerConnection conn, HttpResponse response = null)
{
	if (response is null)
	{
		response = new HttpResponse();
		response.status = HttpStatusCode.OK;
	}
	response.headers["Content-Type"] = "text/event-stream";
	response.headers["Cache-Control"] = "no-cache";
	auto chunked = startChunkedResponse(conn, response);
	return new SseConnection(chunked);
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : ConnectionState;
	import ae.sys.dataset : bytes, joinToGC;
	import ae.utils.array : as;

	// Collect data sent through the SSE connection.
	Data[] sent;

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

	auto sse = new SseConnection(inner);

	// Simple data-only event.
	sse.sendEvent("hello");
	auto result = sent.bytes[].joinToGC().as!string;
	assert(result == "data: hello\n\n", result);

	// Event with type and id.
	sent = null;
	sse.sendEvent("payload", "update", "42");
	result = sent.bytes[].joinToGC().as!string;
	assert(result == "event: update\nid: 42\ndata: payload\n\n", result);

	// Multi-line data.
	sent = null;
	sse.sendEvent("line1\nline2\nline3");
	result = sent.bytes[].joinToGC().as!string;
	assert(result == "data: line1\ndata: line2\ndata: line3\n\n", result);

	// Comment (keep-alive).
	sent = null;
	sse.sendComment();
	result = sent.bytes[].joinToGC().as!string;
	assert(result == ":\n\n", result);

	// Comment with text.
	sent = null;
	sse.sendComment("ping");
	result = sent.bytes[].joinToGC().as!string;
	assert(result == ": ping\n\n", result);

	// Retry directive.
	sent = null;
	import core.time : seconds;
	sse.sendRetry(30.seconds);
	result = sent.bytes[].joinToGC().as!string;
	assert(result == "retry: 30000\n\n", result);
}
