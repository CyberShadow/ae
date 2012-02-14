/**
 * TCP port forwarder.
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

module ae.demo.portforward.portforward;

import ae.net.asockets;
import ae.sys.log;
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
