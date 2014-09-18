/**
 * ae.sys.net implementation using WinINet
 * Note: Requires Windows.
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

module ae.sys.net.wininet;

import std.array;
import std.exception;
import std.string;
import std.typecons : RefCounted;

import win32.winbase;
import win32.windef;
import win32.wininet;

import ae.net.http.common : HttpRequest;
import ae.net.ietf.url;
import ae.sys.net;
import ae.sys.windows.exception;
import ae.utils.meta;

class WinINetNetwork : Network
{
protected:
	struct HNetImpl
	{
		HINTERNET hNet;
		alias hNet this;
		~this() { if (hNet != hNet.init) hNet.InternetCloseHandle(); }
	}
	alias HNet = RefCounted!HNetImpl;

	final static HNet open(DWORD flags = 0)
	{
		auto hNet = InternetOpenA("ae.sys.net.wininet", INTERNET_OPEN_TYPE_PRECONFIG, null, null, flags)
			.wenforce("InternetOpen");
		return HNet(hNet);
	}

	final static HNet openUrl(ref HNet hNet, string url)
	{
		auto hUrl = InternetOpenUrlA(hNet, url.toStringz(), null, 0xFFFFFFFF, INTERNET_FLAG_RELOAD, 0)
			.wenforce("InternetOpenUrl");
		return HNet(hUrl);
	}

	final static HNet connect(ref HNet hNet, string serverName, INTERNET_PORT port)
	{
		auto hCon = InternetConnectA(hNet, serverName.toStringz(), port, null, null, INTERNET_SERVICE_HTTP, 0, 0)
			.wenforce("InternetConnect");
		return HNet(hCon);
	}

	final static HNet openRequest(ref HNet hCon, string method, string resource, DWORD flags = 0)
	{
		auto hReq = HttpOpenRequestA(hCon, method.toStringz(), resource.toStringz(), null, null, null, flags, 0);
			.wenforce("InternetConnect");
		return HNet(hReq);
	}

	final static void sendRequest(ref HNet hReq)
	{
		HttpSendRequest(hReq, null, 0, null, 0);
			.wenforce("InternetConnect");
	}

	static ubyte[0x10000] buf = void;

	final static void[][] httpQuery(ref HNet hUrl, uint infoLevel)
	{
		DWORD index = 0;

		void[][] result;
		while (true)
		{
			DWORD size = buf.sizeof;
			if (HttpQueryInfoA(hUrl, infoLevel, buf.ptr, &size, &index))
			{
				if (size == buf.sizeof && (infoLevel & HTTP_QUERY_FLAG_NUMBER))
					size = DWORD.sizeof;
				result ~= buf[0..size].dup;
			}
			else
			if (GetLastError() == ERROR_HTTP_HEADER_NOT_FOUND)
				return result;
			else
				wenforce(false, "HttpQueryInfo");

			if (index == 0)
				return result;
		}
	}

	final static void[] httpQueryOne(ref HNet hUrl, uint infoLevel)
	{
		auto results = hUrl.I!httpQuery(infoLevel);
		enforce(results.length <= 1, "Multiple results for HTTP info query");
		return results.length ? results[0] : null;
	}

	final static string httpQueryString(ref HNet hUrl, uint infoLevel)
	{
		return cast(string)hUrl.I!httpQueryOne(infoLevel);
	}

	final static uint httpQueryNumber(ref HNet hUrl, uint infoLevel)
	{
		DWORD[] results = cast(DWORD[])hUrl.I!httpQueryOne(infoLevel | HTTP_QUERY_FLAG_NUMBER);
		enforce(results.length, "No result for HTTP info query");
		return results[0];
	}

	final static void doDownload(string url, void delegate(ubyte[]) sink)
	{
		auto hNet = open();
		auto hUrl = hNet
			.I!openUrl(url);

		// Check HTTP status code
		auto statusCode = hUrl.I!httpQueryNumber(HTTP_QUERY_STATUS_CODE);
		if (statusCode != 200)
		{
			auto statusText = hUrl.I!httpQueryString(HTTP_QUERY_STATUS_TEXT);
			throw new Exception("Bad HTTP status code: %d (%s)".format(statusCode, statusText));
		}

		// Get total file size
		DWORD bytesTotal = 0;
		try
			bytesTotal = hUrl.I!httpQueryNumber(HTTP_QUERY_CONTENT_LENGTH);
		catch (Exception e) {}

		DWORD bytesReadTotal;

		while (true)
		{
			DWORD bytesRead;
			InternetReadFile(hUrl, buf.ptr, buf.length, &bytesRead);
			if (bytesRead==0)
				break;
			sink(buf[0..bytesRead]);
			bytesReadTotal += bytesRead;
		}

		enforce(!bytesTotal || bytesReadTotal == bytesTotal,
			"Failed to download the whole object (got %s out of %s bytes)".format(bytesReadTotal, bytesTotal));
	}

public:
	override void downloadFile(string url, string target)
	{
		import std.stdio;
		auto f = File(target, "wb");
		doDownload(url,
			(ubyte[] bytes)
			{
				f.rawWrite(bytes);
			}
		);
	}

	override void[] getFile(string url)
	{
		auto result = appender!(ubyte[]);
		doDownload(url,
			(ubyte[] bytes)
			{
				result.put(bytes);
			}
		);
		return result.data;
	}

	override string resolveRedirect(string url)
	{
		auto request = new HttpRequest(url);

		auto hNet = open(INTERNET_FLAG_NO_AUTO_REDIRECT);
		auto hCon = hNet.I!connect(request.host, request.port);
		auto hReq = hCon.I!openRequest("HEAD", request.resource, INTERNET_FLAG_NO_AUTO_REDIRECT);
		hReq.I!sendRequest();

		auto location = hReq.I!httpQueryString(HTTP_QUERY_LOCATION);
		return location ? url.applyRelativeURL(location) : null;
	}
}

static this()
{
	net = new WinINetNetwork();
}
