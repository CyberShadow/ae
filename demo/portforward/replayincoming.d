/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Read a PortForward replay log and answer to inbound connections with recorded data.
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
			Duration remainingTime = playTime - Clock.currTime();
			setTimeout(fn, TickDuration.from!"hnsecs"(remainingTime.total!"hnsecs"));
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
