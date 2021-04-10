/**
 * Application shutdown control (with SIGTERM handling).
 * Different from atexit in that it controls initiation
 * of graceful shutdown, as opposed to cleanup actions
 * that are done as part of the shutdown process.
 *
 * Note: thread safety of this module is questionable.
 * Use ae.net.shutdown for networked applications.
 * TODO: transition to thread-safe centralized event loop.
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

module ae.sys.shutdown;

/// Register a handler to be called when a shutdown is requested.
/// Warning: the delegate may be called in an arbitrary thread.
void addShutdownHandler(void delegate(scope const(char)[] reason) fn)
{
	handlers.add(fn);
}

deprecated void addShutdownHandler(void delegate() fn)
{
	addShutdownHandler((scope const(char)[] reason) { fn(); });
}

/// Calls all registered handlers.
void shutdown(scope const(char)[] reason)
{
	foreach (fn; handlers.get())
		fn(reason);
}

deprecated void shutdown()
{
	shutdown(null);
}

private:

import core.thread;

void syncShutdown(scope const(char)[] reason) nothrow @system
{
	try
	{
		thread_suspendAll();
		scope(exit) thread_resumeAll();
		shutdown(reason);
	}
	catch (Throwable e)
	{
		import core.stdc.stdio;
		static if (__VERSION__ < 2068)
		{
			string s = e.msg;
			fprintf(stderr, "Unhandled error while shutting down:\r\n%.*s", s.length, s.ptr);
		}
		else
		{
			fprintf(stderr, "Unhandled error while shutting down:\r\n");
			_d_print_throwable(e);
		}
	}
}

// https://issues.dlang.org/show_bug.cgi?id=7016
version(Posix)
	import ae.sys.signals;
else
version(Windows)
	import core.sys.windows.windows;

extern (C) void _d_print_throwable(Throwable t) nothrow;

void register()
{
	version(Posix)
	{
		addSignalHandler(SIGTERM, { syncShutdown("SIGTERM"); });
		addSignalHandler(SIGINT , { syncShutdown("SIGINT" ); });
	}
	else
	version(Windows)
	{
		static shared bool closing = false;

		static void win32write(string msg) nothrow
		{
			DWORD written;
			WriteConsoleA(GetStdHandle(STD_ERROR_HANDLE), msg.ptr, cast(uint)msg.length, &written, null);
		}

		extern(Windows)
		static BOOL handlerRoutine(DWORD dwCtrlType) nothrow
		{
			if (!closing)
			{
				closing = true;
				win32write("Shutdown event received, shutting down.\r\n");

				string reason;
				switch (dwCtrlType)
				{
					case CTRL_C_EVENT       : reason = "CTRL_C_EVENT"       ; break;
					case CTRL_BREAK_EVENT   : reason = "CTRL_BREAK_EVENT"   ; break;
					case CTRL_CLOSE_EVENT   : reason = "CTRL_CLOSE_EVENT"   ; break;
					case CTRL_LOGOFF_EVENT  : reason = "CTRL_LOGOFF_EVENT"  ; break;
					case CTRL_SHUTDOWN_EVENT: reason = "CTRL_SHUTDOWN_EVENT"; break;
					default: reason = "Unknown dwCtrlType"; break;
				}

				try
				{
					thread_attachThis();
					syncShutdown(reason);
					thread_detachThis();

					return TRUE;
				}
				catch (Throwable e)
				{
					win32write("Unhandled error while shutting down:\r\n");
					static if (__VERSION__ < 2068)
						win32write(e.msg);
					else
						_d_print_throwable(e);
				}
			}
			return FALSE;
		}

		// https://issues.dlang.org/show_bug.cgi?id=12710
		SetConsoleCtrlHandler(cast(PHANDLER_ROUTINE)&handlerRoutine, TRUE);
	}
}

synchronized class HandlerSet
{
	alias T = void delegate(scope const(char)[] reason);
	private T[] handlers;

	void add(T fn)
	{
		if (handlers.length == 0)
			register();
		handlers ~= cast(shared)fn;
	}
	const(T)[] get() { return cast(const(T[]))handlers; }
}

shared HandlerSet handlers;
shared static this() { handlers = new HandlerSet; }
