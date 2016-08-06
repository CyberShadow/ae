/**
 * IRC client demo.
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

module ae.demo.irc.irctest;

import ae.net.asockets;
import ae.net.irc.client;

void main()
{
	auto tcp = new TcpConnection();
	auto c = new IrcClient(tcp);
	c.connectNickname = "ae-test";
	c.realname = "https://github.com/CyberShadow/ae";
	c.handleConnect =
	{
		c.join("#aetest");
		c.message("#aetest", "Test");
		c.disconnect("Bye");
	};

	tcp.connect("irc.gamesurge.net", 6667);

	socketManager.loop();
}
