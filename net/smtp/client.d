/**
 * Simple SMTP client.
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

module ae.net.smtp.client;

import std.algorithm;
import std.conv;
import std.exception;
import std.string;

import core.time;

import ae.net.asockets;
import ae.sys.log;
import ae.sys.timing;
import ae.utils.array;

/// One SmtpClient instance connects, sends one message, and disconnects.
class SmtpClient
{
	enum State
	{
		none,
		connecting,
		greeting,
		hello,
		mailFrom,
		rcptTo,
		data,
		sendingData,
		quit,
		done,
		error
	}

	@property State state() { return _state; }

	this(Logger log, string localDomain, string server, ushort port = 25)
	{
		this.log = log;
		this.localDomain = localDomain;
		this.server = server;
		this.port = port;
	}

	void delegate() handleSent;
	void delegate() handleStateChanged;
	void delegate(string message) handleError;

	void sendMessage(string from, string to, string[] data)
	{
		assert(state == State.none || state == State.done, "SmtpClient busy");
		this.from = from;
		this.to = to;
		this.data = data;
		connect();
	}

private:
	string localDomain, server, from, to;
	ushort port;
	string[] data;
	State _state;

	@property void state(State state)
	{
		_state = state;
		if (handleStateChanged)
			handleStateChanged();
	}

	void connect()
	{
		auto tcp = new TcpConnection();
		IConnection c = tcp;

		c = lineAdapter = new LineBufferedAdapter(c);

		TimeoutAdapter timer;
		c = timer = new TimeoutAdapter(c);
		timer.setIdleTimeout(60.seconds);

		conn = c;

		conn.handleConnect = &onConnect;
		conn.handleDisconnect = &onDisconnect;
		conn.handleReadData = &onReadData;

		log("* Connecting to " ~ server ~ "...");
		state = State.connecting;
		tcp.connect(server, port);
	}

	/// Socket connection.
	LineBufferedAdapter lineAdapter;
	IConnection conn;

	/// Protocol log.
	Logger log;

	void onConnect()
	{
		log("* Connected, waiting for greeting...");
		state = State.greeting;
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		log("* Disconnected (" ~ reason ~ ")");
		if (state < State.quit)
		{
			if (handleError)
				handleError(reason);
			return;
		}

		state = State.done;

		if (handleSent)
			handleSent();
	}

	void sendLine(string line)
	{
		log("< " ~ line);
		lineAdapter.send(line);
	}

	void onReadData(Data data)
	{
		auto line = cast(string)data.toHeap();
		log("> " ~ line);
		try
			handleLine(line);
		catch (Exception e)
		{
			foreach (eLine; e.toString().splitLines())
				log("* " ~ eLine);
			conn.disconnect("Error (%s) while handling line from SMTP server: %s".format(e.msg, line));
		}
	}

	void handleLine(string line)
	{
		string codeStr;
		list(codeStr, null, line) = line.findSplit(" ");
		auto code = codeStr.to!int;

		switch (state)
		{
			case State.greeting:
				enforce(code == 220, "Unexpected greeting");
				state = State.hello;
				sendLine("HELO " ~ localDomain);
				break;
			case State.hello:
				enforce(code == 250, "Unexpected HELO response");
				state = State.mailFrom;
				sendLine("MAIL FROM: " ~ from);
				break;
			case State.mailFrom:
				enforce(code == 250, "Unexpected MAIL FROM response");
				state = State.rcptTo;
				sendLine("RCPT TO: " ~ to);
				break;
			case State.rcptTo:
				enforce(code == 250, "Unexpected MAIL FROM response");
				state = State.data;
				sendLine("DATA");
				break;
			case State.data:
				enforce(code == 354, "Unexpected DATA response");
				state = State.sendingData;
				foreach (dataLine; data)
				{
					if (dataLine.startsWith("."))
						dataLine = "." ~ dataLine;
					sendLine(dataLine);
				}
				sendLine(".");
				break;
			case State.sendingData:
				enforce(code == 250, "Unexpected data response");
				state = State.quit;
				sendLine("QUIT");
				break;
			case State.quit:
				enforce(code == 221, "Unexpected QUIT response");
				conn.disconnect("All done!");
				break;
			default:
				enforce(false, "Unexpected line in state " ~ text(state));
		}
	}
}
