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

import core.time : Duration, minutes;

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

	this(
		IConnection next,
		bool useMask = false,
		bool requireMask = false,
		bool sendBinary = true,
		Duration idleTimeout = 1.minutes,
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
	}

	final void send(Data message)
	{
		send(message.asSlice);
	}

	alias send = IConnection.send; /// ditto

	override void send(scope Data[] message, int priority)
	{
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

private:
	Mt19937_64 maskRNG;

	/// The receive buffer.
	Data inBuffer;

	/// The accumulated fragments.
	DataVec outBuffer;

	/// Timeout handling.
	TimerTask idleTask;
	bool pingSent; /// ditto

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
						goto dataFrame;

					dataFrame:
						outBuffer ~= fragment;
						if (flags & Flags.fin)
						{
							auto m = outBuffer.joinData;
							outBuffer = null;
							super.onReadData(m);
						}
						break;

					case Flags.opClose:
						enforce(flags & Flags.fin, "Fragmented close frame");
						if (next.state == ConnectionState.connected)
						{
							sendFrame(flags, fragment);
							disconnect("Received close frame");
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
	}
}

import ae.net.http.common : HttpRequest, HttpResponse, HttpStatusCode;
import ae.net.http.server : HttpServerConnection;
import std.base64 : Base64;
import std.digest.sha : sha1Of;

WebSocketAdapter accept(HttpRequest request, HttpServerConnection conn)
{
	enforce(
		request.method == "GET" &&
		request.protocolVersion >= "1.1" &&
		request.headers.get("Upgrade", null).icmp("websocket") == 0 &&
		request.headers.get("Connection", null).icmp("Upgrade") == 0 &&
		"Sec-WebSocket-Key" in request.headers &&
		request.headers.get("Sec-WebSocket-Version", null) == "13",
		"Invalid WebSockets request"
	);

	auto response = new HttpResponse();
	response.status = HttpStatusCode.SwitchingProtocols;
	response.headers["Upgrade"] = "websocket";
	response.headers["Connection"] = "Upgrade";
	response.headers["Sec-WebSocket-Accept"] = Base64.encode(sha1Of(
		request.headers["Sec-WebSocket-Key"] ~ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	));
	auto upgrade = conn.upgrade(response);
	enforce(upgrade.initialData.bytes.length == 0, "WebSocket data before handshake");

	return new WebSocketAdapter(
		upgrade.conn,
		false, // useMask
		true, // requireMask
	);
}
