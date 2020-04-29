/**
 * Common CGI declarations.
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

module ae.net.http.cgi.common;

import std.algorithm.searching : skipOver, findSplit;
import std.array : replace;
import std.conv;
import std.exception : enforce;

import ae.net.http.common : HttpRequest;
import ae.net.ietf.headers : Headers;
import ae.sys.data : Data;
import ae.utils.meta : getAttribute;

/// CGI meta-variables
struct CGIVars
{
	@("AUTH_TYPE"        ) string authType;
	@("CONTENT_LENGTH"   ) string contentLength;
	@("CONTENT_TYPE"     ) string contentType;
	@("GATEWAY_INTERFACE") string gatewayInterface;
	@("PATH_INFO"        ) string pathInfo;
	@("PATH_TRANSLATED"  ) string pathTranslated;
	@("QUERY_STRING"     ) string queryString;
	@("REMOTE_ADDR"      ) string remoteAddr;
	@("REMOTE_HOST"      ) string remoteHost;
	@("REMOTE_IDENT"     ) string remoteIdent;
	@("REMOTE_USER"      ) string remoteUser;
	@("REQUEST_METHOD"   ) string requestMethod;
	@("SCRIPT_NAME"      ) string scriptName;
	@("SERVER_NAME"      ) string serverName;
	@("SERVER_PORT"      ) string serverPort;
	@("SERVER_PROTOCOL"  ) string serverProtocol;
	@("SERVER_SOFTWARE"  ) string serverSoftware;

	static typeof(this) fromAA(string[string] env)
	{
		typeof(this) result;
		foreach (i, ref var; result.tupleof)
			var = env.get(getAttribute!(string, result.tupleof[i]), null);
		return result;
	}
}

struct CGIRequest
{
	CGIVars vars;
	Headers headers;
	Data[] data;

	static typeof(this) fromAA(string[string] env)
	{
		typeof(this) result;
		result.vars = CGIVars.fromAA(env);

		enforce(result.vars.gatewayInterface == "CGI/1.1",
			"Unknown CGI version: " ~ result.vars.gatewayInterface);

		auto protocolPrefix = result.vars.serverProtocol.findSplit("/")[0] ~ "_";
		foreach (name, value; env)
			if (name.skipOver(protocolPrefix))
				result.headers.add(name.replace("_", "-"), value);

		return result;
	}
}

class CGIHttpRequest : HttpRequest
{
	CGIVars cgiVars;

	this(ref CGIRequest cgi)
	{
		cgiVars = cgi.vars;
		headers = cgi.headers;
		resource = cgi.vars.scriptName ~ cgi.vars.pathInfo;
		queryString = cgi.vars.queryString;

		if (cgi.vars.contentType)
			headers.require("Content-Type", cgi.vars.contentType);
		if (cgi.vars.serverName)
			headers.require("Host", cgi.vars.serverName);
		if (cgi.vars.serverPort)
			port = cgi.vars.serverPort.to!ushort;
		method = cgi.vars.requestMethod;
		protocol = cgi.vars.serverProtocol;
		data = cgi.data;
	}
}
