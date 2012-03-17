/**
 * Start a HTTP server on a port and serve the files in the current directory.
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

module ae.demo.http.httpserve;

import std.stdio;
import std.conv;
import std.datetime;
import std.exception;
import std.string;

import ae.sys.log;
import ae.sys.shutdown;
import ae.net.http.server;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.ietf.headers;
import ae.net.asockets;

class FileServer
{
	HttpServer server;

	this(ushort port)
	{
		server = new HttpServer();
		server.log = new ConsoleLogger("Web");
		server.handleRequest = &onRequest;
		port = server.listen(port);
		addShutdownHandler({ server.close(); });
	}

	void onRequest(HttpRequest request, HttpServerConnection conn)
	{
		auto response = new HttpResponseEx();

		try
			response.serveFile(
				decodeUrlParameter(request.resource[1..$]),
				"",
				true,
				formatAddress(conn.localAddress, request.host) ~ "/");
		catch (Exception e)
			response.writeError(HttpStatusCode.InternalServerError, e.msg);
		conn.sendResponse(response);
	}
}

void main(string[] args)
{
	new FileServer(args.length > 1 ? to!ushort(args[1]) : 0);
	socketManager.loop();
}
