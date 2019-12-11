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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.shutdown;

/// Warning: the delegate may be called in an arbitrary thread.
void addShutdownHandler(void delegate() fn)
{
	handlers.add(fn);
}

/// Calls all registered handlers.
void shutdown()
{
	foreach (fn; handlers.get())
		fn();
}

private:

import core.thread;

void syncShutdown() nothrow @system
{
	try
	{
		thread_suspendAll();
		scope(exit) thread_resumeAll();
		shutdown();
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

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
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
		addSignalHandler(SIGTERM, { syncShutdown(); });
		addSignalHandler(SIGINT , { syncShutdown(); });
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

				try
				{
					thread_attachThis();
					syncShutdown();
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
	alias T = void delegate();
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
