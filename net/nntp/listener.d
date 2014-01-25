/**
 * NNTP listener (periodically poll server for new messages).
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

module ae.net.nntp.listener;

import ae.net.nntp.client;

import std.datetime;

import ae.sys.timing;
import ae.sys.log;

const POLL_PERIOD = 2.seconds;

class NntpListener
{
private:
	NntpClient client;
	string server;
	string lastDate;
	bool[string] oldMessages;
	TimerTask pollTimer;
	bool connected, polling;
	int queued;

	void reconnect()
	{
		assert(!connected);
		client.connect(server, &onConnect);
	}

	void schedulePoll()
	{
		pollTimer = setTimeout(&poll, POLL_PERIOD);
	}

	void poll()
	{
		pollTimer = null;
		client.getDate(&onDate);
		client.getNewNews("*", lastDate[0..8] ~ " " ~ lastDate[8..14] ~ " GMT", &onNewNews);
	}

	void onConnect()
	{
		connected = true;

		if (polling)
		{
			if (lastDate)
				poll();
			else
				client.getDate(&onDate);
		}
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		connected = false;
		if (polling)
		{
			if (pollTimer && pollTimer.isWaiting())
				pollTimer.cancel();
			if (type != DisconnectType.Requested)
				setTimeout(&reconnect, 10.seconds);
		}
	}

	void onDate(string date)
	{
		if (polling)
		{
			if (lastDate is null)
				schedulePoll();
			lastDate = date;
		}
	}

	void onNewNews(string[] reply)
	{
		bool[string] messages;
		foreach (message; reply[1..$])
			messages[message] = true;

		assert(queued == 0);
		foreach (message, b; messages)
			if (!(message in oldMessages))
			{
				client.getMessage(message, &onMessage);
				queued++;
			}
		oldMessages = messages;
		if (queued==0)
			schedulePoll();
	}

	void onMessage(string[] lines, string num, string id)
	{
		if (handleMessage)
			handleMessage(lines, num, id);

		if (polling)
		{
			queued--;
			if (queued==0)
				schedulePoll();
		}
	}

public:
	this(Logger log)
	{
		client = new NntpClient(log);
		client.handleDisconnect = &onDisconnect;
	}

	void connect(string server)
	{
		this.server = server;
		reconnect();
	}

	void disconnect()
	{
		client.disconnect();
	}

	void startPolling(string lastDate = null)
	{
		assert(!polling, "Already polling");
		polling = true;
		this.lastDate = lastDate;
		if (connected)
			poll();
	}

	void delegate(string[] lines, string num, string id) handleMessage;
}
