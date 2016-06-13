/**
 * Asynchronous OAuth via ae.net.
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

module ae.net.oauth.async;

import ae.net.http.common;

import ae.net.oauth.common;

void prepareRequest(ref OAuthSession session, HttpRequest request)
{
	UrlParameters[] parameters;
	parameters ~= request.urlParameters;
	if (request.headers.get("Content-Type", "") == "application/x-www-form-urlencoded")
		parameters ~= request.decodePostData();
	auto oauthParams = session.prepareRequest(request.baseURL, request.method, parameters);

	request.headers.add("Authorization", oauthHeader(oauthParams));

	// auto params = request.urlParameters;
	// foreach (name, value; oauthParams)
	// 	params.add(name, value);
	// request.urlParameters = params;
}
