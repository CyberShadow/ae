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

/// Handler callback type.
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

/// Register a handler for a POSIX signal.
void addSignalHandler(int signum, SignalHandler fn)
{
	handlers[signum].add(fn);
}

/// Unregister a previously registered signal handler.
/// When the last handler for `signum` is removed, the disposition
/// that was in effect before the first `addSignalHandler` is restored.
void removeSignalHandler(int signum, SignalHandler fn)
{
	handlers[signum].remove(fn);
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
	private immutable int signum;
	private T[] handlers;
	/// The disposition which was in effect before `sighandle` was installed.
	/// Valid while `handlers` is non-empty.
	private sigaction_t original;
	/// Set during runtime shutdown, after which the set may no longer change.
	private bool closed;

	this(int signum) { this.signum = signum; }

	void add(T fn)
	{
		assert(!closed, "Signal handler registered after runtime shutdown");
		if (handlers.length == 0)
			install();
		handlers ~= cast(shared)fn;
	}
	void remove(T fn)
	{
		assert(!closed, "Signal handler unregistered after runtime shutdown");
		foreach (i, lfn; handlers)
			if (lfn is fn)
			{
				handlers = handlers[0..i] ~ handlers[i+1..$];
				if (handlers.length == 0)
					uninstall();
				return;
			}
		assert(false, "Handler not found");
	}
	/// Restore the original disposition if `sighandle` is installed.
	/// Called during runtime shutdown, before the GC releases the
	/// storage referenced by `handlers` and the delegate contexts.
	void close()
	{
		if (handlers.length)
			uninstall();
		closed = true;
	}
	const(T)[] get() pure nothrow @nogc { return cast(const(T[]))handlers; }

	private void install()
	{
		sigaction_t sa;
		sa.sa_handler = &sighandle;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = SA_RESTART; // Same semantics as BSD / glibc signal()
		sigaction_t old;
		errnoEnforce(sigaction(signum, &sa, &old) == 0, "sigaction");
		assert(old.sa_handler == SIG_DFL || old.sa_handler == SIG_IGN, "A signal handler was already set");
		original = cast(shared)old;
	}
	private void uninstall()
	{
		errnoEnforce(sigaction(signum, cast(sigaction_t*)&original, null) == 0, "sigaction");
	}
}

shared HandlerSet[SIGMAX] handlers;

shared static this() { foreach (signum, ref h; handlers) h = new shared HandlerSet(cast(int)signum); }

// druntime runs module destructors before `gc_term`, so this uninstalls
// `sighandle` while the delegates it dereferences are still alive.
shared static ~this() { foreach (h; handlers) h.close(); }

extern(C) void sighandle(int signum) nothrow @system
{
	if (signum >= 0 && signum < handlers.length)
		foreach (fn; handlers[signum].get())
			fn();
}

// ***************************************************************************

debug(ae_unittest)
{
	import core.stdc.stdlib : atexit;

	// The default action of SIGURG is to ignore it, and nothing else in ae uses it.
	enum testSignal = SIGURG;
	__gshared sigaction_t testOriginal;

	bool isOriginalDisposition() nothrow @nogc
	{
		sigaction_t current;
		sigaction(testSignal, null, &current);
		return current.sa_handler == testOriginal.sa_handler
			&& current.sa_flags == testOriginal.sa_flags
			&& sigismember(&current.sa_mask, SIGUSR2) == 1
			&& sigismember(&current.sa_mask, SIGUSR1) == 0;
	}

	// Runs after `rt_term`, i.e. after the GC has been torn down.
	extern(C) void checkDispositionAfterRuntime() nothrow @nogc
	{
		import core.stdc.stdio : fflush, fprintf, stderr;
		import core.sys.posix.unistd : _exit;

		if (!isOriginalDisposition())
		{
			fprintf(stderr, "ae.sys.signals: signal disposition was not restored at runtime shutdown\n");
			fflush(null);
			_exit(1);
		}
	}
}

debug(ae_unittest) unittest
{
	// Start from a known non-default disposition, so that restoring
	// the original is distinguishable from restoring SIG_DFL.
	sigaction_t sa;
	sa.sa_handler = SIG_IGN;
	sigemptyset(&sa.sa_mask);
	sigaddset(&sa.sa_mask, SIGUSR2);
	sa.sa_flags = 0;
	errnoEnforce(sigaction(testSignal, &sa, null) == 0);
	errnoEnforce(sigaction(testSignal, null, &testOriginal) == 0);

	SignalHandler fn = {};

	// Removing the last handler restores the original disposition.
	addSignalHandler(testSignal, fn);
	assert(!isOriginalDisposition());
	removeSignalHandler(testSignal, fn);
	assert(isOriginalDisposition());

	// Runtime shutdown restores the original disposition
	// of signals which still have handlers registered.
	addSignalHandler(testSignal, fn); // Intentionally never removed
	atexit(&checkDispositionAfterRuntime);
}
