/**
 * ae.sys.net implementation using ae.net
 * Note: ae.net requires an SSL provider for HTTPS links.
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

module ae.sys.net.ae;

import ae.net.asockets;
import ae.net.http.client;
import ae.net.ietf.url;
import ae.sys.net;

static import std.file;

class AENetwork : Network
{
	private Data getData(string url)
	{
		Data result;
		bool got;

		httpGet(url,
			(Data data) { result = data; got = true; },
			(string error) { throw new Exception(error); }
		);

		socketManager.loop();
		assert(got);
		return result;
	}

	override void downloadFile(string url, string target)
	{
		Data data = getData(url);
		std.file.write(target, data.contents);
	}

	override void[] getFile(string url)
	{
		return getData(url).toHeap;
	}

	override void[] post(string url, in void[] data)
	{
		Data result;
		bool got;

		httpPost(url, [Data(data)], null,
			(Data data) { result = data; got = true; },
			(string error) { throw new Exception(error); }
		);

		socketManager.loop();
		assert(got);
		return result.toHeap;
	}

	override bool urlOK(string url)
	{
		bool got, result;

		auto request = new HttpRequest;
		request.method = "HEAD";
		request.resource = url;
		try
		{
			httpRequest(request,
				(HttpResponse response, string disconnectReason)
				{
					got = true;
					if (!response)
						result = false;
					else
						result = response.status == HttpStatusCode.OK;
				}
			);

			socketManager.loop();
		}
		catch (Exception e)
			return false;

		assert(got);
		return result;
	}

	override string resolveRedirect(string url)
	{
		string result; bool got;

		auto request = new HttpRequest;
		request.method = "HEAD";
		request.resource = url;
		httpRequest(request,
			(HttpResponse response, string disconnectReason)
			{
				if (!response)
					throw new Exception(disconnectReason);
				else
				{
					got = true;
					result = response.headers.get("Location", null);
					if (result)
						result = url.applyRelativeURL(result);
				}
			}
		);

		socketManager.loop();
		assert(got);
		return result;
	}
}

static this()
{
	net = new AENetwork();
}
