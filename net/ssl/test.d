/**
 * SSL tests.
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

module ae.net.ssl.test;

import ae.net.asockets;
import ae.net.ssl;

debug(SSL) import std.stdio : stderr;

void testSSL(SSLProvider ssl)
{
	import std.algorithm.searching : endsWith;

	void testServer(string host, ushort port)
	{
		auto c = new TcpConnection;
		auto ctx = ssl.createContext(SSLContext.Kind.client);
		auto s = ssl.createAdapter(ctx, c);
		Data allData;

		s.handleConnect =
		{
			debug(SSL) stderr.writeln("Connected!");
			s.send(Data("GET /d/nettest/testUrl1 HTTP/1.0\r\nHost: thecybershadow.net\r\n\r\n"));
		};
		s.handleReadData = (Data data)
		{
			debug(SSL) { stderr.write(cast(string)data.contents); stderr.flush(); }
			allData ~= data;
		};
		s.handleDisconnect = (string reason, DisconnectType type)
		{
			debug(SSL) { stderr.writeln(reason); }
			assert(type == DisconnectType.graceful);
			assert((cast(string)allData.contents).endsWith("Hello world\n"));
		};
		s.setHostName("thecybershadow.net");
		c.connect(host, port);
		socketManager.loop();
	}

	testServer("thecybershadow.net", 443);
}
