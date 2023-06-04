/**
 * Support for implementing CGI scripts.
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

module ae.net.http.cgi.script;

import core.runtime : Runtime;

import std.algorithm.searching : startsWith, canFind;
import std.conv : to, text;
import std.exception : enforce;
import std.path : baseName;
import std.process : environment;
import std.stdio : stdin, stdout, File;

import ae.net.http.cgi.common;
import ae.net.http.common;
import ae.net.ietf.headers : Headers, normalizeHeaderName;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.sys.file : readExactly;
import ae.utils.text.ascii : toDec;

/// Return true if the current process was invoked as a CGI script.
bool inCGI()
{
	return !!environment.get("GATEWAY_INTERFACE", null);
}

/// Return true if it seems likely that we are being invoked as an NPH
/// (non-parsed headers) script.
bool isNPH()
{
	// https://www.htmlhelp.com/faq/cgifaq.2.html#8
	return Runtime.args[0].baseName.startsWith("nph-");
}

/// Load the CGI request from the environment / standard input.
CGIRequest readCGIRequest(
	string[string] env = environment.toAA(),
	File input = stdin,
)
{
	auto request = CGIRequest.fromAA(env);

	if (request.vars.contentLength)
	{
		auto contentLength = request.vars.contentLength.to!size_t;
		if (contentLength)
		{
			auto data = Data(contentLength);
			data.asDataOf!ubyte.enter((scope contents) {
				input.readExactly(contents)
					.enforce("EOF while reading content data");
			});
			request.data = DataVec(data);
		}
	}

	return request;
}

private struct FileWriter
{
	File f;
	void put(T...)(auto ref T args) { f.write(args); }
}

/// Write the response headers from a HTTP response in CGI format.
void writeCGIHeaders(Writer)(HttpResponse r, ref Writer writer)
{
	auto headers = r.headers;
	if (r.status)
		headers.require("Status", text(ushort(r.status), " ", r.statusMessage));

	static immutable string[] headerOrder = ["Location", "Content-Type", "Status"];
	foreach (name; headerOrder)
		if (auto p = name in headers)
			writer.put(name, ": ", *p, "\n");

	foreach (name, value; headers)
		if (!headerOrder.canFind(name.normalizeHeaderName))
			writer.put(name, ": ", value, "\n");
	writer.put("\n");
}

/// Write the response headers from a HTTP response in CGI NPH format.
void writeNPHHeaders(Writer)(HttpResponse r, ref Writer writer)
{
	char[5] statusBuf;
	writer.put("HTTP/1.0 ", toDec(ushort(r.status), statusBuf), " ", r.statusMessage, "\n");
	foreach (string header, string value; r.headers)
		writer.put(header, ": ", value, "\n");
	writer.put("\n");
}

/// Write a HTTP response in CGI format.
void writeCGIResponse(HttpResponse r)
{
	auto writer = FileWriter(stdout);
	writeCGIHeaders(r, writer);

	foreach (datum; r.data)
		datum.enter((scope contents) {
			stdout.rawWrite(contents);
		});
}

/// Write a HTTP response in CGI NPH format.
void writeNPHResponse(HttpResponse r)
{
	auto writer = FileWriter(stdout);
	writeNPHHeaders(r, writer);

	foreach (datum; r.data)
		datum.enter((scope contents) {
			stdout.rawWrite(contents);
		});
}
