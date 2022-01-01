/**
 * ae.sys.net implementation for HTTP using Curl,
 * with caching and cookie support
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

module ae.sys.net.cachedcurl;

// TODO: refactor into an abstract Cached!Network wrapper?

import std.algorithm.comparison;
import std.conv;
import std.exception;
import std.file;
import std.net.curl;
import std.path;
import std.string;
import std.typecons;

import ae.net.http.common;
import ae.net.ietf.url;
import ae.sys.dataio;
import ae.sys.dataset;
import ae.sys.file;
import ae.sys.net;
import ae.utils.digest;
import ae.utils.json;
import ae.utils.time;

/// libcurl-based implementation of `Network` which caches responses.
/// Allows quickly re-running some deterministic process without redownloading all URLs.
class CachedCurlNetwork : Network
{
	/// Curl HTTP object
	/// Can be customized after construction.
	HTTP http;

	/// Directory for caching responses
	string cacheDir = "cache";

	/// Ignore cache entries older than the given time
	StdTime epoch = 0;

	/// Directory for reading cookies.
	/// May be moved to a lambda in the future.
	/// Format is one file per host, with hostname ~ cookieExt being the file name.
	/// Contents is one line for the entire HTTP "Cookie" header.
	string cookieDir, cookieExt;

	this()
	{
		http = HTTP();
	} ///

	/// Response metadata.
	static struct Metadata
	{
		HTTP.StatusLine statusLine; /// HTTP status line.
		string[][string] headers; /// HTTP response headers.
	}

	static struct Request
	{
		string url; ///
		HTTP.Method method = HTTP.Method.get; ///
		const(void)[] data; ///
		const(string[2])[] headers; ///

		/// Maximum number of redirects to follow.
		/// By default, choose a number appropriate to the method.
		int maxRedirects = int.min;
	} ///

	/*private*/ static void _req(CachedCurlNetwork instance, ref const Request request, string target, string metadataPath)
	{
		with (instance)
		{
			http.clearRequestHeaders();
			http.method = request.method;
			if (request.maxRedirects != int.min)
				http.maxRedirects = request.maxRedirects;
			else
			if (request.method == HTTP.Method.head)
				http.maxRedirects = uint.max;
			else
				http.maxRedirects = 10;
			auto host = request.url.split("/")[2];
			if (cookieDir)
			{
				auto cookiePath = buildPath(cookieDir, host ~ cookieExt);
				if (cookiePath.exists)
					http.addRequestHeader("Cookie", cookiePath.readText.chomp());
			}
			foreach (header; request.headers)
				http.addRequestHeader(header[0], header[1]);
			Metadata metadata;
			http.onReceiveHeader =
				(in char[] key, in char[] value)
				{
					metadata.headers[key.idup] ~= value.idup;
				};
			http.onReceiveStatusLine =
				(HTTP.StatusLine statusLine)
				{
					metadata.statusLine = statusLine;
				};
			if (request.data)
			{
				const(void)[] data = request.data;
				http.addRequestHeader("Content-Length", data.length.text);
				http.onSend = (void[] buf)
					{
						size_t len = min(buf.length, data.length);
						buf[0..len] = data[0..len];
						data = data[len..$];
						return len;
					};
			}
			else
				http.onSend = null;
			download!HTTP(request.url, target, http);
			write(metadataPath, metadata.toJson);
		}
	}

	static struct Response
	{
		string responsePath; /// Path to response data.
		string metadataPath; /// Path to response metadata.

		/// Returns the response data, if it was successful.
		@property ubyte[] responseData()
		{
			checkOK();
			return cast(ubyte[])std.file.read(responsePath);
		}

		/// Returns the response metadata.
		@property Metadata metadata()
		{
			return metadataPath.exists ? metadataPath.readText.jsonParse!Metadata : Metadata.init;
		}

		/// Check if the response succeeded.
		@property bool ok()
		{
			return metadata.statusLine.code / 100 == 2;
		}

		/// Check if the response succeeded, and throws an error if not.
		ref Response checkOK() return
		{
			if (!ok)
				throw new CachedCurlException(metadata);
			return this;
		}
	} ///

	/// Exception thrown for failed requests (server errors).
	static class CachedCurlException : Exception
	{
		Metadata metadata; ///

		private this(Metadata metadata, string fn = __FILE__, size_t ln = __LINE__)
		{
			this.metadata = metadata;
			super("Request failed: " ~ metadata.statusLine.reason, fn, ln);
		}
	}

	/// Perform a raw request and return information about the resulting cached response.
	Response cachedReq(ref const Request request)
	{
		auto hash = getDigestString!MD5(request.url ~ cast(char)request.method ~ request.data);
		auto path = buildPath(cacheDir, hash[0..2], hash);
		ensurePathExists(path);
		auto metadataPath = path ~ ".metadata";
		if (path.exists && path.timeLastModified.stdTime < epoch)
			path.remove();
		cached!_req(this, request, path, metadataPath);
		return Response(path, metadataPath);
	}

	/// ditto
	Response cachedReq(string url, HTTP.Method method, in void[] data = null)
	{
		auto req = Request(url, method, data);
		return cachedReq(req);
	}

	string downloadFile(string url)
	{
		return cachedReq(url, HTTP.Method.get).checkOK.responsePath;
	} /// Download a file and return the response path.

	override void downloadFile(string url, string target)
	{
		std.file.copy(downloadFile(url), target);
	} ///

	override void[] getFile(string url)
	{
		return cachedReq(url, HTTP.Method.get).responseData;
	} ///

	override bool urlOK(string url)
	{
		return cachedReq(url, HTTP.Method.get).ok;
	} ///

	override string resolveRedirect(string url)
	{
		return
			url.applyRelativeURL(
				cachedReq(url, HTTP.Method.head, null)
				.metadata
				.headers
				.get("location", null)
				.enforce("Not a redirect: " ~ url)
				[$-1]);
	} ///

	override void[] post(string url, in void[] data)
	{
		return cachedReq(url, HTTP.Method.post, data).responseData;
	} ///

	override HttpResponse httpRequest(HttpRequest request)
	{
		Request req;
		req.url = request.url;
		switch (request.method.toUpper)
		{
			case "HEAD"   : req.method = HTTP.Method.head; break;
			case "GET"    : req.method = HTTP.Method.get; break;
			case "POST"   : req.method = HTTP.Method.post; break;
			case "PUT"    : req.method = HTTP.Method.put; break;
			case "DEL"    : req.method = HTTP.Method.del; break;
			case "OPTIONS": req.method = HTTP.Method.options; break;
			case "TRACE"  : req.method = HTTP.Method.trace; break;
			case "CONNECT": req.method = HTTP.Method.connect; break;
			case "PATCH"  : req.method = HTTP.Method.patch; break;
			default: throw new Exception("Unknown HTTP method: " ~ request.method);
		}
		req.data = request.data.joinToHeap;
		foreach (name, value; request.headers)
			req.headers ~= [name, value];
		req.maxRedirects = uint.max; // Do not follow redirects, return them as-is

		auto resp = cachedReq(req);
		auto metadata = resp.metadata;

		auto response = new HttpResponse;
		response.status = cast(HttpStatusCode)metadata.statusLine.code;
		response.statusMessage = metadata.statusLine.reason;
		foreach (name, values; metadata.headers)
			foreach (value; values)
				response.headers.add(name, value);
		response.data = DataVec(readData(resp.responsePath));
		return response;
	} ///
}

alias CachedCurlException = CachedCurlNetwork.CachedCurlException; ///

static this()
{
	net = new CachedCurlNetwork();
}
