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
import ae.utils.funopt;
import ae.utils.main;

void httpserve(ushort port = 0, string host = null)
{
	HttpServer server;

	server = new HttpServer();
	server.log = consoleLogger("Web");
	server.handleRequest =
		(HttpRequest request, HttpServerConnection conn)
		{
			auto response = new HttpResponseEx();
			response.status = HttpStatusCode.OK;

			try
				response.serveFile(
					decodeUrlParameter(request.resource[1..$]),
					"",
					true,
					formatAddress("http", conn.localAddress, request.host, request.port) ~ "/");
			catch (Exception e)
				response.writeError(HttpStatusCode.InternalServerError, e.msg);
			conn.sendResponse(response);
		};
	server.listen(port, host);
	addShutdownHandler({ server.close(); });

	socketManager.loop();
}

mixin main!(funopt!httpserve);
