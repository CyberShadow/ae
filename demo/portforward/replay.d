/**
 * Some common stuff for replaying PortForward replay logs.
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

module ae.demo.portforward.replay;

import std.stdio;
import std.conv;
import std.string;
import std.datetime;
import std.exception;

import ae.utils.text;

class Replayer
{
private:
	File f;
	string line;

	/// Consume and return next space-delimited word from line.
	string getWord()
	{
		int p = line.indexOf(' ');
		string word;
		if (p<0)
			word = line,
			line = null;
		else
			word = line[0..p],
			line = line[p+1..$];
		return word;
	}

	/// Consume and return the rest of the line.
	string getData()
	{
		string data = line;
		line = null;
		return data;
	}

public:
	this(string fn)
	{
		f.open(fn, "rb");

		nextLine();
	}

protected:
	void nextLine()
	{
		line = f.readln().chomp();
		if (line=="" && f.eof())
			return;

		auto recordTime = SysTime(to!long(getWord()));
		string commandStr = getWord();
		enforce(commandStr.length==1, "Invalid command");
		char command = commandStr[0];
		bool proceed;
		switch (command)
		{
		case 'S':
			proceed = handleStart(recordTime);
			break;
		case 'L':
			proceed = handleListen(recordTime, to!ushort(getWord()));
			break;
		case 'A':
			proceed = handleAccept(recordTime, to!uint(getWord()), to!ushort(getWord()));
			break;
		case 'C':
		{
			uint index = to!uint(getWord());
			string addr = getWord();
			int p = addr.lastIndexOf(':');
			proceed = handleConnect(recordTime, index, addr[0..p], to!ushort(addr[p+1..$]));
			break;
		}
		case '<':
			proceed = handleIncomingData(recordTime, to!uint(getWord()), stringUnescape(getData()));
			break;
		case '>':
			proceed = handleOutgoingData(recordTime, to!uint(getWord()), stringUnescape(getData()));
			break;
		case '[':
			proceed = handleIncomingDisconnect(recordTime, to!uint(getWord()), getData());
			break;
		case ']':
			proceed = handleOutgoingDisconnect(recordTime, to!uint(getWord()), getData());
			break;
		default:
			throw new Exception("Unknown command: " ~ command);
		}

		enforce(line.length==0, "Unexpected data at the end of line: " ~ line);

		if (proceed)
			nextLine();
	}

	bool handleStart             (SysTime time)                                       { return true; }
	bool handleListen            (SysTime time, ushort port)                          { return true; }
	bool handleAccept            (SysTime time, uint index, ushort port)              { return true; }
	bool handleConnect           (SysTime time, uint index, string host, ushort port) { return true; }
	bool handleIncomingData      (SysTime time, uint index, void[] data)              { return true; }
	bool handleOutgoingData      (SysTime time, uint index, void[] data)              { return true; }
	bool handleIncomingDisconnect(SysTime time, uint index, string reason)            { return true; }
	bool handleOutgoingDisconnect(SysTime time, uint index, string reason)            { return true; }
}

ubyte[] stringUnescape(string s)
{
	ubyte[] r;
	for (int i=0; i<s.length; i++)
		if (s[i]=='\\')
			r ~= fromHex!ubyte(s[i+1..i+3]),
			i+=2;
		else
			r ~= s[i];
	return r;
}
