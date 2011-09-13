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

/// Some common stuff for replaying PortForward replay logs.
module ae.demo.portforward.replay;

//import Team15.Utils;

import std.stdio;
import std.conv;
import std.string;
import std.datetime;
import std.exception;

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
			r ~= parse!ubyte(s[i+1..i+3], 16),
			i+=2;
		else
			r ~= s[i];
	return r;
}
