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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.process;

version (Posix)
{
	import core.sys.posix.unistd : getlogin;
	import std.process : environment;
	import std.string : fromStringz;
}
version (Windows)
{
	import core.sys.windows.lmcons : UNLEN;
	import core.sys.windows.winbase : GetUserNameW;
	import core.sys.windows.windef : DWORD;
	import core.sys.windows.winnt : WCHAR;
	import ae.sys.windows.exception : wenforce;
	import ae.sys.windows.text : fromWString;
}

/// Get the name of the user that the current process is running under.
// Note: Windows does not have numeric user IDs, which is why this
// cross-platform function always returns a string.
string getCurrentUser()
{
	version (Posix)
		return environment.get("LOGNAME", cast(string)getlogin().fromStringz);
	version (Windows)
	{
		WCHAR[UNLEN + 1] buf;
		DWORD len = buf.length;
		GetUserNameW(buf.ptr, &len).wenforce("GetUserNameW");
		return buf[].fromWString();
	}
}

version(Posix):

import ae.net.sync;
import ae.sys.signals;

import std.process;

/// Asynchronously wait for a process to terminate.
void asyncWait(Pid pid, void delegate(int status) dg)
{
	auto anchor = new ThreadAnchor;

	void handler() nothrow @nogc
	{
		anchor.runAsync(
			{
				// Linux may coalesce multiple SIGCHLD into one, so
				// we need to explicitly check if our process exited.
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

version(ae_unittest) import ae.sys.timing, ae.net.asockets;

version(ae_unittest) unittest
{
	string order;

	auto pid = spawnProcess(["sleep", "1"]);
	asyncWait(pid, (int status) { assert(status == 0); order ~= "b"; });
	setTimeout({ order ~= "a"; },  500.msecs);
	setTimeout({ order ~= "c"; }, 1500.msecs);
	socketManager.loop();

	assert(order == "abc");
}
