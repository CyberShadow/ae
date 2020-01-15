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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
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

import ae.net.ietf.url;
import ae.sys.file;
import ae.sys.net;
import ae.utils.digest;
import ae.utils.json;
import ae.utils.time;

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
	}

	static struct Metadata
	{
		HTTP.StatusLine statusLine;
		string[][string] headers;
	}

	static struct Request
	{
		string url;
		HTTP.Method method = HTTP.Method.get;
		const(void)[] data;
		const(string[2])[] headers;

		int maxRedirects = int.min; // choose depending or method
	}

	/*private*/ static void req(CachedCurlNetwork instance, in ref Request request, string target, string metadataPath)
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
		string responsePath;
		string metadataPath;

		@property ubyte[] responseData()
		{
			checkOK();
			return cast(ubyte[])std.file.read(responsePath);
		}

		@property Metadata metadata()
		{
			return metadataPath.exists ? metadataPath.readText.jsonParse!Metadata : Metadata.init;
		}

		@property bool ok()
		{
			return metadata.statusLine.code / 100 == 2;
		}

		ref Response checkOK()
		{
			if (!ok)
				throw new CachedCurlException(metadata);
			return this;
		}
	}

	static class CachedCurlException : Exception
	{
		Metadata metadata;

		this(Metadata metadata, string fn = __FILE__, size_t ln = __LINE__)
		{
			this.metadata = metadata;
			super("Request failed: " ~ metadata.statusLine.reason, fn, ln);
		}
	}

	Response cachedReq(in ref Request request)
	{
		auto hash = getDigestString!MD5(request.url ~ cast(char)request.method ~ request.data);
		auto path = buildPath(cacheDir, hash[0..2], hash);
		ensurePathExists(path);
		auto metadataPath = path ~ ".metadata";
		if (path.exists && path.timeLastModified.stdTime < epoch)
			path.remove();
		cached!req(this, request, path, metadataPath);
		return Response(path, metadataPath);
	}

	Response cachedReq(string url, HTTP.Method method, in void[] data = null)
	{
		auto req = Request(url, method, data);
		return cachedReq(req);
	}

	string downloadFile(string url)
	{
		return cachedReq(url, HTTP.Method.get).checkOK.responsePath;
	}

	override void downloadFile(string url, string target)
	{
		std.file.copy(downloadFile(url), target);
	}

	override void[] getFile(string url)
	{
		return cachedReq(url, HTTP.Method.get).responseData;
	}

	override bool urlOK(string url)
	{
		return cachedReq(url, HTTP.Method.get).ok;
	}

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
	}

	override void[] post(string url, in void[] data)
	{
		return cachedReq(url, HTTP.Method.post, data).responseData;
	}
}

alias CachedCurlException = CachedCurlNetwork.CachedCurlException;

static this()
{
	net = new CachedCurlNetwork();
}
