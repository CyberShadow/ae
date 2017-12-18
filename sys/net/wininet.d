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
version(Windows):

import std.array;
import std.exception;
import std.string;
import std.typecons : RefCounted;

import ae.net.http.common : HttpRequest;
import ae.net.ietf.url;
import ae.sys.net;
import ae.sys.windows.dll;
import ae.sys.windows.exception;
import ae.utils.meta;

import ae.sys.windows.imports;
mixin(importWin32!q{winbase});
mixin(importWin32!q{windef});
mixin(importWin32!q{wininet});

class WinINetNetwork : Network
{
private:
	// Don't require wininet.lib
	mixin DynamicLoadMulti!("wininet.dll",
		HttpQueryInfoA,
		HttpOpenRequestA,
		HttpSendRequestA,
		InternetCloseHandle,
		InternetConnectA,
		InternetOpenA,
		InternetOpenUrlA,
		InternetReadFile,
	);

protected:
	struct HNetImpl
	{
		HINTERNET hNet;
		alias hNet this;
		~this() { if (hNet != hNet.init) InternetCloseHandle(hNet); }
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
			.wenforce("HttpOpenRequest");
		return HNet(hReq);
	}

	final static void sendRequest(ref HNet hReq, string headers = null, in void[] optionalData = null)
	{
		HttpSendRequestA(hReq, headers.ptr, headers.length.to!DWORD, cast(void*)optionalData.ptr, optionalData.length.to!DWORD);
			.wenforce("HttpSendRequest");
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

	final static void doDownload(HNet hUrl, void delegate(ubyte[]) sink)
	{
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

	final static DWORD urlFlags(string url)
	{
		return url.startsWith("https://") ? INTERNET_FLAG_SECURE : 0;
	}

public:
	override void downloadFile(string url, string target)
	{
		import std.stdio;
		auto f = File(target, "wb");
		auto hNet = open();
		doDownload(hNet.I!openUrl(url), &f.rawWrite!ubyte);
	}

	override void[] getFile(string url)
	{
		auto result = appender!(ubyte[]);
		auto hNet = open();
		doDownload(hNet.I!openUrl(url), &result.put!(ubyte[]));
		return result.data;
	}

	override void[] post(string url, in void[] data)
	{
		auto request = new HttpRequest(url);

		auto hNet = open();
		auto hCon = hNet.I!connect(request.host, request.port);
		auto hReq = hCon.I!openRequest("POST", request.resource, urlFlags(url));
		hReq.I!sendRequest(null, data);

		auto result = appender!(ubyte[]);
		doDownload(hReq, &result.put!(ubyte[]));
		return result.data;
	}

	override bool urlOK(string url)
	{
		try
		{
			auto request = new HttpRequest(url);

			auto hNet = open();
			auto hCon = hNet.I!connect(request.host, request.port);
			auto hReq = hCon.I!openRequest("HEAD", request.resource, urlFlags(url));
			hReq.I!sendRequest();

			return hReq.I!httpQueryNumber(HTTP_QUERY_STATUS_CODE) == 200;
		}
		catch (Exception e)
			return false;
	}

	override string resolveRedirect(string url)
	{
		auto request = new HttpRequest(url);

		auto hNet = open(INTERNET_FLAG_NO_AUTO_REDIRECT);
		auto hCon = hNet.I!connect(request.host, request.port);
		auto hReq = hCon.I!openRequest("HEAD", request.resource, INTERNET_FLAG_NO_AUTO_REDIRECT | urlFlags(url));
		hReq.I!sendRequest();

		auto location = hReq.I!httpQueryString(HTTP_QUERY_LOCATION);
		return location ? url.applyRelativeURL(location) : null;
	}
}

static this()
{
	net = new WinINetNetwork();
}
