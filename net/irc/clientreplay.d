/**
 * Replay an IRC session from an IrcClient log file.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.irc.clientreplay;

import ae.net.asockets;

class IrcClientLogSource : IConnection
{
	bool isConnected;
	@property bool connected() { return isConnected; }

	@property bool disconnecting() { return false; }

	void send(Data[] data, int priority) {}
	alias send = IConnection.send;

	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested) {}

	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	private ConnectHandler connectHandler;

	@property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
	}
	private ReadDataHandler readDataHandler;

	@property void handleDisconnect(DisconnectHandler value) {}

	void recv(Data data)
	{
		if (readDataHandler)
			readDataHandler(data);
	}

	void run(string fn)
	{
		import std.algorithm;
		import std.stdio;

		isConnected = true;
		connectHandler();

		foreach (line; File(fn).byLine(KeepTerminator.yes))
		{
			if (line[0] != '[')
				continue;
			line = line.findSplit("] ")[2];
			if (line[0] == '<')
				recv(Data(line[2..$]));
		}
	}
}
