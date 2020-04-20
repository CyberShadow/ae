/**
 * ae.sys.net implementation using std.net.curl
 * Note: std.net.curl requires libcurl.
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

module ae.sys.net.curl;

import etc.c.curl : CurlSeekPos, CurlSeek;

import std.algorithm.comparison;
import std.file;
import std.net.curl;
import std.string;

import ae.net.http.common;
import ae.net.ietf.url;
import ae.sys.data;
import ae.sys.net;

class CurlNetwork : Network
{
	override void downloadFile(string url, string target)
	{
		std.file.write(target, getFile(url));
	}

	override void[] getFile(string url)
	{
		return get!(AutoProtocol, ubyte)(url);
	}

	override void[] post(string url, in void[] data)
	{
		return .post!ubyte(url, data);
	}

	override bool urlOK(string url)
	{
		try
		{
			auto http = HTTP(url);
			http.method = HTTP.Method.head;
			http.perform();
			return http.statusLine.code == 200; // OK
		}
		catch (Exception e)
			return false;
	}

	override string resolveRedirect(string url)
	{
		string result = null;

		auto http = HTTP(url);
		http.method = HTTP.Method.head;
		http.onReceiveHeader =
			(in char[] key, in char[] value)
			{
				if (icmp(key, "Location")==0)
				{
					result = value.idup;
					if (result)
						result = url.applyRelativeURL(result);
				}
			};
		http.perform();

		return result;
	}

	override HttpResponse httpRequest(HttpRequest request)
	{
		auto http = HTTP();
		http.url = request.url;
		switch (request.method.toUpper)
		{
			case "HEAD"   : http.method = HTTP.Method.head; break;
			case "GET"    : http.method = HTTP.Method.get; break;
			case "POST"   : http.method = HTTP.Method.post; break;
			case "PUT"    : http.method = HTTP.Method.put; break;
			case "DEL"    : http.method = HTTP.Method.del; break;
			case "OPTIONS": http.method = HTTP.Method.options; break;
			case "TRACE"  : http.method = HTTP.Method.trace; break;
			case "CONNECT": http.method = HTTP.Method.connect; break;
			case "PATCH"  : http.method = HTTP.Method.patch; break;
			default: throw new Exception("Unknown HTTP method: " ~ request.method);
		}
		foreach (name, value; request.headers)
			http.addRequestHeader(name, value);

		if (request.data)
		{
			auto requestData = request.data.bytes;
			http.contentLength = requestData.length;
			auto remainingData = requestData;
			http.onSend =
				(void[] buf)
				{
					size_t bytesToSend = min(buf.length, remainingData.length);
					if (!bytesToSend)
						return 0;
					auto dataToSend = remainingData[0 .. bytesToSend];
					{
						size_t p = 0;
						foreach (datum; dataToSend)
						{
							buf[p .. p + datum.length] = datum.contents;
							p += datum.length;
						}
					}
					remainingData = remainingData[bytesToSend .. $].bytes;
					return bytesToSend;
				};
			http.handle.onSeek =
				(long offset, CurlSeekPos mode)
				{
					switch (mode)
					{
						case CurlSeekPos.set:
							remainingData = requestData[cast(size_t) offset .. $].bytes;
							return CurlSeek.ok;
						default:
							return CurlSeek.cantseek;
					}
				};
		}

		auto response = new HttpResponse;
		http.onReceiveStatusLine =
			(HTTP.StatusLine statusLine)
			{
				response.status = cast(HttpStatusCode)statusLine.code;
				response.statusMessage = statusLine.reason;
			};
		http.onReceiveHeader =
			(in char[] key, in char[] value)
			{
				response.headers.add(key.idup, value.idup);
			};
		http.onReceive =
			(ubyte[] data)
			{
				response.data ~= Data(data);
				return data.length;
			};
		http.perform();
		return response;
	}
}

static this()
{
	net = new CurlNetwork();
}
