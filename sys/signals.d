/**
 * POSIX signal handlers.
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

module ae.sys.signals;

import std.exception;

public import core.sys.posix.signal;

alias void delegate() nothrow @system SignalHandler;

// https://github.com/D-Programming-Language/druntime/pull/759
version(OSX) private
{
	enum SIG_BLOCK   = 1;
	enum SIG_UNBLOCK = 2;
	enum SIG_SETMASK = 3;
}

void addSignalHandler(int signum, SignalHandler fn)
{
	if (handlers[signum].length == 0)
	{
		auto old = signal(signum, &sighandle);
		assert(old == SIG_DFL, "A signal handler was already set");
	}
	handlers[signum] ~= fn;
}

void removeSignalHandler(int signum, SignalHandler fn)
{
	foreach (i, lfn; handlers[signum])
		if (lfn is fn)
		{
			handlers[signum] = handlers[signum][0..i] ~ handlers[signum][i+1..$];
			if (handlers[signum].length == 0)
				signal(signum, SIG_DFL);
			return;
		}
	assert(0);
}

// ***************************************************************************

/// If the signal signum is raised during execution of code,
/// ignore it. Returns true if the signal was raised.
bool collectSignal(int signum, void delegate() code)
{
	sigset_t mask;
	sigemptyset(&mask);
	sigaddset(&mask, signum);
	errnoEnforce(pthread_sigmask(SIG_BLOCK, &mask, null) != -1);

	bool result;
	{
		scope(exit)
			errnoEnforce(pthread_sigmask(SIG_UNBLOCK, &mask, null) != -1);

		scope(exit)
		{
			static if (is(typeof(&sigpending)))
			{
				errnoEnforce(sigpending(&mask) == 0);
				auto m = sigismember(&mask, signum);
				errnoEnforce(m >= 0);
				result = m == 0;
				if (result)
				{
					int s;
					errnoEnforce(sigwait(&mask, &s) == 0);
					assert(s == signum);
				}
			}
			else
			{
				timespec zerotime;
				result = sigtimedwait(&mask, null, &zerotime) == 0;
			}
		}

		code();
	}

	return result;
}

private:

enum SIGMAX = 100;
shared SignalHandler[][SIGMAX] handlers;

extern(C) void sighandle(int signum) nothrow @system
{
	if (signum >= 0 && signum < handlers.length)
		foreach (fn; handlers[signum])
			fn();
}
