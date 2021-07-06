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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.net.http.cgi.common;

import std.algorithm.searching : skipOver, findSplit;
import std.array : replace;
import std.conv;
import std.exception : enforce;

import ae.net.http.common : HttpRequest;
import ae.net.ietf.headers : Headers;
import ae.sys.data : Data, DataVec;
import ae.utils.meta : getAttribute;

/// Holds parsed CGI meta-variables.
struct CGIVars
{
	@("AUTH_TYPE"        ) string authType;         /// The CGI "AUTH_TYPE" meta-variable.
	@("CONTENT_LENGTH"   ) string contentLength;    /// The CGI "CONTENT_LENGTH" meta-variable.
	@("CONTENT_TYPE"     ) string contentType;      /// The CGI "CONTENT_TYPE" meta-variable.
	@("GATEWAY_INTERFACE") string gatewayInterface; /// The CGI "GATEWAY_INTERFACE" meta-variable.
	@("PATH_INFO"        ) string pathInfo;         /// The CGI "PATH_INFO" meta-variable.
	@("PATH_TRANSLATED"  ) string pathTranslated;   /// The CGI "PATH_TRANSLATED" meta-variable.
	@("QUERY_STRING"     ) string queryString;      /// The CGI "QUERY_STRING" meta-variable.
	@("REMOTE_ADDR"      ) string remoteAddr;       /// The CGI "REMOTE_ADDR" meta-variable.
	@("REMOTE_HOST"      ) string remoteHost;       /// The CGI "REMOTE_HOST" meta-variable.
	@("REMOTE_IDENT"     ) string remoteIdent;      /// The CGI "REMOTE_IDENT" meta-variable.
	@("REMOTE_USER"      ) string remoteUser;       /// The CGI "REMOTE_USER" meta-variable.
	@("REQUEST_METHOD"   ) string requestMethod;    /// The CGI "REQUEST_METHOD" meta-variable.
	@("SCRIPT_NAME"      ) string scriptName;       /// The CGI "SCRIPT_NAME" meta-variable.
	@("SERVER_NAME"      ) string serverName;       /// The CGI "SERVER_NAME" meta-variable.
	@("SERVER_PORT"      ) string serverPort;       /// The CGI "SERVER_PORT" meta-variable.
	@("SERVER_PROTOCOL"  ) string serverProtocol;   /// The CGI "SERVER_PROTOCOL" meta-variable.
	@("SERVER_SOFTWARE"  ) string serverSoftware;   /// The CGI "SERVER_SOFTWARE" meta-variable.

	// SCGI vars:
	@("REQUEST_URI"      ) string requestUri;       /// The SCGI "REQUEST_URI" meta-variable.
	@("DOCUMENT_URI"     ) string documentUri;      /// The SCGI "DOCUMENT_URI" meta-variable.
	@("DOCUMENT_ROOT"    ) string documentRoot;     /// The SCGI "DOCUMENT_ROOT" meta-variable.

	/// Parse from an environment block (represented as an associate array).
	static typeof(this) fromAA(string[string] env)
	{
		typeof(this) result;
		foreach (i, ref var; result.tupleof)
			var = env.get(getAttribute!(string, result.tupleof[i]), null);
		return result;
	}
}

/// Holds a CGI request.
struct CGIRequest
{
	CGIVars vars;    /// CGI meta-variables.
	Headers headers; /// Request headers.
	DataVec data;    /// Request data.

	/// Parse from an environment block (represented as an associate array).
	static typeof(this) fromAA(string[string] env)
	{
		typeof(this) result;
		result.vars = CGIVars.fromAA(env);

		// Missing `include /etc/nginx/fastcgi_params;` in nginx?
		enforce(result.vars.gatewayInterface, "GATEWAY_INTERFACE not set");

		enforce(result.vars.gatewayInterface == "CGI/1.1",
			"Unknown CGI version: " ~ result.vars.gatewayInterface);

		result.headers = decodeHeaders(env, result.vars.serverProtocol);

		return result;
	}

	/// Extract request headers from an environment block (represented
	/// as an associate array).
	/// Params:
	///  env            = The environment block.
	///  serverProtocol = The protocol (as specified in
	///                   SERVER_PROTOCOL).
	static Headers decodeHeaders(string[string] env, string serverProtocol)
	{
		Headers headers;
		auto protocolPrefix = serverProtocol.findSplit("/")[0] ~ "_";
		foreach (name, value; env)
			if (name.skipOver(protocolPrefix))
				headers.add(name.replace("_", "-"), value);
		return headers;
	}
}

/// Subclass of `HttpRequest` for HTTP requests received via CGI.
class CGIHttpRequest : HttpRequest
{
	CGIVars cgiVars; /// CGI meta-variables.

	/// Construct the HTTP request from a CGI request.
	this(ref CGIRequest cgi)
	{
		cgiVars = cgi.vars;
		headers = cgi.headers;
		if (cgi.vars.requestUri)
			resource = cgi.vars.requestUri;
		else
		if (cgi.vars.documentUri)
			resource = cgi.vars.documentUri;
		else
			resource = cgi.vars.scriptName ~ cgi.vars.pathInfo;
		if (cgi.vars.queryString)
			queryString = cgi.vars.queryString;

		if (cgi.vars.contentType)
			headers.require("Content-Type", cgi.vars.contentType);
		if (cgi.vars.serverName)
			headers.require("Host", cgi.vars.serverName);
		if (cgi.vars.serverPort)
			port = cgi.vars.serverPort.to!ushort;
		method = cgi.vars.requestMethod;
		protocol = cgi.vars.serverProtocol;
		data = cgi.data.dup;
	}
}
