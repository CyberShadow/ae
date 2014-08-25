/**
 * ae.sys.net implementation using WinInet
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

import win32.windef;
import win32.wininet;

import ae.sys.net;
import ae.sys.windows.exception;

class WinInet : Network
{
	final void doDownload(string url, void delegate(ubyte[]) sink)
	{
		auto hNet = InternetOpenA("ae.sys.net.wininet", INTERNET_OPEN_TYPE_PRECONFIG, null, null, 0)
			.wenforce("InternetOpen");
		scope(exit) InternetCloseHandle(hNet);

		auto hUrl = InternetOpenUrlA(hNet, url.toStringz(), null, 0xFFFFFFFF, INTERNET_FLAG_RELOAD, 0)
			.wenforce("InternetOpenUrl");
		scope(exit) InternetCloseHandle(hUrl);

		// Check response info
		{
			DWORD error;
			char[0x1000] errorBuf;
			DWORD errorSize = errorBuf.sizeof;
			InternetGetLastResponseInfoA(&error, errorBuf.ptr, &errorSize)
				.wenforce("InternetGetLastResponseInfo");
			enforce(error == 0, "Internet error %d (%s)".format(error, errorBuf[0..errorSize]));
		}

		// Check HTTP status code
		{
			DWORD statusCode;
			DWORD statusCodeLength = statusCode.sizeof;
			DWORD index = 0;
			HttpQueryInfo(hUrl, HTTP_QUERY_STATUS_CODE | HTTP_QUERY_FLAG_NUMBER, &statusCode, &statusCodeLength, &index)
				.wenforce("HttpQueryInfo");

			if (statusCode != 200)
			{
				char[0x1000] errorBuf;
				DWORD errorSize = errorBuf.sizeof;
				index = 0;

				HttpQueryInfo(hUrl, HTTP_QUERY_STATUS_TEXT, errorBuf.ptr, &errorSize, &index)
					.wenforce("HttpQueryInfo");

				throw new Exception("Bad HTTP status code: %d (%s)".format(statusCode, errorBuf[0..errorSize]));
			}
		}

		// Get total file size
		DWORD bytesTotal;
		{
			DWORD bytesTotalLength = bytesTotal.sizeof;
			DWORD index = 0;
			if (!HttpQueryInfo(hUrl, HTTP_QUERY_CONTENT_LENGTH | HTTP_QUERY_FLAG_NUMBER, &bytesTotal, &bytesTotalLength, &index))
				bytesTotal = 0;
		}

		DWORD bytesReadTotal;

		ubyte[0x10000] buffer = void;
		while (true)
		{
			DWORD bytesRead;
			InternetReadFile(hUrl, buffer.ptr, buffer.length, &bytesRead);
			if (bytesRead==0)
				break;
			sink(buffer[0..bytesRead]);
			bytesReadTotal += bytesRead;
		}

		enforce(!bytesTotal || bytesReadTotal == bytesTotal,
			"Failed to download the whole object (got %s out of %s bytes)".format(bytesReadTotal, bytesTotal));
	}

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
}

static this()
{
	net = new WinInet();
}
