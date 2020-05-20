/**
 * Support for implementing SCGI application servers.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.net.http.scgi.app;

import std.algorithm.searching : findSplit;
import std.conv : to;
import std.exception;
import std.string;

import ae.net.asockets;
import ae.net.http.cgi.common;
import ae.net.http.cgi.script;
import ae.net.http.common;
import ae.sys.log;
import ae.utils.array;

final class SCGIConnection
{
	IConnection connection;
	Logger log;
	bool nph;

	this(IConnection connection)
	{
		this.connection = connection;
		connection.handleReadData = &onReadData;
	}

	private Data buffer;

	void onReadData(Data data)
	{
		buffer ~= data;

		while (true)
			try
			{
				auto bufferStr = cast(char[])buffer.contents;
				auto colonIdx = bufferStr.indexOf(':');
				if (colonIdx < 0)
					return;

				auto headerLenStr = bufferStr[0 .. colonIdx];
				auto headerLen = headerLenStr.to!size_t;
				auto headerEnd = headerLenStr.length + 1 /*:*/ + headerLen + 1 /*,*/;
				if (buffer.length < headerEnd)
					return;
				enforce(bufferStr[headerEnd - 1] == ',', "Expected ','");

				auto headersStr = bufferStr[headerLenStr.length + 1 .. headerEnd - 1];
				enum CONTENT_LENGTH = "CONTENT_LENGTH";
				enforce(headersStr.startsWith(CONTENT_LENGTH ~ "\0"), "Expected first header to be " ~ CONTENT_LENGTH);
				auto contentLength = headersStr[CONTENT_LENGTH.length + 1 .. $].findSplit("\0")[0].to!size_t;
				if (buffer.length < headerEnd + contentLength)
					return;

				// We now know we have all the data in the request

				auto headers = parseHeaders(headersStr.idup);
				enforce(headers.get("SCGI", null) == "1", "Unknown SCGI version");
				CGIRequest request;
				request.vars = CGIVars.fromAA(headers);
				request.headers = CGIRequest.decodeHeaders(headers, request.vars.serverProtocol ? request.vars.serverProtocol : "HTTP");
				request.data = [buffer[headerEnd .. headerEnd + contentLength]];
				buffer = buffer[headerEnd + contentLength .. $];
				handleRequest(request);
			}
			catch (Exception e)
			{
				if (log) log("Error handling request: " ~ e.toString());
				connection.disconnect(e.msg);
				return;
			}
	}

	static string[string] parseHeaders(string s)
	{
		string[string] headers;
		while (s.length)
		{
			auto name = s.skipUntil('\0').enforce("Unterminated header name");
			auto value = s.skipUntil('\0').enforce("Unterminated header value");
			headers[name] = value;
		}
		return headers;
	}

	void sendResponse(HttpResponse r)
	{
		FastAppender!char headers;
		if (nph)
			writeNPHHeaders(r, headers);
		else
			writeCGIHeaders(r, headers);
		connection.send([Data(headers.get)] ~ r.data);
		connection.disconnect("Response sent");
	}

	void delegate(ref CGIRequest) handleRequest;
}
