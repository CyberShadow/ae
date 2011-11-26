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
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
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

/// Start a HTTP server on a port and serve the files in the current directory.
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
