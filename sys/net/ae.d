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
import ae.sys.net;

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
}

static this()
{
	net = new AENetwork();
}
