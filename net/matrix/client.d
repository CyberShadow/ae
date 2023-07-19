/**
 * A simple Matrix client. Experimental!
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

module ae.net.matrix.client;

import core.time;

import std.conv : to;
import std.exception;
import std.json : parseJSON, JSONValue;

import ae.net.http.client;
import ae.net.matrix.common;
import ae.sys.data;
import ae.sys.dataset;
import ae.sys.log;
import ae.sys.timing;
import ae.utils.array;
import ae.utils.json : JSONFragment;
import ae.utils.promise;
import ae.utils.text : randomString;

final class MatrixClient
{
private:
	string host;
	string clientAccessToken;
	Promise!string serverBaseURL;

	Promise!string getServerHost()
	{
		return serverBaseURL.require({
			auto p = new Promise!string;
			httpGet("https://" ~ host ~ "/.well-known/matrix/client",
				(string s) { p.fulfill(s.parseJSON()["m.homeserver"]["base_url"].str); },
				(string err) { p.reject(new Exception(err)); },
			);
			return p;
		}());
	}

	enum timeout = 5.minutes;

	/// Send a request (with retry).
	Promise!JSONValue send(string path, string method = "GET", JSONFragment data = JSONFragment.init)
	{
		auto p = new Promise!JSONValue;
		getServerHost().then(
			(string baseURL)
			{
				int retries;
				void request()
				{
					void retry(Duration backoff, string msg)
					{
						if (retries++ >= 10)
							return p.reject(new Exception(msg));
						setTimeout(&request, backoff);
					}

					auto url = baseURL ~ path;
					auto r = new HttpRequest(url);
					r.headers["Authorization"] = "Bearer " ~ clientAccessToken;
					r.method = method;
					if (data)
					{
						r.headers["Content-Type"] = "application/json";
						r.data = DataVec(Data(data.json.asBytes));
					}
					auto c = new HttpsClient(timeout);
					c.handleResponse = (HttpResponse response, string disconnectReason)
					{
						try
						{
							if (!response)
								return retry(10.seconds, disconnectReason);
							enforce(response.headers.get("Content-Type", null) == "application/json", "Expected application/json");
							auto j = response.getContent().asDataOf!char.toGC.parseJSON();
							if (response.status == HttpStatusCode.TooManyRequests)
								return retry(
									j.object.get("retry_after_ms", JSONValue(10_000)).integer.msecs,
									j.object.get("error", JSONValue(response.statusMessage)).str,
								);
							if (response.status != HttpStatusCode.OK)
								throw new Exception(j.object.get("error", JSONValue(response.statusMessage)).str);
							p.fulfill(j);
						}
						catch (Exception e)
							p.reject(e);
					};
					c.request(r);
				}
				request();
			}
		);
		return p;
	}

	alias Subscription = void delegate(JSONValue);
	Subscription[] subscriptions;

	void sync(string since = null)
	{
		auto queryParameters = [
			"timeout": timeout.total!"msecs".to!string,
		];
		if (since)
			queryParameters["since"] = since;
		send("/_matrix/client/v3/sync?" ~ encodeUrlParameters(queryParameters))
			.then((JSONValue j) {
				if (since)
					foreach (subscription; subscriptions)
						subscription(j);
				sync(j["next_batch"].str);
			})
			.except((Exception e) {
				if (log) log("Sync error: " ~ e.msg);
				setTimeout(&sync, 10.seconds, since);
			});
	}

public:
	Logger log;

	this(string host, string clientAccessToken)
	{
		this.host = host;
		this.clientAccessToken = clientAccessToken;
	}

	Promise!EventId send(RoomId roomId, MessageEventType eventType, RoomMessage roomMessage)
	{
		auto txnId = randomString();
		return send("/_matrix/client/r0/rooms/" ~ roomId.value ~ "/send/" ~ eventType ~ "/" ~ txnId, "PUT", roomMessage.fragment)
			.then((JSONValue response)
			{
				return response["event_id"].str.EventId;
			})
		;
	}

	void subscribe(void delegate(JSONValue) subscription)
	{
		if (!subscriptions)
			sync();
		subscriptions ~= subscription;
	}
}
