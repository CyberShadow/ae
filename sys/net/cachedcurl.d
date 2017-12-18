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

	private struct Metadata
	{
		HTTP.StatusLine statusLine;
		string[][string] headers;
	}

	/*private*/ static void req(CachedCurlNetwork instance, string url, HTTP.Method method, const(void)[] data, string target, string metadataPath)
	{
		with (instance)
		{
			http.clearRequestHeaders();
			http.method = method;
			if (method == HTTP.Method.head)
				http.maxRedirects = uint.max;
			else
				http.maxRedirects = 10;
			auto host = url.split("/")[2];
			if (cookieDir)
			{
				auto cookiePath = buildPath(cookieDir, host ~ cookieExt);
				if (cookiePath.exists)
					http.addRequestHeader("Cookie", cookiePath.readText.chomp());
			}
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
			if (data)
				http.onSend = (void[] buf)
					{
						size_t len = min(buf.length, data.length);
						buf[0..len] = data[0..len];
						data = data[len..$];
						return len;
					};
			else
				http.onSend = null;
			download!HTTP(url, target, http);
			write(metadataPath, metadata.toJson);
		}
	}

	private struct Response
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
			enforce(ok, "Request failed: " ~ metadata.statusLine.reason);
			return this;
		}
	}

	private Response cachedReq(string url, HTTP.Method method, in void[] data = null)
	{
		auto hash = getDigestString!MD5(url ~ cast(char)method ~ data);
		auto path = buildPath(cacheDir, hash[0..2], hash);
		ensurePathExists(path);
		auto metadataPath = path ~ ".metadata";
		if (path.exists && path.timeLastModified.stdTime < epoch)
			path.remove();
		cached!req(this, url, method, data, path, metadataPath);
		return Response(path, metadataPath);
	}

	override void downloadFile(string url, string target)
	{
		std.file.copy(cachedReq(url, HTTP.Method.get).checkOK.responsePath, target);
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

static this()
{
	net = new CachedCurlNetwork();
}
