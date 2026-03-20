/**
 * WebSockets implementation.
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

module ae.net.http.websocket;

version (ae_with_zlib) // Explicit override
	enum haveZlib = true;
else
version (ae_without_zlib) // Explicit override
	enum haveZlib = false;
else
version (Have_ae) // Building with Dub
{
	version (Have_ae_zlib) // Using ae:zlib
		enum haveZlib = true;
	else
		enum haveZlib = false;
}
else // Not building with Dub
	enum haveZlib = true; // Pull in zlib by default

import core.time : Duration, minutes, seconds;

import std.conv : to;
import std.exception : enforce;
import std.random : Mt19937_64, uniform;
import std.uni : icmp;

import ae.net.asockets : ConnectionAdapter, IConnection, DisconnectType, ConnectionState, now;
import ae.sys.data : Data;
import ae.sys.dataset : joinData, DataVec, bytes;
import ae.sys.osrng : genRandom;
import ae.sys.timing : TimerTask, mainTimer, Timer;
import ae.utils.array : as, asBytes, asStaticBytes, asSlice;
import ae.utils.bitmanip : NetworkByteOrder;

static if (haveZlib)
{
	import zlib = ae.utils.zlib;
}

/// Compression mode for WebSocket permessage-deflate (RFC 7692).
enum PerMessageDeflate
{
	disable,   /// Never use compression, even if built with zlib.
	negotiate, /// Use compression if peer supports it.
	force,     /// Require compression; fail if peer does not support it.
}

/// Adapter which decodes/encodes WebSocket frames.
class WebSocketAdapter : ConnectionAdapter
{
	enum Flags : ubyte
	{
		fin  = 0b1000_0000,
		rsv1 = 0b0100_0000,
		rsv2 = 0b0010_0000,
		rsv3 = 0b0001_0000,

		opMask              = 0xF,

		// Non-control frames
		opContinuationFrame = 0x0,
		opTextFrame         = 0x1,
		opBinaryFrame       = 0x2,

		// Control frames
		opClose             = 0x8,
		opPing              = 0x9,
		opPong              = 0xA,
	}

	enum LengthByte : ubyte
	{
		init          = 0x00,
		lengthMask    = 0x7F,
		lengthIs16Bit = 0x7E,
		lengthIs64Bit = 0x7F,
		masked        = 0x80,
	}

	bool useMask, requireMask, sendBinary;

	Duration idleTimeout;

	/// Whether permessage-deflate compression is active on this connection.
	@property bool deflateEnabled() const
	{
		static if (haveZlib)
			return useDeflate_;
		else
			return false;
	}

	this(
		IConnection next,
		bool useMask = false,
		bool requireMask = false,
		bool sendBinary = true,
		Duration idleTimeout = 1.minutes,
		bool useDeflate = false,
		int compressionLevel = -1,
		bool noDeflateContextTakeover = false,
		bool noInflateContextTakeover = false,
	)
	{
		super(next);
		this.useMask = useMask;
		this.requireMask = requireMask;
		this.sendBinary = sendBinary;
		this.idleTimeout = idleTimeout;

		if (useMask)
		{
			ubyte[8] bytes;
			genRandom(bytes);
			this.maskRNG = Mt19937_64(bytes.as!ulong);
		}

		idleTask = new TimerTask();
		idleTask.handleTask = &onIdle;
		mainTimer.add(idleTask, now + idleTimeout);

		static if (haveZlib)
		{
			this.useDeflate_ = useDeflate;
			this.noDeflateContextTakeover_ = noDeflateContextTakeover;
			this.noInflateContextTakeover_ = noInflateContextTakeover;
			if (useDeflate)
			{
				deflater.init(zlib.ZlibOptions(compressionLevel, 15, zlib.ZlibMode.raw));
				inflater.init(zlib.ZlibOptions(zlib.ZlibOptions.init.deflateLevel, 15, zlib.ZlibMode.raw));
			}
		}
		else
		{
			if (useDeflate)
				throw new Exception("WebSocket compression not available (built without zlib)");
		}
	}

	final void send(Data message)
	{
		send(message.asSlice);
	}

	alias send = IConnection.send; /// ditto

	override void send(scope Data[] message, int priority)
	{
		static if (haveZlib)
		{
			if (useDeflate_)
			{
				auto compressed = compressMessage(message);
				sendFrame(
					cast(Flags)(
						(sendBinary ? Flags.opBinaryFrame : Flags.opTextFrame) |
						Flags.rsv1 |
						Flags.fin
					),
					compressed,
				);
				return;
			}
		}

		foreach (fragmentIndex, fragment; message)
		{
			Flags flags;
			if (fragmentIndex == 0)
				flags = sendBinary ? Flags.opBinaryFrame : Flags.opTextFrame;
			else
				flags = Flags.opContinuationFrame;
			if (fragmentIndex + 1 == message.length)
				flags |= Flags.fin;

			sendFrame(flags, fragment);
		}
	}

	override void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		if (next.state == ConnectionState.connected)
			sendFrame(cast(Flags)(Flags.opClose | Flags.fin), Data.init);
		super.disconnect(reason, type);
	}

private:
	Mt19937_64 maskRNG;

	/// The receive buffer.
	Data inBuffer;

	/// The accumulated fragments.
	DataVec outBuffer;

	/// Timeout handling.
	TimerTask idleTask;
	bool pingSent; /// ditto

	static if (haveZlib)
	{
		bool useDeflate_;
		bool messageCompressed_;
		bool noDeflateContextTakeover_;
		bool noInflateContextTakeover_;
		zlib.ZlibProcess!true deflater;
		zlib.ZlibProcess!false inflater;

		Data compressMessage(scope Data[] message)
		{
			foreach (ref chunk; message)
				deflater.processChunk(chunk);
			auto compressed = deflater.syncFlush().joinData;
			if (noDeflateContextTakeover_)
				deflater.reset();
			// Strip trailing 0x00 0x00 0xFF 0xFF (sync flush marker)
			// per RFC 7692 Section 7.2.1.
			// The tail is absent when there is nothing new to flush
			// (e.g. empty message after a prior flush).
			if (compressed.length == 0)
				return Data.init;
			assert(compressed.length >= 4);
			return compressed[0 .. $ - 4];
		}

		Data decompressMessage(Data compressed)
		{
			if (compressed.length == 0)
				return Data.init;
			// Append 0x00 0x00 0xFF 0xFF per RFC 7692 Section 7.2.1
			inflater.processChunk(compressed);
			auto tail = Data(cast(ubyte[])[0x00, 0x00, 0xFF, 0xFF]);
			inflater.processChunk(tail);
			auto result = inflater.syncFlush().joinData;
			if (noInflateContextTakeover_)
				inflater.reset();
			return result;
		}
	}

	void sendFrame(Flags flags, Data payload)
	{
		auto totalLength =
			1 + // flags
			1 + // length byte
			(
				payload.length <=    125 ? 0 :
				payload.length <= 0xFFFF ? 2 :
											8
			) + // length
			(useMask ? 4 : 0) + // mask
			payload.length;
		auto packet = Data(totalLength);
		packet.enter((scope ubyte[] bytes) {
			size_t pos;

			bytes[pos++] = flags;

			auto lengthByte = useMask ? LengthByte.masked : LengthByte.init;

			if (payload.length <= 125)
			{
				lengthByte |= cast(ubyte)payload.length;
				bytes[pos++] = lengthByte;
			}
			else
			if (payload.length <= 0xFFFF)
			{
				lengthByte |= LengthByte.lengthIs16Bit;
				bytes[pos++] = lengthByte;

				NetworkByteOrder!ushort len = cast(ushort)payload.length;
				foreach (b; len.asBytes)
					bytes[pos++] = b;
			}
			else
			{
				lengthByte |= LengthByte.lengthIs64Bit;
				bytes[pos++] = lengthByte;

				NetworkByteOrder!ulong len = payload.length;
				foreach (b; len.asBytes)
					bytes[pos++] = b;
			}

			payload.enter((scope ubyte[] fragmentBytes) {
				if (useMask)
				{
					auto mask = maskRNG.uniform!uint.asStaticBytes;
					foreach (b; mask)
						bytes[pos++] = b;
					foreach (i, b; fragmentBytes)
						bytes[pos++] = b ^ mask[i % 4];
				}
				else
					foreach (b; fragmentBytes)
						bytes[pos++] = b;
			});

			assert(pos == bytes.length);

		});
		next.send(packet);
	}

	void onIdle(Timer /*timer*/, TimerTask /*task*/)
	{
		mainTimer.add(idleTask, now + idleTimeout);
		if (pingSent)
			disconnect("Time-out");
		else
		{
			pingSent = true;
			sendFrame(cast(Flags)(Flags.opPing | Flags.fin), Data.init);
		}
	}

protected:
	/// Called when data has been received.
	final override void onReadData(Data data)
	{
		inBuffer ~= data;
		bool stop;
		while (!stop)
		{
			inBuffer.enter((scope ubyte[] bytes) {

				if (inBuffer.length < 2) { stop = true; return; }

				size_t pos = 0;
				auto flags = cast(Flags)bytes[pos++];
				auto lengthByte = cast(LengthByte)bytes[pos++];

				bool masked;
				if (lengthByte & LengthByte.masked)
					masked = true;

				if (requireMask)
					enforce(masked, "Fragment was not masked");

				auto lengthSize =
					(lengthByte & LengthByte.lengthMask) == LengthByte.lengthIs16Bit ? 2 :
					(lengthByte & LengthByte.lengthMask) == LengthByte.lengthIs64Bit ? 8 :
					                                                                   0;
				if (inBuffer.length < pos + lengthSize) { stop = true; return; }

				size_t length;
				if ((lengthByte & LengthByte.lengthMask) == LengthByte.lengthIs16Bit)
				{
					NetworkByteOrder!ushort len;
					foreach (ref b; len.asBytes)
						b = bytes[pos++];
					length = len;
				}
				else
				if ((lengthByte & LengthByte.lengthMask) == LengthByte.lengthIs64Bit)
				{
					NetworkByteOrder!ulong len;
					foreach (ref b; len.asBytes)
						b = bytes[pos++];
					ulong value = len;
					length = value.to!size_t;
				}
				else
					length = (lengthByte & LengthByte.lengthMask);

				auto totalLength =
					1 + // flags
					1 + // length byte
					lengthSize + // length
					(masked ? 4 : 0) + // mask
					length; // data
				if (bytes.length < totalLength) { stop = true; return; }

				auto fragment = Data(length);
				fragment.enter((scope ubyte[] fragmentBytes) {
					if (masked)
					{
						ubyte[4] mask;
						foreach (ref b; mask)
							b = bytes[pos++];
						foreach (i, ref b; fragmentBytes)
							b = bytes[pos++] ^ mask[i % 4];
					}
					else
					{
						foreach (ref b; fragmentBytes)
							b = bytes[pos++];
					}
				});

				assert(pos == totalLength);
				inBuffer = inBuffer[pos .. $];

				switch (flags & Flags.opMask)
				{
					case Flags.opContinuationFrame:
						enforce(outBuffer.length > 0, "Continuation frame without an initial frame");
						goto dataFrame;

					case Flags.opTextFrame:
					case Flags.opBinaryFrame:
						enforce(outBuffer.length == 0, "Unexpected non-continuation frame");
						static if (haveZlib)
						{
							if (useDeflate_)
								messageCompressed_ = cast(bool)(flags & Flags.rsv1);
						}
						goto dataFrame;

					dataFrame:
						outBuffer ~= fragment;
						if (flags & Flags.fin)
						{
							auto m = outBuffer.joinData;
							outBuffer = null;
							static if (haveZlib)
							{
								if (messageCompressed_)
								{
									m = decompressMessage(m);
									messageCompressed_ = false;
								}
							}
							super.onReadData(m);
						}
						break;

					case Flags.opClose:
						enforce(flags & Flags.fin, "Fragmented close frame");
						if (next.state == ConnectionState.connected)
						{
							sendFrame(flags, fragment);
							super.disconnect("Received close frame");
						}
						stop = true;
						return;

					case Flags.opPing:
						enforce(flags & Flags.fin, "Fragmented ping frame");
						if (next.state == ConnectionState.connected)
							sendFrame(cast(Flags)(Flags.opPong | Flags.fin), fragment);
						break;

					case Flags.opPong:
						enforce(flags & Flags.fin, "Fragmented pong frame");
						enforce(pingSent, "Unexpected pong frame");
						pingSent = false;
						if (idleTask)
							idleTask.restart(now + idleTimeout);
						break;

					default:
						throw new Exception("Unknown opcode");
				}
			});
		}
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		inBuffer.clear();
		outBuffer = null;
		idleTask.cancel();
		idleTask = null;
		static if (haveZlib)
		{
			useDeflate_ = false;
		}
	}
}

import ae.net.http.common : HttpRequest, HttpResponse, HttpStatusCode;
import ae.net.http.server : HttpServerConnection;
import std.algorithm.iteration : splitter;
import std.algorithm.searching : any;
import std.base64 : Base64;
import std.digest.sha : sha1Of;
import std.string : strip;

private enum wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Accept a WebSocket upgrade request on the server side.
WebSocketAdapter accept(
	HttpRequest request,
	HttpServerConnection conn,
	PerMessageDeflate deflateMode = PerMessageDeflate.negotiate,
	int compressionLevel = -1,
)
{
	enforce(request.method == "GET", "WebSocket request method is not GET");
	enforce(request.protocolVersion >= "1.1", "WebSocket request HTTP version < 1.1");
	enforce(request.headers.get("Upgrade", null).icmp("websocket") == 0, "WebSocket request missing 'Upgrade: websocket' header");
	enforce(request.headers.get("Connection", null).splitter(",").any!(t => t.strip.icmp("Upgrade") == 0), "WebSocket request missing 'Connection: Upgrade' header");
	enforce("Sec-WebSocket-Key" in request.headers, "WebSocket request missing Sec-WebSocket-Key header");
	enforce(request.headers.get("Sec-WebSocket-Version", null) == "13", "WebSocket request Sec-WebSocket-Version is not 13");

	auto response = new HttpResponse();
	response.status = HttpStatusCode.SwitchingProtocols;
	response.headers["Upgrade"] = "websocket";
	response.headers["Connection"] = "Upgrade";
	response.headers["Sec-WebSocket-Accept"] = Base64.encode(sha1Of(
		request.headers["Sec-WebSocket-Key"] ~ wsGUID
	));

	bool useDeflate = false;
	bool serverNoContextTakeover = false;
	bool clientNoContextTakeover = false;
	static if (haveZlib)
	{
		if (deflateMode != PerMessageDeflate.disable)
		{
			auto exts = request.headers.get("Sec-WebSocket-Extensions", null);
			if (exts !is null)
			{
				foreach (ext; exts.splitter(','))
				{
					auto params = ext.splitter(';');
					if (params.front.strip != "permessage-deflate")
						continue;
					useDeflate = true;
					params.popFront();
					// Parse extension parameters (RFC 7692 Section 7.1)
					string responseExt = "permessage-deflate";
					foreach (param; params)
					{
						auto p = param.strip;
						// RFC 7692 §7.1.1.1: If client offered server_no_context_takeover,
						// server MUST include it in the response.
						if (p == "server_no_context_takeover")
						{
							serverNoContextTakeover = true;
							responseExt ~= "; server_no_context_takeover";
						}
						// RFC 7692 §7.1.2.1: If client offered client_no_context_takeover,
						// server MAY include it in the response. We honor it.
						else if (p == "client_no_context_takeover")
						{
							clientNoContextTakeover = true;
							responseExt ~= "; client_no_context_takeover";
						}
						// client_max_window_bits (with or without value) — acknowledged
						// server_max_window_bits — not currently supported
					}
					response.headers["Sec-WebSocket-Extensions"] = responseExt;
					break;
				}
			}
			if (deflateMode == PerMessageDeflate.force)
				enforce(useDeflate, "Client did not offer permessage-deflate");
		}
	}
	else
	{
		if (deflateMode == PerMessageDeflate.force)
			throw new Exception("WebSocket compression not available (built without zlib)");
	}

	auto upgrade = conn.upgrade(response);
	enforce(upgrade.initialData.bytes.length == 0, "WebSocket data before handshake");

	return new WebSocketAdapter(
		upgrade.conn,
		false, // useMask
		true, // requireMask
		true, // sendBinary
		1.minutes, // idleTimeout
		useDeflate,
		compressionLevel,
		serverNoContextTakeover, // noDeflateContextTakeover (server's deflater)
		clientNoContextTakeover, // noInflateContextTakeover (client's inflater = server's inflater for client msgs)
	);
}

import ae.net.asockets : TimeoutAdapter;
import ae.net.http.client : HttpClient, Connector, TcpConnector;
import ae.net.ssl : ssl, SSLContext, SSLAdapter;
import std.algorithm.mutation : move;
import std.algorithm.searching : skipOver;
import std.exception : assumeUnique;

/// Connect to a WebSocket server.
///
/// Performs the client-side opening handshake (RFC 6455 Section 4)
/// and, on success, calls `handler` with a ready-to-use `WebSocketAdapter`.
/// On failure, calls `errorHandler` with an error message.
void connectWebSocket(
	string url,
	void delegate(WebSocketAdapter) handler,
	void delegate(string) errorHandler,
	PerMessageDeflate deflateMode = PerMessageDeflate.negotiate,
	int compressionLevel = -1,
)
{
	auto resource = url;
	bool secure;
	if (resource.skipOver("wss://"))
	{
		resource = "https://" ~ resource;
		secure = true;
	}
	else if (resource.skipOver("ws://"))
		resource = "http://" ~ resource;

	SSLContext sslCtx;
	if (secure)
		sslCtx = ssl.createContext(SSLContext.Kind.client);

	auto client = sslCtx ? new WebSocketClient(sslCtx) : new WebSocketClient;

	client.handleWebSocketConnect = (WebSocketAdapter ws, HttpResponse /*response*/) {
		handler(ws);
	};

	client.handleResponse = (HttpResponse response, string reason) {
		if (errorHandler)
			errorHandler(response
				? "WebSocket upgrade failed: HTTP " ~ response.status.to!string
				: reason);
	};

	auto req = new HttpRequest(resource);
	client.upgradeRequest(req, deflateMode, compressionLevel);
}

/// WebSocket client that performs the HTTP upgrade handshake.
///
/// Subclasses `HttpClient` to handle the WebSocket opening handshake
/// (RFC 6455 Section 4). For simple use cases, see `connectWebSocket`.
///
/// Usage with custom headers:
/// ---
/// auto client = new WebSocketClient;
/// client.handleWebSocketConnect = (ws, response) { /* ... */ };
/// client.handleResponse = (response, reason) { /* error */ };
/// auto req = new HttpRequest("http://example.com/ws");
/// req.headers["Authorization"] = "Bearer token";
/// client.upgradeRequest(req);
/// ---
///
/// Usage with custom TLS:
/// ---
/// auto ctx = ssl.createContext(SSLContext.Kind.client);
/// ctx.setCertificate("/path/to/cert.pem");
/// auto client = new WebSocketClient(ctx);
/// client.handleWebSocketConnect = (ws, response) { /* ... */ };
/// auto req = new HttpRequest("https://example.com/ws");
/// client.upgradeRequest(req);
/// ---
class WebSocketClient : HttpClient
{
	/// Called on successful WebSocket upgrade.
	/// The `HttpResponse` is provided so the caller can read
	/// `Sec-WebSocket-Protocol`, `Sec-WebSocket-Extensions`, etc.
	void delegate(WebSocketAdapter, HttpResponse) handleWebSocketConnect;

	/// Constructor for plain `ws://` connections.
	this(Duration timeout = 30.seconds, Connector connector = new TcpConnector)
	{
		super(timeout, connector);
	}

	/// Constructor with custom SSL context for `wss://` connections.
	/// Allows configuring client certificates, custom CA, etc.
	this(SSLContext sslContext, Duration timeout = 30.seconds, Connector connector = new TcpConnector)
	{
		sslCtx = sslContext;
		super(timeout, connector);
	}

	/// Send a WebSocket upgrade request.
	/// Adds required headers (`Upgrade`, `Connection`, `Sec-WebSocket-Key`,
	/// `Sec-WebSocket-Version`). Custom headers should be set on the
	/// request before calling this method.
	void upgradeRequest(
		HttpRequest req,
		PerMessageDeflate deflateMode = PerMessageDeflate.negotiate,
		int compressionLevel = -1,
	)
	{
		ubyte[16] keyBytes;
		genRandom(keyBytes);
		wsKey = Base64.encode(keyBytes[]).assumeUnique;

		req.headers["Upgrade"] = "websocket";
		req.headers["Connection"] = "Upgrade";
		req.headers["Sec-WebSocket-Key"] = wsKey;
		req.headers["Sec-WebSocket-Version"] = "13";

		static if (haveZlib)
		{
			if (deflateMode != PerMessageDeflate.disable)
				req.headers["Sec-WebSocket-Extensions"] = "permessage-deflate; client_max_window_bits";
		}
		else
		{
			if (deflateMode == PerMessageDeflate.force)
				throw new Exception("WebSocket compression not available (built without zlib)");
		}

		deflateMode_ = deflateMode;
		compressionLevel_ = compressionLevel;

		this.request(req, false);
	}

private:
	string wsKey;
	SSLContext sslCtx;
	SSLAdapter sslAdapter;
	PerMessageDeflate deflateMode_;
	int compressionLevel_;

protected:
	override IConnection adaptConnection(IConnection conn)
	{
		if (sslCtx)
		{
			sslAdapter = ssl.createAdapter(sslCtx, conn);
			return sslAdapter;
		}
		return conn;
	}

	override void connect(HttpRequest request)
	{
		super.connect(request);
		if (sslAdapter && conn.state == ConnectionState.connecting)
			sslAdapter.setHostName(request.host);
	}

	override void sendRequest(HttpRequest request)
	{
		// WebSocket requires HTTP/1.1 (HttpClient defaults to HTTP/1.0)
		string reqMessage = request.method ~ " ";
		if (request.proxy !is null)
		{
			reqMessage ~= "http://" ~ request.host;
			if (request.port != 80)
				reqMessage ~= ":" ~ request.port.to!string;
		}
		reqMessage ~= request.resource ~ " HTTP/1.1\r\n";

		foreach (string header, string value; request.headers)
			if (value !is null)
				reqMessage ~= header ~ ": " ~ value ~ "\r\n";

		reqMessage ~= "\r\n";

		conn.send(Data(reqMessage.asBytes));
		conn.send(request.data[]);
	}

	override void onHeadersReceived()
	{
		if (currentResponse.status != HttpStatusCode.SwitchingProtocols)
		{
			super.onHeadersReceived();
			return;
		}

		auto expectedAccept = Base64.encode(sha1Of(wsKey ~ wsGUID));

		enforce(
			currentResponse.headers.get("Sec-WebSocket-Accept", null) == expectedAccept,
			"Invalid Sec-WebSocket-Accept in WebSocket handshake response"
		);

		bool useDeflate = false;
		bool serverNoContextTakeover = false;
		bool clientNoContextTakeover = false;
		static if (haveZlib)
		{
			if (deflateMode_ != PerMessageDeflate.disable)
			{
				auto exts = currentResponse.headers.get("Sec-WebSocket-Extensions", null);
				if (exts !is null)
				{
					foreach (ext; exts.splitter(','))
					{
						auto params = ext.splitter(';');
						if (params.front.strip != "permessage-deflate")
							continue;
						useDeflate = true;
						params.popFront();
						foreach (param; params)
						{
							auto p = param.strip;
							if (p == "server_no_context_takeover")
								serverNoContextTakeover = true;
							else if (p == "client_no_context_takeover")
								clientNoContextTakeover = true;
						}
						break;
					}
				}
				if (deflateMode_ == PerMessageDeflate.force)
					enforce(useDeflate, "Server did not accept permessage-deflate");
			}
		}

		auto response = currentResponse;
		auto rest = move(headerBuffer);

		receivedResponses = sentRequests;
		currentResponse = null;

		IConnection baseConn;
		if (timer)
		{
			timer.cancelIdleTimeout();
			baseConn = timer.next;
		}
		else
			baseConn = conn;

		conn = null;

		auto ws = new WebSocketAdapter(
			baseConn,
			true,  // useMask (client must mask)
			false, // requireMask
			true,  // sendBinary
			1.minutes, // idleTimeout
			useDeflate,
			compressionLevel_,
			clientNoContextTakeover, // noDeflateContextTakeover (client's deflater)
			serverNoContextTakeover, // noInflateContextTakeover (server's inflater = client's inflater for server msgs)
		);

		if (handleWebSocketConnect)
			handleWebSocketConnect(ws, response);

		if (rest.bytes.length)
			ws.onReadData(rest.joinData);
	}
}

debug(ae_unittest) unittest
{
	import ae.net.http.server : HttpServer, HttpServerConnection;
	import ae.net.asockets : socketManager;

	auto s = new HttpServer;
	s.handleRequest = (HttpRequest request, HttpServerConnection serverConn) {
		auto ws = accept(request, serverConn);
		ws.handleReadData = (Data data) {
			ws.send(data); // echo
		};
	};
	auto port = s.listen(0, "127.0.0.1");

	bool ok;
	connectWebSocket(
		"ws://127.0.0.1:" ~ port.to!string ~ "/",
		(WebSocketAdapter ws) {
			ws.handleReadData = (Data data) {
				assert(data.toGC() == "Hello WebSocket");
				ok = true;
				ws.disconnect("Test complete");
				s.close();
			};
			ws.send(Data("Hello WebSocket".asBytes));
		},
		(string error) {
			assert(false, "WebSocket connection failed: " ~ error);
		},
	);

	socketManager.loop();
	assert(ok);
}

version (HAVE_WS_PEER)
static if (haveZlib)
debug(ae_unittest) unittest
{
	// Integration test: D client connects to external WebSocket echo server.
	// The peer server must support permessage-deflate (RFC 7692).
	import std.process : environment;
	if (environment.get("WS_TEST_MODE", "") != "client") return;

	import ae.net.asockets : socketManager;

	auto port = environment.get("WS_SERVER_PORT", "18765");

	bool ok;
	connectWebSocket(
		"ws://127.0.0.1:" ~ port ~ "/",
		(WebSocketAdapter ws) {
			assert(ws.deflateEnabled, "permessage-deflate was not negotiated with server");
			ws.handleReadData = (Data data) {
				assert(data.toGC() == "Hello from D client");
				ok = true;
				ws.disconnect("Test complete");
			};
			ws.send(Data("Hello from D client".asBytes));
		},
		(string error) {
			assert(false, "WebSocket connection failed: " ~ error);
		},
	);

	socketManager.loop();
	assert(ok);
}

version (HAVE_WS_PEER)
static if (haveZlib)
debug(ae_unittest) unittest
{
	// Integration test: D server accepts connection from external WebSocket client.
	// The peer client must support permessage-deflate (RFC 7692).
	import std.process : environment;
	if (environment.get("WS_TEST_MODE", "") != "server") return;

	import ae.net.http.server : HttpServer;
	import ae.net.asockets : socketManager;
	import ae.sys.timing : setTimeout;

	auto s = new HttpServer;
	bool ok;
	s.handleRequest = (HttpRequest request, HttpServerConnection serverConn) {
		auto ws = accept(request, serverConn);
		assert(ws.deflateEnabled, "permessage-deflate was not negotiated with client");
		ws.handleReadData = (Data data) {
			ok = true;
			ws.send(data); // echo
		};
		ws.handleDisconnect = (string reason, DisconnectType type) {
			setTimeout({ s.close(); }, 0.seconds);
		};
	};
	auto port = environment.get("WS_PORT", "18766").to!ushort;
	s.listen(port, "127.0.0.1");

	// Signal readiness to the test harness
	import std.file : fileWrite = write;
	fileWrite(environment.get("WS_READY_FILE", "/tmp/ws_ready"), "ready");

	socketManager.loop();
	assert(ok);
}

static if (haveZlib)
debug(ae_unittest) unittest
{
	import ae.net.http.server : HttpServer, HttpServerConnection;
	import ae.net.asockets : socketManager;

	auto s = new HttpServer;
	s.handleRequest = (HttpRequest request, HttpServerConnection serverConn) {
		auto ws = accept(request, serverConn);
		assert(ws.deflateEnabled, "Server: permessage-deflate was not negotiated");
		ws.handleReadData = (Data data) {
			ws.send(data); // echo
		};
	};
	auto port = s.listen(0, "127.0.0.1");

	bool ok;
	connectWebSocket(
		"ws://127.0.0.1:" ~ port.to!string ~ "/",
		(WebSocketAdapter ws) {
			assert(ws.deflateEnabled, "Client: permessage-deflate was not negotiated");
			ws.handleReadData = (Data data) {
				assert(data.toGC() == "Hello Compressed WebSocket");
				ok = true;
				ws.disconnect("Test complete");
				s.close();
			};
			ws.send(Data("Hello Compressed WebSocket".asBytes));
		},
		(string error) {
			assert(false, "WebSocket connection failed: " ~ error);
		},
	);

	socketManager.loop();
	assert(ok);
}

version (HAVE_WS_PEER)
static if (haveZlib)
debug(ae_unittest) unittest
{
	// Integration test: D client connects to external echo server configured
	// with no_context_takeover. Multiple messages are sent to verify that
	// the zlib stream is properly reset between messages.
	import std.process : environment;
	if (environment.get("WS_TEST_MODE", "") != "client_nctx") return;

	import ae.net.asockets : socketManager;

	auto port = environment.get("WS_SERVER_PORT", "18765");
	enum messages = ["Message one", "Message two", "Message three"];
	int received;

	bool ok;
	connectWebSocket(
		"ws://127.0.0.1:" ~ port ~ "/",
		(WebSocketAdapter ws) {
			assert(ws.deflateEnabled, "permessage-deflate was not negotiated");
			ws.handleReadData = (Data data) {
				assert(data.toGC() == messages[received], "Echo mismatch on message " ~ received.to!string);
				received++;
				if (received < messages.length)
					ws.send(Data(messages[received].asBytes));
				else
				{
					ok = true;
					ws.disconnect("Test complete");
				}
			};
			ws.send(Data(messages[0].asBytes));
		},
		(string error) {
			assert(false, "WebSocket connection failed: " ~ error);
		},
	);

	socketManager.loop();
	assert(ok);
	assert(received == messages.length);
}

version (HAVE_WS_PEER)
static if (haveZlib)
debug(ae_unittest) unittest
{
	// Integration test: D server accepts connection from external client
	// configured with no_context_takeover. Multiple messages verify that
	// the zlib stream is properly reset between messages.
	import std.process : environment;
	if (environment.get("WS_TEST_MODE", "") != "server_nctx") return;

	import ae.net.http.server : HttpServer;
	import ae.net.asockets : socketManager;
	import ae.sys.timing : setTimeout;

	auto s = new HttpServer;
	int received;
	s.handleRequest = (HttpRequest request, HttpServerConnection serverConn) {
		auto ws = accept(request, serverConn);
		assert(ws.deflateEnabled, "permessage-deflate was not negotiated with client");
		ws.handleReadData = (Data data) {
			received++;
			ws.send(data); // echo
		};
		ws.handleDisconnect = (string reason, DisconnectType type) {
			setTimeout({ s.close(); }, 0.seconds);
		};
	};
	auto port = environment.get("WS_PORT", "18767").to!ushort;
	s.listen(port, "127.0.0.1");

	// Signal readiness to the test harness
	import std.file : fileWrite = write;
	fileWrite(environment.get("WS_READY_FILE", "/tmp/ws_ready_nctx"), "ready");

	socketManager.loop();
	assert(received == 3, "Expected 3 messages, got " ~ received.to!string);
}
