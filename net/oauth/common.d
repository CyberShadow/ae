/**
 * ae.net.oauth.common
 *
 * I have no idea what I'm doing.
 * Please don't use this module.
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

module ae.net.oauth.common;

import std.algorithm.sorting;
import std.base64;
import std.conv;
import std.datetime;
import std.digest.hmac;
import std.digest.sha;

import ae.net.ietf.url;
import ae.utils.text;

debug(OAUTH) import std.stdio : stderr;

/// OAuth configuration.
struct OAuthConfig
{
	string consumerKey;    ///
	string consumerSecret; ///
}

/**
   Implements an OAuth client session.

   Example:
   ---
   OAuthSession session;
   session.config.consumerKey    = "(... obtain from service ...)";
   session.config.consumerSecret = "(... obtain from service ...)";
   session.token                 = "(... obtain from service ...)";
   session.tokenSecret           = "(... obtain from service ...)";

   ...

   UrlParameters parameters;
   parameters["payload"] = "(... some data here ...)";
   auto request = new HttpRequest;
   auto queryString = parameters.byPair.map!(p => session.encode(p.key) ~ "=" ~ session.encode(p.value)).join("&");
   auto baseURL = "https://api.example.com/endpoint";
   auto fullURL = baseURL ~ "?" ~ queryString;
   request.resource = fullURL;
   request.method = "POST";
   request.headers["Authorization"] = session.prepareRequest(baseURL, "POST", parameters).oauthHeader;
   httpRequest(request, null);
   ---
*/
struct OAuthSession
{
	OAuthConfig config; ///

	///
	string token, tokenSecret;

	/// Signs a request and returns the relevant parameters for the "Authorization" header.
	UrlParameters prepareRequest(string requestUrl, string method, UrlParameters[] parameters...)
	{
		UrlParameters oauthParams;
		oauthParams["oauth_consumer_key"] = config.consumerKey;
		oauthParams["oauth_token"] = token;
		oauthParams["oauth_timestamp"] = Clock.currTime().toUnixTime().text();
		oauthParams["oauth_nonce"] = randomString();
		oauthParams["oauth_version"] = "1.0";
		oauthParams["oauth_signature_method"] = "HMAC-SHA1";
		oauthParams["oauth_signature"] = signRequest(method, requestUrl, parameters ~ oauthParams);
		return oauthParams;
	}

	/// Calculates the signature for a request.
	string signRequest(string method, string requestUrl, UrlParameters[] parameters...)
	{
		string paramStr;
		bool[string] keys;

		foreach (set; parameters)
			foreach (key, value; set)
				keys[key] = true;

		foreach (key; keys.keys.sort())
		{
			string[] values;
			foreach (set; parameters)
				foreach (value; set.valuesOf(key).sort())
					values ~= value;

			foreach (value; values.sort())
			{
				if (paramStr.length)
					paramStr ~= '&';
				paramStr ~= encode(key) ~ "=" ~ encode(value);
			}
		}

		auto str = encode(method) ~ "&" ~ encode(requestUrl) ~ "&" ~ encode(paramStr);
		debug(OAUTH) stderr.writeln("Signature base string: ", str);

		auto key = encode(config.consumerSecret) ~ "&" ~ encode(tokenSecret);
		debug(OAUTH) stderr.writeln("Signing key: ", key);
		auto digest = hmac!SHA1(cast(ubyte[])str, cast(ubyte[])key);
		return Base64.encode(digest);
	}

	version(ae_unittest) unittest
	{
		// Example from https://dev.twitter.com/oauth/overview/creating-signatures

		OAuthSession session;
		session.config.consumerSecret = "kAcSOqF21Fu85e7zjz7ZN2U4ZRhfV3WpwPAoE3Z7kBw";
		session.tokenSecret = "LswwdoUaIvS8ltyTt5jkRh4J50vUPVVHtR2YPi5kE";

		UrlParameters getVars, postVars, oauthVars;
		getVars["include_entities"] = "true";
		postVars["status"] = "Hello Ladies + Gentlemen, a signed OAuth request!";

		oauthVars["oauth_consumer_key"] = "xvz1evFS4wEEPTGEFPHBog";
		oauthVars["oauth_nonce"] = "kYjzVBB8Y0ZFabxSWbWovY3uYSQ2pTgmZeNu2VS4cg";
		oauthVars["oauth_signature_method"] = "HMAC-SHA1";
		oauthVars["oauth_timestamp"] = "1318622958";
		oauthVars["oauth_token"] = "370773112-GmHxMAgYyLbNEtIKZeRNFsMKPR9EyMZeS9weJAEb";
		oauthVars["oauth_version"] = "1.0";

		auto signature = session.signRequest("POST", "https://api.twitter.com/1/statuses/update.json", getVars, postVars, oauthVars);
		assert(signature == "tnnArxj06cWHq44gCs1OSKk/jLY=");
	}

	/// Alias to `oauthEncode`.
	alias encode = oauthEncode;
}

/// Converts OAuth parameters into a string suitable for the "Authorization" header.
string oauthHeader(UrlParameters oauthParams)
{
	string s;
	foreach (key, value; oauthParams)
		s ~= (s.length ? ", " : "") ~ key ~ `="` ~ oauthEncode(value) ~ `"`;
	return "OAuth " ~ s;
}

static import std.ascii;
/// Performs URL encoding as required by OAuth.
static alias oauthEncode = encodeUrlPart!(c => std.ascii.isAlphaNum(c) || c=='-' || c=='.' || c=='_' || c=='~');
