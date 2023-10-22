/**
 * select-based event loop.
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

module ae.sys.event.select;

import ae.net.sockets : GenericSocket;

version(Windows)
{
	import core.sys.windows.windows : Sleep;
	private enum USE_SLEEP = true; // avoid convoluted mix of static and runtime conditions
}
else
	private enum USE_SLEEP = false;

/// `select`-based event loop implementation.
struct EventLoop
{
private:
	enum FD_SETSIZE = 1024;

	/// List of all sockets to poll.
	GenericSocket[] sockets;

	/// Debug AA to check for dangling socket references.
	debug GenericSocket[socket_t] socketHandles;

	void delegate()[] nextTickHandlers, idleHandlers;

public:
	MonoTime now;

	/// Register a socket with the manager.
	void register(GenericSocket conn)
	{
		debug (ASOCKETS) stderr.writefln("Registering %s (%d total)", conn, sockets.length + 1);
		assert(!conn.socket.blocking, "Trying to register a blocking socket");
		sockets ~= conn;

		debug
		{
			auto handle = conn.socket.handle;
			assert(handle != socket_t.init, "Can't register a closed socket");
			assert(handle !in socketHandles, "This socket handle is already registered");
			socketHandles[handle] = conn;
		}
	}

	/// Unregister a socket with the manager.
	void unregister(GenericSocket conn)
	{
		debug (ASOCKETS) stderr.writefln("Unregistering %s (%d total)", conn, sockets.length - 1);

		debug
		{
			auto handle = conn.socket.handle;
			assert(handle != socket_t.init, "Can't unregister a closed socket");
			auto pconn = handle in socketHandles;
			assert(pconn, "This socket handle is not registered");
			assert(*pconn is conn, "This socket handle is registered but belongs to another GenericSocket");
			socketHandles.remove(handle);
		}

		foreach (size_t i, GenericSocket j; sockets)
			if (j is conn)
			{
				sockets = sockets[0 .. i] ~ sockets[i + 1 .. sockets.length];
				return;
			}
		assert(false, "Socket not registered");
	}

	/// Returns the number of registered sockets.
	size_t size()
	{
		return sockets.length;
	}

	/// Loop continuously until no sockets are left.
	void loop()
	{
		debug (ASOCKETS) stderr.writeln("Starting event loop.");

		SocketSet readset, writeset;
		size_t sockcount;
		uint setSize = FD_SETSIZE; // Can't trust SocketSet.max due to Issue 14012
		readset  = new SocketSet(setSize);
		writeset = new SocketSet(setSize);
		while (true)
		{
			if (nextTickHandlers.length)
			{
				auto thisTickHandlers = nextTickHandlers;
				nextTickHandlers = null;

				foreach (handler; thisTickHandlers)
					handler();

				continue;
			}

			uint minSize = 0;
			version(Windows)
				minSize = cast(uint)sockets.length;
			else
			{
				foreach (s; sockets)
					if (s.socket && s.socket.handle != socket_t.init && s.socket.handle > minSize)
						minSize = s.socket.handle;
			}
			minSize++;

			if (setSize < minSize)
			{
				debug (ASOCKETS) stderr.writefln("Resizing SocketSets: %d => %d", setSize, minSize*2);
				setSize = minSize * 2;
				readset  = new SocketSet(setSize);
				writeset = new SocketSet(setSize);
			}
			else
			{
				readset.reset();
				writeset.reset();
			}

			sockcount = 0;
			bool haveActive;
			debug (ASOCKETS) stderr.writeln("Populating sets");
			foreach (GenericSocket conn; sockets)
			{
				if (!conn.socket)
					continue;
				sockcount++;

				debug (ASOCKETS) stderr.writef("\t%s:", conn);
				if (conn.notifyRead)
				{
					readset.add(conn.socket);
					if (!conn.daemonRead)
						haveActive = true;
					debug (ASOCKETS) stderr.write(" READ", conn.daemonRead ? "[daemon]" : "");
				}
				if (conn.notifyWrite)
				{
					writeset.add(conn.socket);
					if (!conn.daemonWrite)
						haveActive = true;
					debug (ASOCKETS) stderr.write(" WRITE", conn.daemonWrite ? "[daemon]" : "");
				}
				debug (ASOCKETS) stderr.writeln();
			}
			debug (ASOCKETS)
			{
				stderr.writefln("Sets populated as follows:");
				printSets(readset, writeset);
			}

			debug (ASOCKETS) stderr.writefln("Waiting (%sactive with %d sockets, %s timer events, %d idle handlers)...",
				haveActive ? "" : "not ",
				sockcount,
				mainTimer.isWaiting() ? "with" : "no",
				idleHandlers.length,
			);
			if (!haveActive && !mainTimer.isWaiting() && !nextTickHandlers.length)
			{
				debug (ASOCKETS) stderr.writeln("No more sockets or timer events, exiting loop.");
				break;
			}

			debug (ASOCKETS) stderr.flush();

			int events;
			if (idleHandlers.length)
			{
				if (sockcount==0)
					events = 0;
				else
					events = Socket.select(readset, writeset, null, 0.seconds);
			}
			else
			if (USE_SLEEP && sockcount==0)
			{
				version (Windows)
				{
					now = MonoTime.currTime();
					auto duration = mainTimer.getRemainingTime(now).total!"msecs"();
					debug (ASOCKETS) writeln("Wait duration: ", duration, " msecs");
					if (duration <= 0)
						duration = 1; // Avoid busywait
					else
					if (duration > int.max)
						duration = int.max;
					Sleep(cast(int)duration);
					events = 0;
				}
				else
					assert(0);
			}
			else
			if (mainTimer.isWaiting())
			{
				// Refresh time before sleeping, to ensure that a
				// slow event handler does not skew everything else
				now = MonoTime.currTime();

				events = Socket.select(readset, writeset, null, mainTimer.getRemainingTime(now));
			}
			else
				events = Socket.select(readset, writeset, null);

			debug (ASOCKETS) stderr.writefln("%d events fired.", events);

			// Update time after sleeping
			now = MonoTime.currTime();

			if (events > 0)
			{
				// Handle just one event at a time, as the first
				// handler might invalidate select()'s results.
				handleEvent(readset, writeset);
			}
			else
			if (idleHandlers.length)
			{
				import ae.utils.array : shift;
				auto handler = idleHandlers.shift();

				// Rotate the idle handler queue before running it,
				// in case the handler unregisters itself.
				idleHandlers ~= handler;

				handler();
			}

			// Timers may invalidate our select results, so fire them after processing the latter
			mainTimer.prod(now);

			eventCounter++;
		}
	}

	debug (ASOCKETS)
	private void printSets(SocketSet readset, SocketSet writeset)
	{
		foreach (GenericSocket conn; sockets)
		{
			if (!conn.socket)
				stderr.writefln("\t\t%s is unset", conn);
			else
			{
				if (readset.isSet(conn.socket))
					stderr.writefln("\t\t%s is readable", conn);
				if (writeset.isSet(conn.socket))
					stderr.writefln("\t\t%s is writable", conn);
			}
		}
	}

	private void handleEvent(SocketSet readset, SocketSet writeset)
	{
		debug (ASOCKETS)
		{
			stderr.writefln("\tSelect results:");
			printSets(readset, writeset);
		}

		foreach (GenericSocket conn; sockets)
		{
			if (!conn.socket)
				continue;

			if (readset.isSet(conn.socket))
			{
				debug (ASOCKETS) stderr.writefln("\t%s - calling onReadable", conn);
				return conn.onReadable();
			}
			else
			if (writeset.isSet(conn.socket))
			{
				debug (ASOCKETS) stderr.writefln("\t%s - calling onWritable", conn);
				return conn.onWritable();
			}
		}

		assert(false, "select() reported events available, but no registered sockets are set");
	}
}

// Use UFCS to allow removeIdleHandler to have a predicate with context
/// Register a function to be called when the event loop is idle,
/// and would otherwise sleep.
void addIdleHandler(ref EventLoop eventLoop, void delegate() handler)
{
	foreach (i, idleHandler; eventLoop.idleHandlers)
		assert(handler !is idleHandler);

	eventLoop.idleHandlers ~= handler;
}

/// Unregister a function previously registered with `addIdleHandler`.
void removeIdleHandler(alias pred=(a, b) => a is b, Args...)(ref EventLoop eventLoop, Args args)
{
	foreach (i, idleHandler; eventLoop.idleHandlers)
		if (pred(idleHandler, args))
		{
			import std.algorithm : remove;
			eventLoop.idleHandlers = eventLoop.idleHandlers.remove(i);
			return;
		}
	assert(false, "No such idle handler");
}

/// Mixed in `GenericSocket`.
mixin template SocketMixin()
{
	// Flags that determine socket wake-up events.

	/// Interested in read notifications (onReadable)?
	bool notifyRead;
	/// Interested in write notifications (onWritable)?
	bool notifyWrite;
}
