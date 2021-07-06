/**
 * Synchronous helper to access the GitHub API
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

module ae.net.github.rest;

package(ae):

import std.algorithm.searching;
import std.conv;
import std.string;
import std.utf;

import ae.net.http.common;
import ae.net.ietf.headers;
import ae.net.ietf.url;
import ae.sys.data;
import ae.sys.log;
import ae.sys.net;
import ae.utils.json;
import ae.utils.meta;

struct GitHub
{
	string token;

	void delegate(string) log;

	struct CacheEntry
	{
		string[string] headers;
		string data;
	}
	interface ICache
	{
		string get(string key);
		void put(string key, string value);
	}
	static class NoCache : ICache
	{
		string get(string key) { return null; }
		void put(string key, string value) {}
	}
	ICache cache = new NoCache;

	struct Result
	{
		string[string] headers;
		string data;
	}

	Result query(string url)
	{
		auto request = new HttpRequest;
		request.resource = url;
		if (token)
			request.headers["Authorization"] = "token " ~ token;

		auto cacheKey = url;

		CacheEntry cacheEntry;
		auto cacheEntryStr = cache.get(cacheKey);
		if (cacheEntryStr)
		{
			cacheEntry = cacheEntryStr.jsonParse!CacheEntry();
			auto cacheHeaders = Headers(cacheEntry.headers);

			if (auto p = "ETag" in cacheHeaders)
				request.headers["If-None-Match"] = *p;
			if (auto p = "Last-Modified" in cacheHeaders)
				request.headers["If-Modified-Since"] = *p;
		}

		if (log) log("Getting URL " ~ url);

		auto response = net.httpRequest(request);
		while (true) // Redirect loop
		{
			if (response.status == HttpStatusCode.NotModified)
			{
				if (log) log(" > Cache hit");
				return Result(cacheEntry.headers, cacheEntry.data);
			}
			else
			if (response.status == HttpStatusCode.OK)
			{
				if (log) log(" > Cache miss; ratelimit: %s/%s".format(
					response.headers.get("X-Ratelimit-Remaining", "?"),
					response.headers.get("X-Ratelimit-Limit", "?"),
				));
				scope(failure) if (log) log(response.headers.text);
				auto headers = response.headers.to!(string[string]);
				auto data = (cast(char[])response.getContent().contents).idup;
				cacheEntry.headers = headers;
				cacheEntry.data = data;
				cache.put(cacheKey, toJson(cacheEntry));
				return Result(headers, data);
			}
			else
			if (response.status >= 300 && response.status < 400 && "Location" in response.headers)
			{
				auto location = response.headers["Location"];
				if (log) log(" > Redirect: " ~ location);
				request.resource = applyRelativeURL(request.url, location);
				if (response.status == HttpStatusCode.SeeOther)
				{
					request.method = "GET";
					request.data = null;
				}
				response = net.httpRequest(request);
			}
			else
				throw new Exception("Error with URL " ~ url ~ ": " ~ text(response.status));
		}
	}

	static import std.json;

	std.json.JSONValue[] pagedQuery(string url)
	{
		import std.json : JSONValue, parseJSON;

		JSONValue[] result;
		while (true)
		{
			auto page = query(url);
			result ~= page.data.parseJSON().array;
			auto links = page.headers.get("Link", null).I!parseLinks();
			if ("next" in links)
				url = links["next"];
			else
				break;
		}
		return result;
	}

	/// Parse a "Link" header.
	private static string[string] parseLinks(string s)
	{
		string[string] result;
		auto items = s.split(", "); // Hacky but should never occur inside an URL or "rel" value
		foreach (item; items)
		{
			auto parts = item.split("; "); // ditto
			string url; string[string] args;
			foreach (part; parts)
			{
				if (part.startsWith("<") && part.endsWith(">"))
					url = part[1..$-1];
				else
				{
					auto ps = part.findSplit("=");
					auto key = ps[0];
					auto value = ps[2];
					if (value.startsWith('"') && value.endsWith('"'))
						value = value[1..$-1];
					args[key] = value;
				}
			}
			result[args.get("rel", null)] = url;
		}
		return result;
	}

	unittest
	{
		auto header = `<https://api.github.com/repositories/1257070/pulls?per_page=100&page=2>; rel="next", ` ~
			`<https://api.github.com/repositories/1257070/pulls?per_page=100&page=3>; rel="last"`;
		assert(parseLinks(header) == [
			"next" : "https://api.github.com/repositories/1257070/pulls?per_page=100&page=2",
			"last" : "https://api.github.com/repositories/1257070/pulls?per_page=100&page=3",
		]);
	}

	string post(string url, Data jsonData)
	{
		auto request = new HttpRequest;
		request.resource = url;
		request.method = "POST";
		if (token)
			request.headers["Authorization"] = "token " ~ token;
		request.headers["Content-Type"] = "application/json";
		request.data = DataVec(jsonData);

		auto response = net.httpRequest(request);
		string result = cast(string)response.data.joinToHeap;
		validate(result);
		return result;
	}
}
