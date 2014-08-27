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

import std.file;
import std.net.curl;
import std.string;

import ae.net.ietf.url;
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
}

static this()
{
	net = new CurlNetwork();
}
