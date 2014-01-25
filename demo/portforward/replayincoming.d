/**
 * Read a PortForward replay log and answer to inbound connections with recorded data.
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

module ae.demo.portforward.replayincoming;

import ae.demo.portforward.replay;
import ae.net.asockets;
import ae.sys.timing;
import ae.sys.log;

import std.datetime : SysTime, Duration, Clock;
import std.string : format;
import std.getopt;

Logger log;

class InboundReplayer : Replayer
{
	this(string fn)
	{
		super(fn);
	}

protected:
	override bool handleListen(SysTime time, ushort port)
	{
		listeners[port] = new Listener(port);
		log(format("Listening on port %d", port));
		return true;
	}

	override bool handleAccept(SysTime time, uint index, ushort port)
	{
		listeners[port].s.handleAccept = (ClientSocket s) { onSocketAccept(s, time, index); };
		log(format("Waiting for connection %d on port %d", index, port));
		return false;
	}

	private void onSocketAccept(ClientSocket s, SysTime time, uint index)
	{
		log(format("Accepted connection %d from %s", index, s.remoteAddress()));
		auto c = new Connection;
		c.s = s;
		c.recordStart = time;
		c.playStart = Clock.currTime();
		connections[index] = c;

		nextLine();
	}

	override bool handleOutgoingData(SysTime time, uint index, void[] data)
	{
		log(format("Sending %d bytes of data to connection %d", data.length, index));
		connections[index].at(time, { sendData(index, data); });
		return false;
	}

	private void sendData(uint index, void[] data)
	{
		connections[index].s.send(data);
		nextLine();
	}

	override bool handleOutgoingDisconnect(SysTime time, uint index, string reason)
	{
		connections[index].at(time, { sendDisconnect(index); });
		return false;
	}

	private void sendDisconnect(uint index)
	{
		connections[index].s.disconnect("Record");
		nextLine();
	}

private:
	Listener[ushort] listeners;

	class Listener
	{
		ServerSocket s;

		this(ushort port)
		{
			s = new ServerSocket();
			s.listen(port);
		}
	}

	Connection[uint] connections;

	class Connection
	{
		ClientSocket s;
		SysTime recordStart, playStart;

		void at(SysTime recordTime, void delegate() fn)
		{
			SysTime playTime = playStart + (recordTime - recordStart);
			setTimeout(fn, playTime - Clock.currTime());
		}
	}
}

void main(string[] args)
{
	bool quiet = false;
	getopt(args, std.getopt.config.bundling,
		"q|quiet", &quiet);
	log = quiet ? new FileLogger("PortForwardReplayIncoming") : new FileAndConsoleLogger("PortForwardReplayIncoming");
	new InboundReplayer(args[1]);
	socketManager.loop();
}
