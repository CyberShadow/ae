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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.net.ae;

import ae.net.http.client;
import ae.net.ietf.url;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec;
import ae.sys.net;
import ae.utils.promise : Promise;
import ae.utils.promise.await : awaitSync;

static import std.file;

/// `Network` implementation based on `ae.net`.
class AENetwork : Network
{
	private Data getData(string url)
	{
		auto promise = new Promise!Data;

		httpGet(url,
			(Data data) { promise.fulfill(data); },
			(string error) { promise.reject(new Exception(error)); }
		);

		return promise.awaitSync();
	}

	override void downloadFile(string url, string target)
	{
		Data data = getData(url);
		data.enter((contents) {
			std.file.write(target, contents);
		});
	} ///

	override ubyte[] getFile(string url)
	{
		return getData(url).toGC();
	} ///

	override ubyte[] post(string url, const(ubyte)[] data)
	{
		auto promise = new Promise!Data;

		httpPost(url, DataVec(Data(data)), null,
			(Data data) { promise.fulfill(data); },
			(string error) { promise.reject(new Exception(error)); }
		);

		return promise.awaitSync().toGC();
	} ///

	override bool urlOK(string url)
	{
		auto promise = new Promise!bool;

		auto request = new HttpRequest;
		request.method = "HEAD";
		request.resource = url;
		try
		{
			.httpRequest(request,
				(HttpResponse response, string disconnectReason)
				{
					if (!response)
						promise.fulfill(false);
					else
						promise.fulfill(response.status == HttpStatusCode.OK);
				} ///
			);

			return promise.awaitSync();
		} ///
		catch (Exception e)
			return false;
	} ///

	override string resolveRedirect(string url)
	{
		auto promise = new Promise!string;

		auto request = new HttpRequest;
		request.method = "HEAD";
		request.resource = url;
		.httpRequest(request,
			(HttpResponse response, string disconnectReason)
			{
				if (!response)
					promise.reject(new Exception(disconnectReason));
				else
				{
					string location = response.headers.get("Location", null);
					if (location)
						location = url.applyRelativeURL(location);
					promise.fulfill(location);
				} ///
			} ///
		);

		return promise.awaitSync();
	} ///

	override HttpResponse httpRequest(HttpRequest request)
	{
		auto promise = new Promise!HttpResponse;

		.httpRequest(request,
			(HttpResponse response, string disconnectReason)
			{
				if (!response)
					promise.reject(new Exception(disconnectReason));
				else
					promise.fulfill(response);
			} ///
		);

		return promise.awaitSync();
	} ///
}

static this()
{
	net = new AENetwork();
}
