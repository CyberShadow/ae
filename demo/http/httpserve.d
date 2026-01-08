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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.demo.http.httpserve;

import std.algorithm.searching;
import std.base64;
import std.conv;
import std.datetime;
import std.exception;
import std.stdio;
import std.string;

import ae.net.asockets;
import ae.net.http.common;
import ae.net.http.responseex;
import ae.net.http.server;
import ae.net.ietf.headers;
import ae.net.ssl.openssl;
import ae.sys.log;
import ae.sys.shutdown;
import ae.utils.funopt;
import ae.utils.main;

mixin SSLUseLib;

void httpserve(
	ushort port = 0, string host = null,
	string sslCert = null, string sslKey = null,
	string userName = null, string password = null,
	bool stripQueryParameters = false,
)
{
	HttpServer server;

	if (sslCert || sslKey)
	{
		auto https = new HttpsServer();
		https.ctx.setCertificate(sslCert);
		https.ctx.setPrivateKey(sslKey);
		server = https;
	}
	else
		server = new HttpServer();

	server.log = consoleLogger("Web");
	server.handleRequest =
		(HttpRequest request, HttpServerConnection conn)
		{
			auto response = new HttpResponseEx();

			if ((userName || password) &&
				!response.authorize(request, (reqUser, reqPass) => reqUser == userName && reqPass == password))
				return conn.sendResponse(response);

			response.status = HttpStatusCode.OK;

			auto path = request.resource[1..$];
			if (stripQueryParameters)
				path = path.findSplit("?")[0];

			try
				response.serveFile(
					decodeUrlParameter(path),
					"",
					true,
					formatAddress("http", conn.localAddress, request.host, request.port) ~ "/");
			catch (Exception e)
				response.writeError(request, HttpStatusCode.InternalServerError, e.msg);
			conn.sendResponse(response);
		};
	server.listen(port, host);
	addShutdownHandler((reason) { server.close(); });

	socketManager.loop();
}

mixin main!(funopt!httpserve);
