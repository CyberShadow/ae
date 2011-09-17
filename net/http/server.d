/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Stéphan Kochen <stephan@kochen.nl>
 * Portions created by the Initial Developer are Copyright (C) 2006
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// A simple HTTP server.
module ae.net.http.server;

import std.string;
import std.conv;
import std.datetime;
import std.uri;
import std.exception;

import ae.net.asockets;
import ae.sys.data;

public import ae.net.http.common;

debug (HTTP) import std.stdio;

class HttpServer
{
private:
	ServerSocket conn;
	TickDuration timeout;

private:
	class Connection
	{
		ClientSocket conn;
		Data inBuffer;

		HttpRequest currentRequest;
		int expect;  // VP 2007.01.21: changing from size_t to int because size_t is unsigned
		bool persistent;

		this(ClientSocket conn)
		{
			this.conn = conn;
			conn.handleReadData = &onNewRequest;
			conn.setIdleTimeout(timeout);
			debug (HTTP) conn.handleDisconnect = &onDisconnect;
		}

		void onNewRequest(ClientSocket sender, Data data)
		{
			debug (HTTP) writefln("Receiving start of request: \n%s---", cast(string)data.contents);
			inBuffer ~= data;

			auto inBufferStr = cast(string)inBuffer.contents;
			int headersend = inBufferStr.indexOf("\r\n\r\n");
			if (headersend == -1)
				return;

			debug (HTTP) writefln("Got headers, %d bytes total", headersend+4);
			string[] lines = splitLines(inBufferStr[0 .. headersend]);
			string reqline = lines[0];
			enforce(reqline.length > 10);
			lines = lines[1 .. lines.length];

			currentRequest = new HttpRequest();

			int methodend = reqline.indexOf(' ');
			enforce(methodend > 0);
			currentRequest.method = reqline[0 .. methodend].idup;
			reqline = reqline[methodend + 1 .. reqline.length];

			int resourceend = reqline.lastIndexOf(' ');
			enforce(resourceend > 0);
			currentRequest.resource = reqline[0 .. resourceend].idup;

			string protocol = reqline[resourceend+1..$];
			enforce(protocol.startsWith("HTTP/"));
			currentRequest.protocolVersion = protocol[5..$].idup;

			foreach (string line; lines)
			{
				int valuestart = line.indexOf(": ");
				if (valuestart > 0)
					currentRequest.headers[line[0 .. valuestart].idup] = line[valuestart + 2 .. line.length].idup;
			}

			switch (currentRequest.protocolVersion)
			{
				case "1.0":
					persistent =  ("Connection" in currentRequest.headers && currentRequest.headers["Connection"] == "Keep-Alive");
					break;
				default: // 1.1+
					persistent = !("Connection" in currentRequest.headers && currentRequest.headers["Connection"] == "close");
					break;
			}
			debug (HTTP) writefln("This %s connection %s persistent", currentRequest.protocolVersion, persistent ? "IS" : "is NOT");

			expect = 0;
			if ("Content-Length" in currentRequest.headers)
				expect = to!uint(currentRequest.headers["Content-Length"]);

			inBuffer.popFront(headersend+4);

			if (expect > 0)
			{
				if (expect > inBuffer.length)
					conn.handleReadData = &onContinuation;
				else
					processRequest(inBuffer.popFront(expect));
			}
			else
				processRequest(Data());
		}

		debug (HTTP)
		void onDisconnect(ClientSocket sender, string reason, DisconnectType type)
		{
			writefln("Disconnect: %s", reason);
		}

		void onContinuation(ClientSocket sender, Data data)
		{
			debug (HTTP) writefln("Receiving continuation of request: \n%s---", cast(string)data.contents);
			inBuffer ~= data;

			if (inBuffer.length >= expect)
			{
				debug (HTTP) writefln(inBuffer.length, "/", expect);
				processRequest(inBuffer.popFront(expect));
			}
		}

		void processRequest(Data data)
		{
			currentRequest.data = data;
			if (handleRequest)
				sendResponse(handleRequest(currentRequest, conn));

			if (persistent)
			{
				// reset for next request
				conn.handleReadData = &onNewRequest;
				if (inBuffer.length) // a second request has been pipelined
					onNewRequest(conn, Data());
			}
			else
				conn.disconnect();
		}

		void sendResponse(HttpResponse response)
		{
			string respMessage = "HTTP/" ~ currentRequest.protocolVersion ~ " ";
			if (response)
			{
				if ("Accept-Encoding" in currentRequest.headers)
					response.compress(currentRequest.headers["Accept-Encoding"]);
				response.headers["Content-Length"] = response ? to!string(response.data.length) : "0";
				response.headers["X-Powered-By"] = "DHttp";
				if (persistent && currentRequest.protocolVersion=="1.0")
					response.headers["Connection"] = "Keep-Alive";

				respMessage ~= to!string(response.status) ~ " " ~ response.statusMessage ~ "\r\n";
				foreach (string header, string value; response.headers)
					respMessage ~= header ~ ": " ~ value ~ "\r\n";

				respMessage ~= "\r\n";
			}
			else
			{
				respMessage ~= "500 Internal Server Error\r\n\r\n";
			}

			auto data = Data(respMessage);
			if (response)
				data ~= response.data;

			conn.send(data.contents);
			debug (HTTP) writefln("Sent response (%d bytes)", data.length);
		}
	}

private:
	void onClose()
	{
		if (handleClose)
			handleClose();
	}

	void onAccept(ClientSocket incoming)
	{
		debug (HTTP) writefln("New connection from " ~ incoming.remoteAddress);
		new Connection(incoming);
	}

public:
	this(TickDuration timeout = TickDuration.from!"seconds"(30))
	{
		assert(timeout.length > 0);
		this.timeout = timeout;

		conn = new ServerSocket();
		conn.handleClose = &onClose;
		conn.handleAccept = &onAccept;
	}

	ushort listen(ushort port, string addr = null)
	{
		return conn.listen(port, addr);
	}

	void close()
	{
		conn.close();
		conn = null;
	}

public:
	/// Callback for when the socket was closed.
	void delegate() handleClose;
	/// Callback for an incoming request.
	HttpResponse delegate(HttpRequest request, ClientSocket conn) handleRequest;
}
