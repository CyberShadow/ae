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
import ae.sys.dataset : bytes, DataVec, joinToGC;
import ae.utils.array : as, asBytes, asSlice;

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

/// Adapter which decodes incoming chunked transfer-encoded data.
///
/// Buffers incoming data and emits decoded chunks to `readDataHandler`.
/// When the terminal chunk (`0\r\n\r\n`) is received, fires
/// `handleChunkedFinished` and then disconnects.
///
/// Chunk extensions and trailers are parsed and discarded.
class ChunkedDecodingAdapter : ConnectionAdapter
{
	this(IConnection next)
	{
		super(next);
	}

	/// Called when the terminal chunk has been received and all
	/// body data has been delivered via `handleReadData`.
	void delegate() handleChunkedFinished;

	public override void onReadData(Data data)
	{
		buffer ~= data;
		decodeChunks();
	}

private:
	DataVec buffer;

	/// Current parser state.
	enum State { chunkSize, chunkData, chunkDataCRLF, chunkTrailer, finished }
	State state;

	size_t currentChunkRemaining; // bytes remaining in the current chunk body

	void decodeChunks()
	{
		while (buffer.bytes.length > 0 && state != State.finished)
		{
			final switch (state)
			{
				case State.chunkSize:
					if (!parseChunkSize())
						return; // need more data
					break;

				case State.chunkData:
					if (!consumeChunkData())
						return; // need more data
					break;

				case State.chunkDataCRLF:
					if (!skipChunkDataCRLF())
						return; // need more data
					break;

				case State.chunkTrailer:
					if (!skipTrailers())
						return; // need more data
					break;

				case State.finished:
					return;
			}
		}
	}

	/// Parse a chunk-size line: `<hex-size>[;extensions]\r\n`
	/// Returns false if we need more data.
	bool parseChunkSize()
	{
		auto lineEnd = findCRLF();
		if (lineEnd < 0)
			return false;

		// Extract the line as a string
		auto line = buffer.bytes[0 .. lineEnd].joinToGC().as!string;
		buffer = buffer.bytes[lineEnd + 2 .. buffer.bytes.length]; // skip past \r\n

		// Strip chunk extensions (everything after ';')
		auto semiPos = indexOf(line, ';');
		auto sizeStr = semiPos >= 0 ? line[0 .. semiPos] : line;

		// Parse hex size
		currentChunkRemaining = 0;
		foreach (c; sizeStr)
		{
			int digit;
			if (c >= '0' && c <= '9')
				digit = c - '0';
			else if (c >= 'a' && c <= 'f')
				digit = 10 + c - 'a';
			else if (c >= 'A' && c <= 'F')
				digit = 10 + c - 'A';
			else
				throw new Exception("Invalid character in chunk size: " ~ sizeStr);
			currentChunkRemaining = currentChunkRemaining * 16 + digit;
		}

		if (currentChunkRemaining == 0)
		{
			// Terminal chunk — skip trailers
			state = State.chunkTrailer;
		}
		else
			state = State.chunkData;

		return true;
	}

	/// Consume chunk body data.
	/// Returns false if we need more data.
	bool consumeChunkData()
	{
		auto available = buffer.bytes.length;
		if (available == 0)
			return false;

		if (available < currentChunkRemaining)
		{
			// Deliver what we have so far
			auto partial = buffer.bytes[0 .. available];
			buffer = DataVec.init;
			currentChunkRemaining -= available;
			foreach (ref d; partial[])
				super.onReadData(d);
			return false;
		}

		// We have the full chunk body (or the remaining portion)
		if (currentChunkRemaining > 0)
		{
			auto chunk = buffer.bytes[0 .. currentChunkRemaining];
			buffer = buffer.bytes[currentChunkRemaining .. buffer.bytes.length];
			foreach (ref d; chunk[])
				super.onReadData(d);
			currentChunkRemaining = 0;
		}

		state = State.chunkDataCRLF;
		return true;
	}

	/// Skip the \r\n after chunk data.
	/// Returns false if we need more data.
	bool skipChunkDataCRLF()
	{
		if (buffer.bytes.length < 2)
			return false;

		buffer = buffer.bytes[2 .. buffer.bytes.length];
		state = State.chunkSize;
		return true;
	}

	/// Skip trailer headers after the terminal chunk.
	/// Trailers end with an empty line (\r\n).
	/// Returns false if we need more data.
	bool skipTrailers()
	{
		// Look for \r\n — either an empty line (end of trailers)
		// or a trailer header line to skip.
		while (true)
		{
			auto lineEnd = findCRLF();
			if (lineEnd < 0)
				return false;

			if (lineEnd == 0)
			{
				// Empty line — end of trailers (and end of chunked message)
				buffer = buffer.bytes[2 .. buffer.bytes.length];
				state = State.finished;
				if (handleChunkedFinished)
					handleChunkedFinished();
				return true;
			}

			// Skip this trailer line
			buffer = buffer.bytes[lineEnd + 2 .. buffer.bytes.length];
		}
	}

	/// Find index of first \r\n in the buffer, or -1.
	sizediff_t findCRLF()
	{
		auto len = buffer.bytes.length;
		if (len < 2)
			return -1;
		auto bts = buffer.bytes;
		foreach (i; 0 .. len - 1)
		{
			if (bts[i] == '\r' && bts[i + 1] == '\n')
				return cast(sizediff_t) i;
		}
		return -1;
	}

	static sizediff_t indexOf(string s, char c)
	{
		foreach (i, ch; s)
			if (ch == c)
				return cast(sizediff_t) i;
		return -1;
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

// Test ChunkedDecodingAdapter
debug(ae_unittest) unittest
{
	import ae.net.asockets : IConnection;

	// Collect decoded data and finished signal.
	Data[] received;
	bool finished;

	alias ReadDataHandler = void delegate(Data);
	alias ConnectHandler = void delegate();
	alias DisconnectHandler = void delegate(string, DisconnectType);
	alias BufferFlushedHandler = void delegate();

	auto inner = new class IConnection
	{
		ReadDataHandler rdh;

		@property ConnectionState state() { return ConnectionState.connected; }
		void send(scope Data[] data, int priority) {}
		void disconnect(string reason, DisconnectType type) {}
		@property void handleConnect(ConnectHandler value) {}
		@property void handleReadData(ReadDataHandler value) { rdh = value; }
		@property void handleDisconnect(DisconnectHandler value) {}
		@property void handleBufferFlushed(BufferFlushedHandler value) {}
	};

	auto adapter = new ChunkedDecodingAdapter(inner);
	adapter.handleReadData = (Data d) { received ~= d; };
	adapter.handleChunkedFinished = () { finished = true; };

	// Feed a complete chunked body in one go:
	// 5 bytes "Hello", then 7 bytes " World!", then terminal chunk.
	inner.rdh(Data(("5\r\nHello\r\n7\r\n World!\r\n0\r\n\r\n").asBytes));

	auto result = received.bytes[].joinToGC().as!string;
	assert(result == "Hello World!", result);
	assert(finished);

	// Test incremental feeding: data arrives byte-by-byte.
	received = null;
	finished = false;

	adapter = new ChunkedDecodingAdapter(inner);
	adapter.handleReadData = (Data d) { received ~= d; };
	adapter.handleChunkedFinished = () { finished = true; };

	auto chunked = "A\r\n0123456789\r\n0\r\n\r\n";
	foreach (i, c; chunked)
	{
		ubyte[1] b = [cast(ubyte) c];
		inner.rdh(Data(b[]));
	}

	result = received.bytes[].joinToGC().as!string;
	assert(result == "0123456789", result);
	assert(finished);

	// Test chunk extensions are ignored.
	received = null;
	finished = false;

	adapter = new ChunkedDecodingAdapter(inner);
	adapter.handleReadData = (Data d) { received ~= d; };
	adapter.handleChunkedFinished = () { finished = true; };

	inner.rdh(Data("3;ext=val\r\nabc\r\n0\r\n\r\n".asBytes));

	result = received.bytes[].joinToGC().as!string;
	assert(result == "abc", result);
	assert(finished);

	// Test trailers are skipped.
	received = null;
	finished = false;

	adapter = new ChunkedDecodingAdapter(inner);
	adapter.handleReadData = (Data d) { received ~= d; };
	adapter.handleChunkedFinished = () { finished = true; };

	inner.rdh(Data("2\r\nOK\r\n0\r\nTrailer: value\r\n\r\n".asBytes));

	result = received.bytes[].joinToGC().as!string;
	assert(result == "OK", result);
	assert(finished);
}
