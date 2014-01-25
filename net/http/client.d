/**
 * A simple HTTP client.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.http.client;

import std.string;
import std.conv;
import std.datetime;
import std.uri;
import std.utf;

import ae.net.asockets;
import ae.net.ietf.headers;
import ae.net.ietf.headerparse;
import ae.sys.data;
debug import std.stdio;

public import ae.net.http.common;


class HttpClient
{
private:
	ClientSocket conn;
	Data[] inBuffer;

	HttpRequest currentRequest;

	HttpResponse currentResponse;
	size_t expect;

protected:
	void onConnect(ClientSocket sender)
	{
		string reqMessage = currentRequest.method ~ " ";
		if (currentRequest.proxy !is null) {
			reqMessage ~= "http://" ~ currentRequest.host;
			if (compat || currentRequest.port != 80)
				reqMessage ~= format(":%d", currentRequest.port);
		}
		reqMessage ~= currentRequest.resource ~ " HTTP/1.0\r\n";

		if (!("User-Agent" in currentRequest.headers))
			currentRequest.headers["User-Agent"] = agent;
		if (!compat) {
			if (!("Accept-Encoding" in currentRequest.headers))
				currentRequest.headers["Accept-Encoding"] = "gzip, deflate, *;q=0";
			if (currentRequest.data)
				currentRequest.headers["Content-Length"] = to!string(currentRequest.data.bytes.length);
		} else {
			if (!("Pragma" in currentRequest.headers))
				currentRequest.headers["Pragma"] = "No-Cache";
		}
		foreach (string header, string value; currentRequest.headers)
			reqMessage ~= header ~ ": " ~ value ~ "\r\n";

		reqMessage ~= "\r\n";

		conn.send(Data(reqMessage));
		conn.send(currentRequest.data);
	}

	void onNewResponse(ClientSocket sender, Data data)
	{
		try
		{
			inBuffer ~= data;
			conn.markNonIdle();

			string statusLine;
			Headers headers;

			if (!parseHeaders(inBuffer, statusLine, headers))
				return;

			currentResponse = new HttpResponse;
			currentResponse.parseStatusLine(statusLine);
			currentResponse.headers = headers;

			expect = size_t.max;
			if ("Content-Length" in currentResponse.headers)
				expect = to!size_t(strip(currentResponse.headers["Content-Length"]));

			if (expect > inBuffer.bytes.length)
				conn.handleReadData = &onContinuation;
			else
			{
				currentResponse.data = inBuffer.bytes[0 .. expect];
				conn.disconnect("All data read");
			}
		}
		catch (Exception e)
		{
			conn.disconnect(e.msg, DisconnectType.Error);
		}
	}

	void onContinuation(ClientSocket sender, Data data)
	{
		inBuffer ~= data;
		sender.markNonIdle();

		if (expect!=size_t.max && inBuffer.length >= expect)
		{
			currentResponse.data = inBuffer[0 .. expect];
			conn.disconnect("All data read");
		}
	}

	void onDisconnect(ClientSocket sender, string reason, DisconnectType type)
	{
		if (type == DisconnectType.Error)
			currentResponse = null;
		else
		if (currentResponse)
			currentResponse.data = inBuffer;

		if (handleResponse)
			handleResponse(currentResponse, reason);

		currentRequest = null;
		currentResponse = null;
		inBuffer.clear();
		expect = -1;
		conn.handleReadData = null;
	}

public:
	string agent = "ae.net.http.client (+https://github.com/CyberShadow/ae)";
	bool compat = false;
	string[] cookies;

public:
	this(Duration timeout = 30.seconds)
	{
		assert(timeout > Duration.zero);
		conn = new ClientSocket();
		conn.setIdleTimeout(timeout);
		conn.handleConnect = &onConnect;
		conn.handleDisconnect = &onDisconnect;
	}

	void request(HttpRequest request)
	{
		//debug writefln("New HTTP request: %s", request.url);
		currentRequest = request;
		currentResponse = null;
		conn.handleReadData = &onNewResponse;
		expect = 0;
		if (request.proxy !is null)
			conn.connect(request.proxyHost, request.proxyPort);
		else
			conn.connect(request.host, request.port);
	}

	bool connected()
	{
		return currentRequest !is null;
	}

public:
	// Provide the following callbacks
	void delegate(HttpResponse response, string disconnectReason) handleResponse;
}

/// Asynchronous HTTP request
void httpRequest(HttpRequest request, void delegate(Data) resultHandler, void delegate(string) errorHandler)
{
	void responseHandler(HttpResponse response, string disconnectReason)
	{
		if (!response)
			if (errorHandler)
				errorHandler(disconnectReason);
			else
				throw new Exception(disconnectReason);
		else
			if (errorHandler)
				try
					resultHandler(response.getContent());
				catch (Exception e)
					errorHandler(e.msg);
			else
				resultHandler(response.getContent());
	}

	auto client = new HttpClient;
	client.handleResponse = &responseHandler;
	client.request(request);
}

/// ditto
void httpGet(string url, void delegate(Data) resultHandler, void delegate(string) errorHandler)
{
	auto request = new HttpRequest;
	request.resource = url;
	httpRequest(request, resultHandler, errorHandler);
}

/// ditto
void httpGet(string url, void delegate(string) resultHandler, void delegate(string) errorHandler)
{
	httpGet(url,
		(Data data)
		{
			auto result = (cast(string)data.contents).idup;
			std.utf.validate(result);
			resultHandler(result);
		},
		errorHandler);
}

/// ditto
void httpPost(string url, string[string] vars, void delegate(string) resultHandler, void delegate(string) errorHandler)
{
	auto request = new HttpRequest;
	request.resource = url;
	request.method = "POST";
	request.headers["Content-Type"] = "application/x-www-form-urlencoded";
	request.data = [Data(encodeUrlParameters(vars))];
	httpRequest(request,
		(Data data)
		{
			auto result = (cast(string)data.contents).idup;
			std.utf.validate(result);
			resultHandler(result);
		},
		errorHandler);
}
