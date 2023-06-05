﻿/**
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
 *   Vladimir Panteleev <ae@cy.md>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.irc.clientreplay;

import ae.net.asockets;
import ae.utils.array : asBytes;

/// `IConnection` implementation which replays an `IrcClient` log file.
class IrcClientLogSource : IConnection
{
	/// `IConnection` stubs.
	bool isConnected;
	@property ConnectionState state() { return isConnected ? ConnectionState.connected : ConnectionState.disconnected; } /// ditto

	void send(scope Data[] data, int priority) {} /// ditto
	alias send = IConnection.send; /// ditto

	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested) {} /// ditto

	@property void handleConnect(ConnectHandler value) { connectHandler = value; } /// ditto
	private ConnectHandler connectHandler;

	@property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
	} /// ditto
	private ReadDataHandler readDataHandler;

	@property void handleDisconnect(DisconnectHandler value) {} /// ditto
	@property void handleBufferFlushed(BufferFlushedHandler value) {} /// ditto

	void recv(Data data)
	{
		if (readDataHandler)
			readDataHandler(data);
	} /// ditto

	/// Play this log file.
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
				recv(Data(line[2..$].asBytes));
		}
	}
}
