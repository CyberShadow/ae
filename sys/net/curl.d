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
}

static this()
{
	net = new CurlNetwork();
}
