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

/// TCP port forwarder.
module ae.demo.portforward.portforward;

import ae.net.asockets;
import ae.utils.log;
import ae.utils.text;

import std.stdio;
import std.string;
import std.conv;
import std.datetime;
import std.getopt;
import std.exception;

Logger log, recordLog;
bool logData, record;

class Connection
{
	ClientSocket outer, inner;
	static int counter;
	int index;

	this(ClientSocket outer, string host, ushort port)
	{
		index = counter++;
		this.outer = outer;
		inner = new ClientSocket;
		inner.handleConnect = &onInnerConnect;
		inner.handleReadData = &onInnerData;
		inner.handleDisconnect = &onInnerDisconnect;
		inner.connect(host, port);
	}

	void onInnerConnect(ClientSocket sender)
	{
		log("Connected to " ~ inner.remoteAddress());
		if (record) recordLog(format("%d C %d %s", Clock.currStdTime(), index, inner.remoteAddress()));
		outer.handleReadData = &onOuterData;
		outer.handleDisconnect = &onOuterDisconnect;
	}

	void onOuterData(ClientSocket sender, Data data)
	{
		if (logData) log(format("Outer connection from %s sent %d bytes:\n%s", outer.remoteAddress(), data.length, hexDump(data.contents)));
		if (record) recordLog(format("%d < %d %s", Clock.currStdTime(), index, hexEscape(data.contents)));
		inner.send(data);
	}

	void onOuterDisconnect(ClientSocket sender, string reason, DisconnectType type)
	{
		log("Outer connection from " ~ outer.remoteAddress() ~ " disconnected: " ~ reason);
		if (record) recordLog(format("%d [ %d %s", Clock.currStdTime(), index, reason));
		if (type != DisconnectType.Requested)
			inner.disconnect();
	}

	void onInnerData(ClientSocket sender, Data data)
	{
		if (logData) log(format("Inner connection to %s sent %d bytes:\n%s", inner.remoteAddress(), data.length, hexDump(data.contents)));
		if (record) recordLog(format("%d > %d %s", Clock.currStdTime(), index, hexEscape(data.contents)));
		outer.send(data);
	}

	void onInnerDisconnect(ClientSocket sender, string reason, DisconnectType type)
	{
		log("Inner connection to " ~ inner.remoteAddress() ~ " disconnected: " ~ reason);
		if (record) recordLog(format("%d ] %d %s", Clock.currStdTime(), index, reason));
		if (type != DisconnectType.Requested)
			outer.disconnect();
	}
}

class PortForwarder
{
	ushort localPort;
	string remoteHost;
	ushort remotePort;

	this(string localHost, ushort localPort, string remoteHost, ushort remotePort)
	{
		this.localPort = localPort;
		this.remoteHost = remoteHost;
		this.remotePort = remotePort;

		auto listener = new ServerSocket();
		listener.handleAccept = &onAccept;
		listener.listen(localPort, localHost);
		log(format("Created forwarder: %s:%d -> %s:%d", localHost ? localHost : "*", localPort, remoteHost, remotePort));
		if (record) recordLog(format("%d L %d", Clock.currStdTime(), localPort));
	}

	void onAccept(ClientSocket incoming)
	{
		log(format("Accepted connection from %s on port %d, forwarding to %s:%d", incoming.remoteAddress(), localPort, remoteHost, remotePort));
		if (record) recordLog(format("%d A %d %d", Clock.currStdTime(), Connection.counter, localPort));
		new Connection(incoming, remoteHost, remotePort);
	}
}

void main(string[] args)
{
	string listenOn = null;
	bool quiet = false;
	getopt(args,
		std.getopt.config.bundling,
		"l|listen", &listenOn,
		"v|verbose", &logData,
		"r|record", &record,
		"q|quiet", &quiet);

	if (args.length < 2)
	{
		stderr.writefln("Usage: %s [OPTION]... <destination> <sourceport>[:<targetport>] [...]", args[0]);
		stderr.writeln("Supported options:");
		stderr.writeln(" -q  --quiet           Don't log to screen");
		stderr.writeln(" -l  --listen=ADDRESS  Listen on specified interface (all interfaces by default)");
		stderr.writeln(" -v  --verbose         Log sent/received data as well");
		stderr.writeln(" -r  --record          Log connections to a machine-readable format");
		return;
	}

	log = quiet ? new FileLogger("PortForward") : new FileAndConsoleLogger("PortForward");
	if (record)
	{
		recordLog = new RawFileLogger("PortForwardRecord", true);
		recordLog(format("%d S", Clock.currStdTime()));
	}

	string destination = args[1];
	foreach (portPair; args[2..$])
	{
		auto segments = portPair.split(":");
		enforce(segments.length<=2, "Bad port syntax");
		new PortForwarder(listenOn, to!ushort(segments[0]), destination, to!ushort(segments.length==2 ? segments[1] : segments[0]));
	}
	socketManager.loop();
}

string hexEscape(const(void)[] data)
{
	auto bytes = cast(const(ubyte)[])data;
	string s;
	foreach (b; bytes)
		if (b<0x20 || b>0x7E || b=='\\')
			s ~= `\` ~ hexdigits[b>>4] ~ hexdigits[b&15];
		else
			s ~= cast(char)b;
	return s;
}
