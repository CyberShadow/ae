/**
 * Demo: HTTP request through SOCKS5 proxy.
 *
 * This program demonstrates how to use the SOCKS5ClientAdapter to
 * make HTTP requests through a SOCKS5 proxy server using HttpClient.
 *
 * Usage:
 *   socks5demo [PROXY-HOST [PROXY-PORT [URL]]]
 *
 * Example:
 *   # Using a local SOCKS5 proxy (e.g., SSH tunnel):
 *   # ssh -D 1080 user@server
 *   socks5demo localhost 1080 http://example.com/
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

module ae.demo.socks5.socks5demo;

import core.time : seconds;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.http.common;
import ae.net.socks.socks5;
import ae.net.ssl.openssl;
import ae.sys.log;
import ae.utils.funopt;
import ae.utils.main;

mixin SSLUseLib;

void socks5demo(
	string proxyHost = "localhost",
	ushort proxyPort = 1080,
	string url = "http://example.com/",
)
{
	auto log = consoleLogger("SOCKS5Demo");

	log(format("Connecting to SOCKS5 proxy at %s:%d", proxyHost, proxyPort));
	log(format("Fetching URL: %s", url));

	// Detect if this is HTTPS
	bool isHttps = url.startsWith("https://");

	// Create a SOCKS5 connector
	auto connector = new SOCKS5Connector(proxyHost, proxyPort);

	// Create the appropriate HTTP client (HTTP or HTTPS) that uses the SOCKS5 connector
	HttpClient client;
	if (isHttps)
	{
		log("Using HTTPS through SOCKS5 (nested adapters: SSL over SOCKS5 over TCP)");
		client = new HttpsClient(30.seconds, connector);
	}
	else
	{
		log("Using HTTP through SOCKS5");
		client = new HttpClient(30.seconds, connector);
	}

	// Set up response handler
	client.handleResponse = (HttpResponse response, string disconnectReason)
	{
		log(format("Got response: HTTP %d %s", response.status, response.statusMessage));

		if (response.status >= 200 && response.status < 300)
		{
			// Success - print headers
			log("Response headers:");
			foreach (name, value; response.headers)
				log(format("  %s: %s", name, value));

			// Print response body
			writeln();
			writeln("Response body:");
			writeln("----------------------------------------");
			if (response.data)
			{
				import ae.sys.dataset : joinToGC;
				write(cast(string)response.data.joinToGC());
			}
			writeln("----------------------------------------");
		}
		else
		{
			stderr.writefln("HTTP error: %d %s", response.status, response.statusMessage);
			import core.stdc.stdlib : exit;
			exit(1);
		}
	};

	// Handle disconnection
	client.handleDisconnect = (string reason, DisconnectType type)
	{
		log(format("Disconnected: %s (type: %s)", reason, type));

		if (type == DisconnectType.error)
		{
			stderr.writeln("Connection error: ", reason);
			import core.stdc.stdlib : exit;
			exit(1);
		}
	};

	// Create and send the HTTP request
	auto request = new HttpRequest;
	request.method = "GET";
	request.resource = url;  // This parses the URL and sets host/port/resource

	log(format("Sending request: %s %s://%s:%d%s",
		request.method, request.protocol, request.host, request.port, request.resource));

	client.request(request);

	// Run the event loop
	socketManager.loop();
}

mixin main!(funopt!socks5demo);
