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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.signals;
version(Posix):

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

// https://github.com/D-Programming-Language/druntime/pull/1140
version(FreeBSD) private
{
	enum SIG_BLOCK   = 1;
	enum SIG_UNBLOCK = 2;
	enum SIG_SETMASK = 3;
}

void addSignalHandler(int signum, SignalHandler fn)
{
	handlers[signum].add(fn, {
		alias sigfn_t = typeof(signal(0, null));
		auto old = signal(signum, cast(sigfn_t)&sighandle);
		assert(old == SIG_DFL || old == SIG_IGN, "A signal handler was already set");
	});
}

void removeSignalHandler(int signum, SignalHandler fn)
{
	handlers[signum].remove(fn, {
		signal(signum, SIG_DFL);
	});
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
				result = m != 0;
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

synchronized class HandlerSet
{
	alias T = SignalHandler;
	private T[] handlers;

	void add(T fn, scope void delegate() register)
	{
		if (handlers.length == 0)
			register();
		handlers ~= cast(shared)fn;
	}
	void remove(T fn, scope void delegate() deregister)
	{
		foreach (i, lfn; handlers)
			if (lfn is fn)
			{
				handlers = handlers[0..i] ~ handlers[i+1..$];
				if (handlers.length == 0)
					deregister();
				return;
			}
		assert(0);
	}
	const(T)[] get() pure nothrow @nogc { return cast(const(T[]))handlers; }
}

shared HandlerSet[SIGMAX] handlers;

shared static this() { foreach (ref h; handlers) h = new HandlerSet; }

extern(C) void sighandle(int signum) nothrow @system
{
	if (signum >= 0 && signum < handlers.length)
		foreach (fn; handlers[signum].get())
			fn();
}
