/**
 * JSON-RPC over Content-Length framed transport.
 *
 * Provides JSON-RPC transport using LSP-style Content-Length header framing,
 * as used by the Language Server Protocol and similar protocols.
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

module ae.net.jsonrpc.contentlength;

import ae.net.asockets : ConnectionAdapter, IConnection, DisconnectType;
import ae.sys.data : Data;
import ae.utils.array : asBytes, asSlice;
import std.conv : to;
import std.string : CaseSensitive, indexOf;

/// Adapter implementing LSP-style Content-Length framing.
/// On read: buffers incoming data, parses Content-Length headers, delivers
/// complete message bodies one at a time via the readDataHandler.
/// On write: prepends "Content-Length: N\r\n\r\n" before each message.
class ContentLengthAdapter : ConnectionAdapter
{
	this(IConnection next)
	{
		super(next);
	}

	/// Note: we send all `data` items as a single message.
	/// Call this multiple times to send multiple messages.
	override void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		size_t total = 0;
		foreach (ref d; data)
			total += d.length;
		auto header = "Content-Length: " ~ total.to!string ~ "\r\n\r\n";
		auto headerDatum = Data(header.asBytes);
		super.send(headerDatum.asSlice, priority);
		super.send(data, priority);
	}

	alias send = typeof(super).send;

protected:
	final override void onReadData(Data data)
	{
		if (inBuffer.length)
			inBuffer ~= data;
		else
			inBuffer = data;

		processBuffer();
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		inBuffer.clear();
	}

private:
	Data inBuffer;
	bool readingBody = false;
	size_t bodyLength;

	/// Search for the 4-byte separator `\r\n\r\n` in the buffer.
	/// Returns the byte index of the first `\r`, or -1 if not found.
	sizediff_t findHeaderEnd() @trusted
	{
		auto bytes = inBuffer.unsafeContents;
		if (bytes.length < 4)
			return -1;
		foreach (i; 0 .. bytes.length - 3)
			if (bytes[i] == '\r' && bytes[i+1] == '\n' && bytes[i+2] == '\r' && bytes[i+3] == '\n')
				return i;
		return -1;
	}

	void processBuffer()
	{
		while (true)
		{
			if (!readingBody)
			{
				auto idx = findHeaderEnd();
				if (idx < 0)
					return;

				auto headerStr = cast(string) inBuffer[0 .. idx].toGC();
				enum clPrefix = "Content-Length: ";
				auto clIdx = headerStr.indexOf(clPrefix, CaseSensitive.no);
				if (clIdx < 0)
				{
					disconnect("Missing Content-Length header", DisconnectType.error);
					return;
				}
				auto valueStart = clIdx + clPrefix.length;
				auto lineEnd = headerStr[valueStart .. $].indexOf('\r');
				auto lengthStr = lineEnd < 0
					? headerStr[valueStart .. $]
					: headerStr[valueStart .. valueStart + lineEnd];
				bodyLength = lengthStr.to!size_t;
				inBuffer = inBuffer[idx + 4 .. inBuffer.length];
				readingBody = true;
			}

			if (readingBody)
			{
				if (inBuffer.length < bodyLength)
					return;

				auto body_ = inBuffer[0 .. bodyLength];
				inBuffer = inBuffer[bodyLength .. inBuffer.length];
				readingBody = false;
				bodyLength = 0;
				super.onReadData(body_);
				// Loop to check for next message in buffer
			}
		}
	}
}

// ************************************************************************

version (HAVE_CONTENTLENGTH_PEER)
debug(ae_unittest) unittest
{
	// Integration test, Phase 1: D acts as TCP JSON-RPC server with
	// Content-Length framing. Validates that an external Python peer
	// (python-lsp-jsonrpc) can exchange messages over this transport.
	// The Python writer sends both Content-Length and Content-Type headers,
	// which exercises multi-header parsing.
	import std.process : environment;
	if (environment.get("CL_TEST_MODE", "") != "server") return;

	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import ae.net.jsonrpc.codec : JsonRpcServerCodec;
	import ae.net.jsonrpc.binding : jsonRpcDispatcher;
	import ae.utils.promise : Promise, resolve;
	import std.file : fileWrite = write;

	interface CalcApi
	{
		Promise!int add(int a, int b);
	}

	static class CalcImpl : CalcApi
	{
		Promise!int add(int a, int b) { return resolve(a + b); }
	}

	auto dispatcher = jsonRpcDispatcher!CalcApi(new CalcImpl());
	auto server = new TcpServer();
	server.handleAccept = (TcpConnection conn) {
		auto cl = new ContentLengthAdapter(conn);
		auto codec = new JsonRpcServerCodec(cl);
		codec.handleRequest = &dispatcher.dispatch;
	};
	auto port = server.listen(0, "127.0.0.1");

	fileWrite(environment.get("CL_READY_FILE", "/tmp/cl_ready"), port.to!string);

	socketManager.loop();
}

version (HAVE_CONTENTLENGTH_PEER)
debug(ae_unittest) unittest
{
	// Integration test, Phase 2: D acts as TCP JSON-RPC client with
	// Content-Length framing. Validates that D's ContentLengthAdapter
	// wire format is understood by an external Python peer
	// (python-lsp-jsonrpc).
	import std.process : environment;
	if (environment.get("CL_TEST_MODE", "") != "client") return;

	import ae.net.asockets : socketManager, TcpConnection;
	import ae.net.jsonrpc.binding : jsonRpcClient;
	import ae.utils.promise : Promise;

	auto port = environment.get("CL_SERVER_PORT", "8080").to!ushort;

	interface CalcClient
	{
		Promise!int add(int a, int b);
	}

	bool done;
	auto tcpConn = new TcpConnection();

	tcpConn.handleConnect = {
		auto cl = new ContentLengthAdapter(tcpConn);
		auto client = jsonRpcClient!CalcClient(cl);

		client.add(10, 7).then((int result) {
			assert(result == 17, "Expected 17, got " ~ result.to!string);
			done = true;
			cl.disconnect();
		});
	};

	tcpConn.connect("127.0.0.1", port);

	socketManager.loop();
	assert(done, "D client Content-Length test did not complete");
}
