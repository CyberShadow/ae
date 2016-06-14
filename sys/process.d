/**
 * ae.sys.process
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

module ae.sys.process;

version(Posix):

import ae.net.sync;
import ae.sys.signals;

import std.process;

void asyncWait(Pid pid, void delegate(int status) dg)
{
	auto anchor = new ThreadAnchor;

	void handler() nothrow @nogc
	{
		anchor.runAsync(
			{
				auto result = tryWait(pid);
				if (result.terminated)
				{
					removeSignalHandler(SIGCHLD, &handler);
					dg(result.status);
				}
			});
	}

	addSignalHandler(SIGCHLD, &handler);
}

version(unittest) import ae.sys.timing, ae.net.asockets;

unittest
{
	string order;

	auto pid = spawnProcess(["sleep", "1"]);
	asyncWait(pid, (int status) { assert(status == 0); order ~= "b"; });
	setTimeout({ order ~= "a"; },  500.msecs);
	setTimeout({ order ~= "c"; }, 1500.msecs);
	socketManager.loop();

	assert(order == "abc");
}
