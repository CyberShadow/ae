/**
 * Read a PortForward replay log and output a CSV suitable for creating a graph of the data rate.
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

module ae.demo.portforward.replaystats;

import ae.demo.portforward.replay;

import std.datetime : SysTime;
import std.stdio;

class StatsReplayer : Replayer
{
	this(string fn)
	{
		super(fn);
	}

protected:
	ulong total;

	override bool handleOutgoingData(SysTime time, uint index, void[] data)
	{
		total += data.length;
		writefln("%d,%d", time.stdTime, total);
		return true;
	}
}

void main(string[] args)
{
	new StatsReplayer(args[1]);
}
