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

import ae.net.http.server;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.asockets;

class FileServer
{
	HttpServer server;

	this(ushort port)
	{
		server = new HttpServer();
		server.handleRequest = &onRequest;
		port = server.listen(port);
		writefln("Listening on http://localhost:%d/", port);
	}

	HttpResponse onRequest(HttpRequest request, ClientSocket conn)
	{
		auto response = new HttpResponseEx();
		scope(exit) writefln("[%s] %s - %s - %s", Clock.currTime(), conn.remoteAddress, request.resource, response.status);

		try
			response.serveFile(request.resource[1..$], "", true);
		catch (Exception e)
			response.writeError(HttpStatusCode.InternalServerError, e.msg);
		return response;
	}
}

void main(string[] args)
{
	new FileServer(args.length > 1 ? to!ushort(args[1]) : 0);
	socketManager.loop();
}
