/**
 * Asynchronous socket abstraction.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <ae@cy.md>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.asockets;

import ae.sys.dataset : DataVec;
import ae.sys.timing;
import ae.utils.array : asSlice, asBytes, queuePush, queuePop;
import ae.utils.math;
public import ae.sys.data;

import core.stdc.stdint : int32_t;

import std.exception;
import std.parallelism : totalCPUs;
import std.socket;
import std.string : format;
public import std.socket : Address, AddressInfo, Socket;

version (Windows)
	private import c_socks = core.sys.windows.winsock2;
else version (Posix)
	private import c_socks = core.sys.posix.sys.socket;

debug(ASOCKETS) import std.stdio : stderr;
debug(PRINTDATA) import std.stdio : stderr;
debug(PRINTDATA) import ae.utils.text : hexDump;
debug(ASOCKETS_DEBUG_SHUTDOWN) import ae.utils.exception : captureStackTrace, printCapturedStackTrace, TraceInfo;
private import std.conv : to;


// https://issues.dlang.org/show_bug.cgi?id=7016
static import ae.utils.array;

version(LIBEV)
{
	import deimos.ev;
	pragma(lib, "ev");
}

version(Windows)
{
	import core.sys.windows.windows : Sleep;
	private enum USE_SLEEP = true; // avoid convoluted mix of static and runtime conditions
}
else
	private enum USE_SLEEP = false;

int eventCounter;

version (LIBEV)
{
	// Watchers are a GenericSocket field (as declared in SocketMixin).
	// Use one watcher per read and write event.
	// Start/stop those as higher-level code declares interest in those events.
	// Use the "data" ev_io field to store the parent GenericSocket address.
	// Also use the "data" field as a flag to indicate whether the watcher is active
	// (data is null when the watcher is stopped).

	/// `libev`-based event loop implementation.
	struct SocketManager
	{
	private:
		size_t count;

		void delegate()[] nextTickHandlers;

		extern(C)
		static void ioCallback(ev_loop_t* l, ev_io* w, int revents)
		{
			auto socket = cast(GenericSocket)w.data;
			assert(socket, "libev event fired on stopped watcher");
			debug (ASOCKETS) stderr.writefln("ioCallback(%s, 0x%X)", socket, revents);

			// TODO? Need to get proper SocketManager instance to call updateTimer on
			socketManager.preEvent();

			if (revents & EV_READ)
				socket.onReadable();
			else
			if (revents & EV_WRITE)
				socket.onWritable();
			else
				assert(false, "Unknown event fired from libev");

			socketManager.postEvent(false);
		}

		ev_timer evTimer;
		MonoTime lastNextEvent = MonoTime.max;

		extern(C)
		static void timerCallback(ev_loop_t* l, ev_timer* w, int /*revents*/)
		{
			debug (ASOCKETS) stderr.writefln("Timer callback called.");

			socketManager.preEvent(); // This also updates socketManager.now
			mainTimer.prod(socketManager.now);

			socketManager.postEvent(true);
			debug (ASOCKETS) stderr.writefln("Timer callback exiting.");
		}

		/// Called upon waking up, before calling any users' event handlers.
		void preEvent()
		{
			eventCounter++;
			socketManager.now = MonoTime.currTime();
		}

		/// Called before going back to sleep, after calling any users' event handlers.
		void postEvent(bool wokeDueToTimeout)
		{
			while (nextTickHandlers.length)
			{
				auto thisTickHandlers = nextTickHandlers;
				nextTickHandlers = null;

				foreach (handler; thisTickHandlers)
					runUserEventHandler({
						handler();
					});
			}

			socketManager.updateTimer(wokeDueToTimeout);
		}

		void updateTimer(bool force)
		{
			auto nextEvent = mainTimer.getNextEvent();
			if (force || lastNextEvent != nextEvent)
			{
				debug (ASOCKETS) stderr.writefln("Rescheduling timer. Was at %s, now at %s", lastNextEvent, nextEvent);
				if (nextEvent == MonoTime.max) // Stopping
				{
					if (lastNextEvent != MonoTime.max)
						ev_timer_stop(ev_default_loop(0), &evTimer);
				}
				else
				{
					auto remaining = mainTimer.getRemainingTime(socketManager.now);
					while (remaining <= Duration.zero)
					{
						debug (ASOCKETS) stderr.writefln("remaining=%s, prodding timer.", remaining);
						runUserEventHandler({
							mainTimer.prod(socketManager.now);
						});
						remaining = mainTimer.getRemainingTime(socketManager.now);
					}
					ev_tstamp tstamp = remaining.total!"hnsecs" * 1.0 / convert!("seconds", "hnsecs")(1);
					debug (ASOCKETS) stderr.writefln("remaining=%s, ev_tstamp=%s", remaining, tstamp);
					if (lastNextEvent == MonoTime.max) // Starting
					{
						ev_timer_init(&evTimer, &timerCallback, 0., tstamp);
						ev_timer_start(ev_default_loop(0), &evTimer);
					}
					else // Adjusting
					{
						evTimer.repeat = tstamp;
						ev_timer_again(ev_default_loop(0), &evTimer);
					}
				}
				lastNextEvent = nextEvent;
			}
		}

	public:
		MonoTime now;

		/// Register a socket with the manager.
		void register(GenericSocket socket)
		{
			debug (ASOCKETS) stderr.writefln("Registering %s", socket);
			debug assert(socket.evRead.data is null && socket.evWrite.data is null, "Re-registering a started socket");
			auto fd = socket.conn.handle;
			assert(fd, "Must have fd before socket registration");
			ev_io_init(&socket.evRead , &ioCallback, fd, EV_READ );
			ev_io_init(&socket.evWrite, &ioCallback, fd, EV_WRITE);
			count++;
			debug (ASOCKETS_DEBUG_SHUTDOWN) socket.registrationStackTrace = captureStackTrace();
		}

		/// Unregister a socket with the manager.
		void unregister(GenericSocket socket)
		{
			debug (ASOCKETS) stderr.writefln("Unregistering %s", socket);
			socket.notifyRead  = false;
			socket.notifyWrite = false;
			count--;
		}

		/// Returns the number of registered sockets.
		size_t size()
		{
			return count;
		}

		/// Loop continuously until no sockets are left.
		void loop()
		{
			debug (ASOCKETS_DEBUG_SHUTDOWN) ShutdownDebugger.register();

			auto evLoop = ev_default_loop(0);
			enforce(evLoop, "libev initialization failure");

			updateTimer(true);
			debug (ASOCKETS) stderr.writeln("ev_run");
			ev_run(ev_default_loop(0), 0);
		}
	}

	private mixin template SocketMixin()
	{
		private ev_io evRead, evWrite;

		private final void setWatcherState(ref ev_io ev, bool newValue, int /*event*/)
		{
			if (!conn)
			{
				// Can happen when setting delegates before connecting.
				return;
			}

			if (newValue && !ev.data)
			{
				// Start
				ev.data = cast(void*)this;
				ev_io_start(ev_default_loop(0), &ev);
			}
			else
			if (!newValue && ev.data)
			{
				// Stop
				assert(ev.data is cast(void*)this);
				ev.data = null;
				ev_io_stop(ev_default_loop(0), &ev);
			}
		}

		private final bool getWatcherState(ref ev_io ev) { return !!ev.data; }

		// Flags that determine socket wake-up events.

		/// Interested in read notifications (onReadable)?
		@property final void notifyRead (bool value) { setWatcherState(evRead , value, EV_READ ); }
		@property final bool notifyRead () { return getWatcherState(evRead); } /// ditto
		/// Interested in write notifications (onWritable)?
		@property final void notifyWrite(bool value) { setWatcherState(evWrite, value, EV_WRITE); }
		@property final bool notifyWrite() { return getWatcherState(evWrite); } /// ditto

		debug ~this() @nogc
		{
			// The LIBEV SocketManager holds no references to registered sockets.
			// TODO: Add a doubly-linked list?
			assert(evRead.data is null && evWrite.data is null, "Destroying a registered socket");
		}
	}
}
else // Use select
{
	/// `select`-based event loop implementation.
	struct SocketManager
	{
	private:
		enum FD_SETSIZE = 1024;

		/// List of all sockets to poll.
		GenericSocket[] sockets;

		/// Debug AA to check for dangling socket references.
		debug GenericSocket[socket_t] socketHandles;

		void delegate()[] nextTickHandlers, idleHandlers;

		debug (ASOCKETS_DEBUG_SHUTDOWN) TrackedHandler[] trackedIdleHandlers;

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

			debug (ASOCKETS_DEBUG_SHUTDOWN) conn.registrationStackTrace = captureStackTrace();
		}

		/// Unregister a socket with the manager.
		void unregister(GenericSocket conn)
		{
			debug (ASOCKETS) stderr.writefln("Unregistering %s (%d total)", conn, sockets.length - 1);

			debug
			{
				auto socket = conn.socket;
				assert(socket, "Trying to unregister an uninitialized socket");
				auto handle = socket.handle;
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
			debug (ASOCKETS_DEBUG_SHUTDOWN) ShutdownDebugger.register();

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
					runUserEventHandler({
						handleEvent(readset, writeset);
					});
				}
				else
				if (idleHandlers.length)
				{
					import ae.utils.array : shift;
					auto handler = idleHandlers.shift();
					debug (ASOCKETS_DEBUG_SHUTDOWN) auto trackedHandler = trackedIdleHandlers.shift();

					// Rotate the idle handler queue before running it,
					// in case the handler unregisters itself.
					idleHandlers ~= handler;
					debug (ASOCKETS_DEBUG_SHUTDOWN) trackedIdleHandlers ~= trackedHandler;

					runUserEventHandler({
						handler();
					});
				}

				// Timers may invalidate our select results, so fire them after processing the latter
				runUserEventHandler({
					mainTimer.prod(now);
				});

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

				if (writeset.isSet(conn.socket))
				{
					debug (ASOCKETS) stderr.writefln("\t%s - calling onWritable", conn);
					return conn.onWritable();
				}
				if (readset.isSet(conn.socket))
				{
					debug (ASOCKETS) stderr.writefln("\t%s - calling onReadable", conn);
					return conn.onReadable();
				}
			}

			assert(false, "select() reported events available, but no registered sockets are set");
		}
	}

	// Use UFCS to allow removeIdleHandler to have a predicate with context
	/// Register a function to be called when the event loop is idle,
	/// and would otherwise sleep.
	void addIdleHandler(ref SocketManager socketManager, void delegate() handler)
	{
		foreach (i, idleHandler; socketManager.idleHandlers)
			assert(handler !is idleHandler);

		socketManager.idleHandlers ~= handler;
		debug (ASOCKETS_DEBUG_SHUTDOWN)
			socketManager.trackedIdleHandlers ~= TrackedHandler(handler, captureStackTrace());
	}

	/// Unregister a function previously registered with `addIdleHandler`.
	void removeIdleHandler(alias pred=(a, b) => a is b, Args...)(ref SocketManager socketManager, Args args)
	{
		foreach (i, idleHandler; socketManager.idleHandlers)
			if (pred(idleHandler, args))
			{
				import std.algorithm : remove;
				socketManager.idleHandlers = socketManager.idleHandlers.remove(i);
				debug (ASOCKETS_DEBUG_SHUTDOWN)
					socketManager.trackedIdleHandlers = socketManager.trackedIdleHandlers.remove(i);
				return;
			}
		assert(false, "No such idle handler");
	}

	private mixin template SocketMixin()
	{
		// Flags that determine socket wake-up events.

		/// Interested in read notifications (onReadable)?
		bool notifyRead;
		/// Interested in write notifications (onWritable)?
		bool notifyWrite;
	}
}

/// The default socket manager.
SocketManager socketManager;

/// Schedule a function to run on the next event loop iteration.
/// Can be used to queue logic to run once all current execution frames exit.
/// Similar to e.g. process.nextTick in Node.
void onNextTick(ref SocketManager socketManager, void delegate() dg) pure @safe nothrow
{
	socketManager.nextTickHandlers ~= dg;
}

/// The current monotonic time.
/// Updated by the event loop whenever it is awoken.
@property MonoTime now()
{
	if (socketManager.now == MonoTime.init)
	{
		// Event loop not yet started.
		socketManager.now = MonoTime.currTime();
	}
	return socketManager.now;
}

// ***************************************************************************

debug (ae_unittest) debug (linux) debug = ASOCKETS_SLOW_EVENT_HANDLER;

// Slow event handler watchdog
private debug (ASOCKETS_SLOW_EVENT_HANDLER)
{
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;
	import core.thread : Thread, ThreadID;
	import std.stdio : stderr;

	import core.sys.posix.pthread;
	import core.sys.posix.unistd;
	import core.sys.posix.signal;

	import ae.utils.time.parsedur : parseDuration;

	extern (C)
	{
		int backtrace(void** buffer, int size);
		void backtrace_symbols_fd(const(void*)* buffer, int size, int fd);
	}

	struct SlowEventHandlerWatchdog
	{
	static:
		shared int signal;
		shared Duration timeout;

		extern (C) void stackTraceHandler(int /*sig*/)
		{
			void*[64] buffer;
			int nptrs = backtrace(buffer.ptr, cast(int)buffer.length);
			const(char)[] header = "--- WATCHDOG TIMEOUT: STACK TRACE ---\n";
			const(char)[] footer = "-------------------------------------\n";
			write(STDERR_FILENO, header.ptr, header.length);
			backtrace_symbols_fd(buffer.ptr, nptrs, STDERR_FILENO);
			write(STDERR_FILENO, footer.ptr, footer.length);
		}

		shared static this()
		{
			import std.process : environment;

			// Initialize settings and parse any additional configuration from environment
			signal = environment.get("AE_SLOW_EVENT_HANDLER_SIGNAL", SIGUSR1.to!string).to!int;
			timeout = parseDuration(environment.get("AE_SLOW_EVENT_HANDLER_TIMEOUT", "100ms"));

			// Install signal handler
			{
				sigaction_t sa;
				sa.sa_handler = &stackTraceHandler;
				sigemptyset(&sa.sa_mask);
				sa.sa_flags = 0;
				if (sigaction(signal, &sa, null) == -1)
					throw new ErrnoException("sigaction failed");
			}

			// Initialize mutex for tracking all watchdog threads
			allThreadsMutex = new Mutex();
		}

		final class WatchdogThread : Thread
		{
			Mutex mutex;
			Condition cond;

			ThreadID eventThreadID;
			MonoTime deadline;
			bool shouldStop;

			this(ThreadID eventThreadID)
			{
				this.eventThreadID = eventThreadID;
				this.mutex = new Mutex(this);
				this.cond = new Condition(this.mutex);

				this.isDaemon = true;
				super(&run);
			}

			void run()
			{
				synchronized (this.mutex)
				{
					while (!shouldStop)
					{
						if (deadline is MonoTime.init)
						{
							this.cond.wait();
							continue;
						}

						auto timeLeft = deadline - MonoTime.currTime;
						if (timeLeft > Duration.zero)
						{
							this.cond.wait(timeLeft);
							continue;
						}

						// Deadline reached, time-out
						stderr.writeln("Watchdog: Detected timeout!");

						pthread_kill(eventThreadID, signal);
						deadline = MonoTime.init;
					}
				}
			}

			void stop()
			{
				synchronized (this.mutex)
					shouldStop = true;
				this.cond.notify();
			}
		}

		WatchdogThread thread; // TLS variable in the event loop thread's local storage

		// Global registry of all watchdog threads for cleanup on program exit
		__gshared WatchdogThread[] allThreads;
		__gshared Mutex allThreadsMutex;

		shared static ~this()
		{
			WatchdogThread[] threadsToStop;
			synchronized (allThreadsMutex)
			{
				threadsToStop = allThreads;
				allThreads = null;
			}
			foreach (t; threadsToStop)
			{
				t.stop();
				t.join();
			}
		}

		void arm()
		{
			if (!thread)
			{
				thread = new WatchdogThread(Thread.getThis().id);
				thread.start();
				synchronized (allThreadsMutex)
					allThreads ~= thread;
			}
			synchronized (thread.mutex)
				thread.deadline = MonoTime.currTime() + timeout;
			thread.cond.notify();
		}

		void disarm()
		{
			synchronized (thread.mutex)
				thread.deadline = MonoTime.init;
			thread.cond.notify();
		}
	}
}

void runUserEventHandler(scope void delegate() dg)
{
	debug (ASOCKETS_SLOW_EVENT_HANDLER)
		SlowEventHandlerWatchdog.arm();
	scope (exit)
		debug (ASOCKETS_SLOW_EVENT_HANDLER)
			SlowEventHandlerWatchdog.disarm();
	dg();
}

// ***************************************************************************

// Shutdown debugging: prints objects that are blocking the event loop from exiting
// when the application doesn't shut down cleanly after a shutdown was requested.
private debug (ASOCKETS_DEBUG_SHUTDOWN)
{
	import std.process : environment;
	import ae.utils.time.parsedur : parseDuration;

	struct ShutdownDebugger
	{
	static:
		bool registered = false;
		Duration timeout;
		TimerTask watchdogTask;
		bool shutdownWasRequested;

		void onShutdown(scope const(char)[] /*reason*/)
		{
			import std.stdio : stderr;

			if (shutdownWasRequested)
				return;
			shutdownWasRequested = true;

			stderr.writeln("[ASOCKETS_DEBUG_SHUTDOWN] Shutdown requested. " ~
				"Watchdog will trigger in ", timeout, " if the event loop doesn't exit.");
			stderr.flush();

			watchdogTask = new TimerTask((Timer, TimerTask) { onWatchdogTimeout(); });
			mainTimer.add(watchdogTask, MonoTime.currTime() + timeout);
		}

		void onWatchdogTimeout()
		{
			import std.stdio : stderr;
			import std.range : repeat;
			import std.array : join;

			stderr.writeln("\n[ASOCKETS_DEBUG_SHUTDOWN] Shutdown did not complete in time!");
			stderr.writeln("=".repeat(72).join);
			stderr.writeln("Objects blocking the event loop:");
			stderr.writeln();

			printBlockingSockets();
			printBlockingTimerTasks();
			printBlockingIdleHandlers();
			printBlockingNextTickHandlers();

			stderr.writeln("=".repeat(72).join);
			stderr.flush();
		}

		void printBlockingSockets()
		{
			import std.stdio : stderr;
			size_t count;

			foreach (sock; socketManager.sockets)
			{
				if (sock is null || sock.socket is null)
					continue;
				if (sock.notifyRead && !sock.daemonRead || sock.notifyWrite && !sock.daemonWrite)
				{
					stderr.writefln("SOCKET: %s", sock);
					stderr.writefln("  notifyRead=%s (daemon=%s), notifyWrite=%s (daemon=%s)",
						sock.notifyRead, sock.daemonRead, sock.notifyWrite, sock.daemonWrite);
					if (sock.registrationStackTrace !is null)
					{
						stderr.writeln("  Registered at:");
						printCapturedStackTrace(sock.registrationStackTrace);
					}
					stderr.writeln();
					count++;
				}
			}

			if (count == 0)
				stderr.writeln("SOCKETS: None blocking\n");
			else
				stderr.writefln("SOCKETS: %d blocking\n", count);
		}

		void printBlockingTimerTasks()
		{
			import std.stdio : stderr;

			if (!mainTimer.isWaiting())
			{
				stderr.writeln("TIMER TASKS: None pending\n");
				return;
			}

			auto now = MonoTime.currTime();
			size_t count;

			foreach (task; mainTimer.pendingTasks())
			{
				// Skip our own watchdog task
				if (task is watchdogTask)
					continue;

				count++;
				stderr.writefln("TIMER TASK: %s", cast(void*)task);
				stderr.writefln("  fires at: %s (in %s)", task.when, task.when - now);
				debug(TIMER_TRACK)
				{
					if (task.debugCreationStackTrace !is null)
					{
						stderr.writeln("  Created at:");
						printCapturedStackTrace(task.debugCreationStackTrace);
					}
					if (task.debugAdditionStackTrace !is null)
					{
						stderr.writeln("  Added at:");
						printCapturedStackTrace(task.debugAdditionStackTrace);
					}
				}
				else
				{
					stderr.writeln("  (Enable debug=TIMER_TRACK for stack traces)");
				}
				stderr.writeln();
			}

			if (count == 0)
				stderr.writeln("TIMER TASKS: Only the shutdown watchdog is pending\n");
			else
				stderr.writefln("TIMER TASKS: %d pending\n", count);
		}

		void printBlockingIdleHandlers()
		{
			import std.stdio : stderr;

			version (LIBEV)
			{
				stderr.writeln("IDLE HANDLERS: Not tracked with LIBEV\n");
			}
			else
			{
				auto handlers = socketManager.idleHandlers;
				if (handlers.length == 0)
				{
					stderr.writeln("IDLE HANDLERS: None registered\n");
					return;
				}

				stderr.writefln("IDLE HANDLERS: %d registered", handlers.length);
				foreach (i, ref handler; socketManager.trackedIdleHandlers)
				{
					stderr.writefln("  [%d] %s", i, handler.dg);
					if (handler.stackTrace !is null)
					{
						stderr.writeln("  Registered at:");
						printCapturedStackTrace(handler.stackTrace);
					}
				}
				stderr.writeln();
			}
		}

		void printBlockingNextTickHandlers()
		{
			import std.stdio : stderr;

			auto handlers = socketManager.nextTickHandlers;
			if (handlers.length == 0)
			{
				stderr.writeln("NEXT TICK HANDLERS: None queued\n");
				return;
			}

			// Note: onNextTick is pure @safe nothrow, so we can't capture stack traces there.
			// NextTick handlers are transient anyway (run once per tick).
			stderr.writefln("NEXT TICK HANDLERS: %d queued (stack traces not available)", handlers.length);
			foreach (i, handler; handlers)
			{
				stderr.writefln("  [%d] %s", i, handler);
			}
			stderr.writeln();
		}

		/// Register lazily, only for threads that actually run an event loop.
		void register()
		{
			if (registered)
				return;
			registered = true;

			timeout = parseDuration(environment.get("AE_DEBUG_SHUTDOWN_TIMEOUT", "5 secs"));

			import ae.net.shutdown : addShutdownHandler;
			addShutdownHandler((scope const(char)[] reason) { onShutdown(reason); });
		}
	}

	struct TrackedHandler
	{
		void delegate() dg;
		TraceInfo stackTrace;
	}
}

// ***************************************************************************

/// General methods for an asynchronous socket.
abstract class GenericSocket
{
	/// Declares notifyRead and notifyWrite.
	mixin SocketMixin;

	debug (ASOCKETS_DEBUG_SHUTDOWN) TraceInfo registrationStackTrace;

protected:
	/// The socket this class wraps.
	Socket conn;

// protected:
	void onReadable()
	{
	}

	void onWritable()
	{
	}

	void onError(string /*reason*/)
	{
	}

public:
	/// Retrieve the socket class this class wraps.
	@property final Socket socket()
	{
		return conn;
	}

	/// allow getting the address of connections that are already disconnected
	private Address[2] cachedAddress;

	/*private*/ final @property Address _address(bool local)()
	{
		if (cachedAddress[local] !is null)
			return cachedAddress[local];
		else
		if (conn is null)
			return null;
		else
		{
			Address a;
			if (conn.addressFamily == AddressFamily.UNSPEC)
			{
				// Socket will attempt to construct an UnknownAddress,
				// which will almost certainly not match the real address length.
				static if (local)
					alias getname = c_socks.getsockname;
				else
					alias getname = c_socks.getpeername;

				c_socks.socklen_t nameLen = 0;
				if (getname(conn.handle, null, &nameLen) < 0)
					throw new SocketOSException("Unable to obtain socket address");

				auto buf = new ubyte[nameLen];
				auto sa = cast(c_socks.sockaddr*)buf.ptr;
				if (getname(conn.handle, sa, &nameLen) < 0)
					throw new SocketOSException("Unable to obtain socket address");
				a = new UnknownAddressReference(sa, nameLen);
			}
			else
				a = local ? conn.localAddress() : conn.remoteAddress();
			return cachedAddress[local] = a;
		}
	}

	alias localAddress = _address!true; /// Retrieve this socket's local address.
	alias remoteAddress = _address!false; /// Retrieve this socket's remote address.

	/*private*/ final @property string _addressStr(bool local)() nothrow
	{
		try
		{
			auto a = _address!local;
			if (a is null)
				return "[null address]";
			string host = a.toAddrString();
			import std.string : indexOf;
			if (host.indexOf(':') >= 0)
				host = "[" ~ host ~ "]";
			try
			{
				string port = a.toPortString();
				return host ~ ":" ~ port;
			}
			catch (Exception e)
				return host;
		}
		catch (Exception e)
			return "[error: " ~ e.msg ~ "]";
	}

	alias localAddressStr = _addressStr!true; /// Retrieve this socket's local address, as a string.
	alias remoteAddressStr = _addressStr!false; /// Retrieve this socket's remote address, as a string.

	/// Don't block the process from exiting, even if the socket is ready to receive data.
	/// TODO: Not implemented with libev
	bool daemonRead;

	/// Don't block the process from exiting, even if the socket is ready to send data.
	/// TODO: Not implemented with libev
	bool daemonWrite;

	deprecated alias daemon = daemonRead;

	/// Enable TCP keep-alive on the socket with the given settings.
	final void setKeepAlive(bool enabled=true, int time=10, int interval=5)
	{
		assert(conn, "Attempting to set keep-alive on an uninitialized socket");
		if (enabled)
		{
			try
				conn.setKeepAlive(time, interval);
			catch (SocketException)
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, true);
		}
		else
			conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, false);
	}

	/// Returns a string containing the class name, address, and file descriptor.
	override string toString() const
	{
		import std.string : format, split;
		return "%s {this=%s, fd=%s}".format(this.classinfo.name.split(".")[$-1], cast(void*)this, conn ? conn.handle : -1);
	}
}

// ***************************************************************************

/// Classifies the cause of the disconnect.
/// Can be used to decide e.g. when it makes sense to reconnect.
enum DisconnectType
{
	requested, /// Initiated by the application.
	graceful,  /// The peer gracefully closed the connection.
	error      /// Some abnormal network condition.
}

/// Used to indicate the state of a connection throughout its lifecycle.
enum ConnectionState
{
	/// The initial state, or the state after a disconnect was fully processed.
	disconnected,

	/// Name resolution. Currently done synchronously.
	resolving,

	/// A connection attempt is in progress.
	connecting,

	/// A connection is established.
	connected,

	/// Disconnecting in progress. No data can be sent or received at this point.
	/// We are waiting for queued data to be actually sent before disconnecting.
	disconnecting,
}

/// Returns true if this is a connection state for which disconnecting is valid.
/// Generally, applications should be aware of the life cycle of their sockets,
/// so checking the state of a connection is unnecessary (and a code smell).
/// However, unconditionally disconnecting some connected sockets can be useful
/// when it needs to occur "out-of-bound" (not tied to the application normal life cycle),
/// such as in response to a signal.
bool disconnectable(ConnectionState state) { return state >= ConnectionState.resolving && state <= ConnectionState.connected; }

/// Common interface for connections and adapters.
interface IConnection
{
	/// `send` queues data for sending in one of five queues, indexed
	/// by a numeric priority.
	/// `MAX_PRIORITY` is the highest (least urgent) priority index.
	/// `DEFAULT_PRIORITY` is the default priority
	enum MAX_PRIORITY = 4;
	enum DEFAULT_PRIORITY = 2; /// ditto

	/// This is the default value for the `disconnect` `reason` string parameter.
	static const defaultDisconnectReason = "Software closed the connection";

	/// Get connection state.
	@property ConnectionState state();

	/// Has a connection been established?
	deprecated final @property bool connected() { return state == ConnectionState.connected; }

	/// Are we in the process of disconnecting? (Waiting for data to be flushed)
	deprecated final @property bool disconnecting() { return state == ConnectionState.disconnecting; }

	/// Queue Data for sending.
	void send(scope Data[] data, int priority = DEFAULT_PRIORITY);

	/// ditto
	final void send(Data datum, int priority = DEFAULT_PRIORITY)
	{
		this.send(datum.asSlice, priority);
	}

	/// Terminate the connection.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested);

	/// Callback setter for when a connection has been established
	/// (if applicable).
	alias ConnectHandler = void delegate();
	@property void handleConnect(ConnectHandler value); /// ditto

	/// Callback setter for when new data is read.
	alias ReadDataHandler = void delegate(Data data);
	@property void handleReadData(ReadDataHandler value); /// ditto

	/// Callback setter for when a connection was closed.
	alias DisconnectHandler = void delegate(string reason, DisconnectType type);
	@property void handleDisconnect(DisconnectHandler value); /// ditto

	/// Callback setter for when all queued data has been sent.
	alias BufferFlushedHandler = void delegate();
	@property void handleBufferFlushed(BufferFlushedHandler value); /// ditto
}

// ***************************************************************************

/// Implementation of `IConnection` using a socket.
/// Implements receiving data when readable and sending queued data
/// when writable.
class Connection : GenericSocket, IConnection
{
private:
	ConnectionState _state;
protected:
	final @property ConnectionState state(ConnectionState value) { return _state = value; }

public:
	/// Get connection state.
	override @property ConnectionState state() { return _state; }

protected:
	abstract sizediff_t doSend(scope const(void)[] buffer);
	enum sizediff_t doReceiveEOF = -1;
	abstract sizediff_t doReceive(scope void[] buffer);

	/// The send buffers.
	DataVec[MAX_PRIORITY+1] outQueue;
	/// Whether the first item from this queue (if any) has been partially sent (and thus can't be canceled).
	int partiallySent = -1;

	/// Constructor used by a ServerSocket for new connections
	this(Socket conn)
	{
		this();
		this.conn = conn;
		state = conn is null ? ConnectionState.disconnected : ConnectionState.connected;
		if (conn)
			socketManager.register(this);
		updateFlags();
	}

	final void updateFlags()
	{
		if (state == ConnectionState.connecting)
			notifyWrite = true;
		else
			notifyWrite = writePending;

		notifyRead = state == ConnectionState.connected && readDataHandler;
		debug(ASOCKETS) stderr.writefln("[%s] updateFlags: %s %s", conn ? conn.handle : -1, notifyRead, notifyWrite);
	}

	// We reuse the same buffer across read calls.
	// It is allocated on the first read, and also
	// if the user code decides to keep a reference to it.
	static Data inBuffer;

	/// Called when a socket is readable.
	override void onReadable()
	{
		// TODO: use FIONREAD when Phobos gets ioctl support (issue 6649)
		if (!inBuffer)
			inBuffer = Data(0x10000);
		else
			inBuffer = inBuffer.ensureUnique();
		sizediff_t received;
		inBuffer.enter((scope contents) {
			received = doReceive(contents);
		});

		if (received == doReceiveEOF)
			return disconnect("Connection closed", DisconnectType.graceful);

		if (received == Socket.ERROR)
		{
		//	if (wouldHaveBlocked)
		//	{
		//		debug (ASOCKETS) writefln("\t\t%s: wouldHaveBlocked or recv()", this);
		//		return;
		//	}
		//	else
				onError("recv() error: " ~ lastSocketError);
		}
		else
		{
			debug (PRINTDATA)
			{
				stderr.writefln("== %s <- %s ==", localAddressStr, remoteAddressStr);
				stderr.write(hexDump(inBuffer.unsafeContents[0 .. received]));
				stderr.flush();
			}

			if (state == ConnectionState.disconnecting)
			{
				debug (ASOCKETS) stderr.writefln("\t\t%s: Discarding received data because we are disconnecting", this);
			}
			else
			if (!readDataHandler)
			{
				debug (ASOCKETS) stderr.writefln("\t\t%s: Discarding received data because there is no data handler", this);
			}
			else
			{
				auto data = inBuffer[0 .. received];
				readDataHandler(data);
			}
		}
	}

	/// Called when an error occurs on the socket.
	override void onError(string reason)
	{
		if (state == ConnectionState.disconnecting)
		{
			debug (ASOCKETS) stderr.writefln("Socket error while disconnecting @ %s: %s".format(cast(void*)this, reason));
			return close();
		}

		assert(state == ConnectionState.resolving || state == ConnectionState.connecting || state == ConnectionState.connected);
		disconnect("Socket error: " ~ reason, DisconnectType.error);
	}

	this()
	{
	}

public:
	/// Close a connection. If there is queued data waiting to be sent, wait until it is sent before disconnecting.
	/// The disconnect handler will be called immediately, even when not all data has been flushed yet.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		//scope(success) updateFlags(); // Work around scope(success) breaking debugger stack traces
		assert(state.disconnectable, "Attempting to disconnect on a %s socket".format(state));

		if (writePending)
		{
			if (type==DisconnectType.requested)
			{
				assert(conn, "Attempting to disconnect on an uninitialized socket");
				// queue disconnect after all data is sent
				debug (ASOCKETS) stderr.writefln("[%s] Queueing disconnect: %s", remoteAddressStr, reason);
				state = ConnectionState.disconnecting;
				//setIdleTimeout(30.seconds);
				if (disconnectHandler)
					disconnectHandler(reason, type);
				updateFlags();
				return;
			}
			else
				discardQueues();
		}

		debug (ASOCKETS) stderr.writefln("Disconnecting @ %s: %s", cast(void*)this, reason);

		if ((state == ConnectionState.connecting && conn) || state == ConnectionState.connected)
			close();
		else
		{
			assert(conn is null, "Registered but %s socket".format(state));
			if (state == ConnectionState.resolving)
				state = ConnectionState.disconnected;
		}

		if (disconnectHandler)
			disconnectHandler(reason, type);
		updateFlags();
	}

	private final void close()
	{
		assert(conn, "Attempting to close an unregistered socket");
		socketManager.unregister(this);
		conn.close();
		conn = null;
		outQueue[] = DataVec.init;
		state = ConnectionState.disconnected;
	}

	/// Append data to the send buffer.
	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(state == ConnectionState.connected, "Attempting to send on a %s socket".format(state));
		outQueue[priority] ~= data;
		notifyWrite = true; // Fast updateFlags()

		debug (PRINTDATA)
		{
			stderr.writefln("== %s -> %s ==", localAddressStr, remoteAddressStr);
			foreach (datum; data)
				if (datum.length)
					stderr.write(hexDump(datum.unsafeContents));
				else
					stderr.writeln("(empty Data)");
			stderr.flush();
		}
	}

	/// ditto
	alias send = IConnection.send;

	/// Cancel all queued `Data` packets with the given priority.
	/// Does not cancel any partially-sent `Data`.
	final void clearQueue(int priority)
	{
		if (priority == partiallySent)
		{
			assert(outQueue[priority].length > 0);
			outQueue[priority].length = 1;
		}
		else
			outQueue[priority] = null;
		updateFlags();
	}

	/// Clears all queues, even partially sent content.
	private final void discardQueues()
	{
		foreach (priority; 0..MAX_PRIORITY+1)
			outQueue[priority] = null;
		partiallySent = -1;
		updateFlags();
	}

	/// Returns true if any queues have pending data.
	@property
	final bool writePending()
	{
		foreach (ref queue; outQueue)
			if (queue.length)
				return true;
		return false;
	}

	/// Returns true if there are any queued `Data` which have not yet
	/// begun to be sent.
	final bool queuePresent(int priority = DEFAULT_PRIORITY)
	{
		if (priority == partiallySent)
		{
			assert(outQueue[priority].length > 0);
			return outQueue[priority].length > 1;
		}
		else
			return outQueue[priority].length > 0;
	}

	/// Returns the number of queued `Data` at the given priority.
	final size_t packetsQueued(int priority = DEFAULT_PRIORITY)
	{
		return outQueue[priority].length;
	}

	/// Returns the number of queued bytes at the given priority.
	final size_t bytesQueued(int priority = DEFAULT_PRIORITY)
	{
		size_t bytes;
		foreach (datum; outQueue[priority])
			bytes += datum.length;
		return bytes;
	}

// public:
	private ConnectHandler connectHandler;
	/// Callback for when a connection has been established.
	@property final void handleConnect(ConnectHandler value) { connectHandler = value; updateFlags(); }

	private ReadDataHandler readDataHandler;
	/// Callback for incoming data.
	/// Data will not be received unless this handler is set.
	@property final void handleReadData(ReadDataHandler value) { readDataHandler = value; updateFlags(); }

	private DisconnectHandler disconnectHandler;
	/// Callback for when a connection was closed.
	@property final void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; updateFlags(); }

	private BufferFlushedHandler bufferFlushedHandler;
	/// Callback setter for when all queued data has been sent.
	@property final void handleBufferFlushed(BufferFlushedHandler value) { bufferFlushedHandler = value; updateFlags(); }
}

/// Implements a stream connection.
/// Queued `Data` is allowed to be fragmented.
class StreamConnection : Connection
{
protected:
	this()
	{
		super();
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		//scope(success) updateFlags();
		onWritableImpl();
		updateFlags();
	}

	// Work around scope(success) breaking debugger stack traces
	final private void onWritableImpl()
	{
		debug(ASOCKETS) stderr.writefln("[%s] onWritableImpl (we are %s)", conn ? conn.handle : -1, state);
		if (state == ConnectionState.connecting)
		{
			int32_t error;
			conn.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, error);
			if (error)
				return disconnect(formatSocketError(error), DisconnectType.error);

			state = ConnectionState.connected;

			//debug writefln("[%s] Connected", remoteAddressStr);
			try
				setKeepAlive();
			catch (Exception e)
				return disconnect(e.msg, DisconnectType.error);
			if (connectHandler)
				connectHandler();
			return;
		}
		//debug writefln(remoteAddressStr, ": Writable - handler ", handleBufferFlushed?"OK":"not set", ", outBuffer.length=", outBuffer.length);

		foreach (sendPartial; [true, false])
			foreach (int priority, ref queue; outQueue)
				while (queue.length && (!sendPartial || priority == partiallySent))
				{
					assert(partiallySent == -1 || partiallySent == priority);

					ptrdiff_t sent = 0;
					if (!queue.front.empty)
					{
						queue.front.enter((scope contents) {
							sent = doSend(contents);
						});
						debug (ASOCKETS) stderr.writefln("\t\t%s: sent %d/%d bytes", this, sent, queue.front.length);
					}
					else
					{
						debug (ASOCKETS) stderr.writefln("\t\t%s: empty Data object", this);
					}

					if (sent == Socket.ERROR)
					{
						if (wouldHaveBlocked())
							return;
						else
							return onError("send() error: " ~ lastSocketError);
					}
					else
					if (sent < queue.front.length)
					{
						if (sent > 0)
						{
							queue.front = queue.front[sent..queue.front.length];
							partiallySent = priority;
						}
						return;
					}
					else
					{
						assert(sent == queue.front.length);
						//debug writefln("[%s] Sent data:", remoteAddressStr);
						//debug writefln("%s", hexDump(queue.front.contents[0..sent]));
						queue.front.clear();
						queue.popFront();
						partiallySent = -1;
						if (queue.length == 0)
							queue = null;
					}
				}

		// outQueue is now empty
		if (bufferFlushedHandler)
			bufferFlushedHandler();
		if (state == ConnectionState.disconnecting)
		{
			debug (ASOCKETS) stderr.writefln("Closing @ %s (Delayed disconnect - buffer flushed)", cast(void*)this);
			close();
		}
	}

public:
	this(Socket conn)
	{
		super(conn);
	} ///
}

// ***************************************************************************

/// A POSIX file stream.
/// Allows adding a file (e.g. stdin/stdout) to the socket manager.
/// Does not dup the given file descriptor, so "disconnecting" this connection
/// will close it.
version (Posix)
class FileConnection : StreamConnection
{
	this(int fileno)
	{
		auto conn = new Socket(cast(socket_t)fileno, AddressFamily.UNSPEC);
		conn.blocking = false;
		super(conn);
	} ///

protected:
	import core.sys.posix.unistd : read, write;

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		return write(socket.handle, buffer.ptr, buffer.length);
	}

	override sizediff_t doReceive(scope void[] buffer)
	{
		auto bytesRead = read(socket.handle, buffer.ptr, buffer.length);
		if (bytesRead == 0)
			return doReceiveEOF;
		return bytesRead;
	}
}

/// Separates reading and writing, e.g. for stdin/stdout.
class Duplex : IConnection
{
	///
	IConnection reader, writer;

	this(IConnection reader, IConnection writer)
	{
		this.reader = reader;
		this.writer = writer;
		reader.handleConnect = &onConnect;
		writer.handleConnect = &onConnect;
		reader.handleDisconnect = &onDisconnect;
		writer.handleDisconnect = &onDisconnect;
	} ///

	@property ConnectionState state()
	{
		if (reader.state == ConnectionState.disconnecting || writer.state == ConnectionState.disconnecting)
			return ConnectionState.disconnecting;
		else
			return reader.state < writer.state ? reader.state : writer.state;
	} ///

	/// Queue Data for sending.
	void send(scope Data[] data, int priority)
	{
		writer.send(data, priority);
	}

	alias send = IConnection.send; /// ditto

	/// Terminate the connection.
	/// Note: this isn't quite fleshed out - applications may want to
	/// wait and send some more data even after stdin is closed, but
	/// such an interface can't be fitted into an IConnection
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		if (reader.state > ConnectionState.disconnected && reader.state < ConnectionState.disconnecting)
			reader.disconnect(reason, type);
		if (writer.state > ConnectionState.disconnected && writer.state < ConnectionState.disconnecting)
			writer.disconnect(reason, type);
		debug(ASOCKETS) stderr.writefln("Duplex.disconnect(%(%s%), %s), states are %s / %s", [reason], type, reader.state, writer.state);
	}

	protected void onConnect()
	{
		if (connectHandler && reader.state == ConnectionState.connected && writer.state == ConnectionState.connected)
			connectHandler();
	}

	protected void onDisconnect(string reason, DisconnectType type)
	{
		debug(ASOCKETS) stderr.writefln("Duplex.onDisconnect(%(%s%), %s), states are %s / %s", [reason], type, reader.state, writer.state);
		if (disconnectHandler)
		{
			disconnectHandler(reason, type);
			disconnectHandler = null; // don't call it twice for the other connection
		}
		// It is our responsibility to disconnect the other connection
		// Use DisconnectType.requested to ensure that any written data is flushed
		disconnect("Other side of Duplex connection closed (" ~ reason ~ ")", DisconnectType.requested);
	}

	/// Callback for when a connection has been established.
	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	private ConnectHandler connectHandler;

	/// Callback setter for when new data is read.
	@property void handleReadData(ReadDataHandler value) { reader.handleReadData = value; }

	/// Callback setter for when a connection was closed.
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	private DisconnectHandler disconnectHandler;

	/// Callback setter for when all queued data has been written.
	@property void handleBufferFlushed(BufferFlushedHandler value) { writer.handleBufferFlushed = value; }
}

debug(ae_unittest) unittest { if (false) new Duplex(null, null); }

// ***************************************************************************

/// An asynchronous socket-based connection.
class SocketConnection : StreamConnection
{
protected:
	AddressInfo[] addressQueue;
	bool datagram;

	this(Socket conn, bool datagram = false)
	{
		super(conn);
		this.datagram = datagram;
	}

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		return conn.send(buffer);
	}

	override sizediff_t doReceive(scope void[] buffer)
	{
		auto bytesReceived = conn.receive(buffer);
		if (bytesReceived == 0 && !datagram)
			return doReceiveEOF;
		return bytesReceived;
	}

	final void tryNextAddress()
	{
		assert(state == ConnectionState.connecting);
		auto addressInfo = addressQueue[0];
		addressQueue = addressQueue[1..$];

		try
		{
			conn = new Socket(addressInfo.family, addressInfo.type, addressInfo.protocol);
			conn.blocking = false;

			socketManager.register(this);
			updateFlags();
			debug (ASOCKETS) stderr.writefln("Attempting connection to %s", addressInfo.address.toString());
			conn.connect(addressInfo.address);
		}
		catch (SocketException e)
			return onError("Connect error: " ~ e.msg);
	}

	/// Called when an error occurs on the socket.
	override void onError(string reason)
	{
		if (state == ConnectionState.connecting && addressQueue.length)
		{
			if (conn)
			{
				socketManager.unregister(this);
				conn.close();
				conn = null;
			}

			return tryNextAddress();
		}

		super.onError(reason);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New SocketConnection @ %s", cast(void*)this);
	}

	/// Start establishing a connection.
	final void connect(AddressInfo[] addresses)
	{
		assert(addresses.length, "No addresses specified");

		assert(state == ConnectionState.disconnected, "Attempting to connect on a %s socket".format(state));
		assert(!conn);

		addressQueue = addresses;
		state = ConnectionState.connecting;
		tryNextAddress();
	}
}

/// An asynchronous TCP connection.
class TcpConnection : SocketConnection
{
protected:
	this(Socket conn)
	{
		super(conn, false);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New TcpConnection @ %s", cast(void*)this);
	}

	///
	alias connect = SocketConnection.connect; // raise overload

	/// Start establishing a connection.
	final void connect(string host, ushort port)
	{
		assert(host.length, "Empty host");
		assert(port, "No port specified");

		debug (ASOCKETS) stderr.writefln("Connecting to %s:%s", host, port);
		assert(state == ConnectionState.disconnected, "Attempting to connect on a %s socket".format(state));

		state = ConnectionState.resolving;

		AddressInfo[] addressInfos;
		try
		{
			auto addresses = getAddress(host, port);
			enforce(addresses.length, "No addresses found");
			debug (ASOCKETS)
			{
				stderr.writefln("Resolved to %s addresses:", addresses.length);
				foreach (address; addresses)
					stderr.writefln("- %s", address.toString());
			}

			if (addresses.length > 1)
			{
				import std.random : randomShuffle;
				randomShuffle(addresses);
			}

			foreach (address; addresses)
				addressInfos ~= AddressInfo(address.addressFamily, SocketType.STREAM, ProtocolType.TCP, address, host);
		}
		catch (SocketException e)
			return onError("Lookup error: " ~ e.msg);

		state = ConnectionState.disconnected;
		connect(addressInfos);
	}
}

// ***************************************************************************

/// An asynchronous connection server for socket-based connections.
class SocketServer
{
protected:
	/// Class that actually performs listening on a certain address family
	final class Listener : GenericSocket
	{
		this(Socket conn)
		{
			debug (ASOCKETS) stderr.writefln("New Listener @ %s", cast(void*)this);
			this.conn = conn;
			socketManager.register(this);
		}

		/// Called when a socket is readable.
		override void onReadable()
		{
			debug (ASOCKETS) stderr.writefln("Accepting connection from listener @ %s", cast(void*)this);
			Socket acceptSocket = conn.accept();
			acceptSocket.blocking = false;
			if (handleAccept)
			{
				auto connection = createConnection(acceptSocket);
				debug (ASOCKETS) stderr.writefln("\tAccepted connection %s from %s", connection, connection.remoteAddressStr);
				connection.setKeepAlive();
				//assert(connection.connected);
				//connection.connected = true;
				acceptHandler(connection);
			}
			else
				acceptSocket.close();
		}

		/// Called when a socket is writable.
		override void onWritable()
		{
		}

		/// Called when an error occurs on the socket.
		override void onError(string reason)
		{
			close(); // call parent
		}

		void closeListener()
		{
			assert(conn);
			socketManager.unregister(this);
			conn.close();
			conn = null;
		}
	}

	SocketConnection createConnection(Socket socket)
	{
		return new SocketConnection(socket, datagram);
	}

	/// Whether the socket is listening.
	bool listening;
	/// Listener instances
	Listener[] listeners;
	bool datagram;

	final void updateFlags()
	{
		foreach (listener; listeners)
			listener.notifyRead = handleAccept !is null;
	}

public:
	/// Start listening on this socket.
	final void listen(AddressInfo[] addressInfos)
	{
		foreach (ref addressInfo; addressInfos)
		{
			try
			{
				Socket conn = new Socket(addressInfo);
				conn.blocking = false;
				if (addressInfo.family == AddressFamily.INET6)
					conn.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

				conn.bind(addressInfo.address);
				conn.listen(totalCPUs * 2);

				listeners ~= new Listener(conn);
			}
			catch (SocketException e)
			{
				debug(ASOCKETS) stderr.writefln("Unable to listen node \"%s\" service \"%s\"", addressInfo.address.toAddrString(), addressInfo.address.toPortString());
				debug(ASOCKETS) stderr.writeln(e.msg);
			}
		}

		if (listeners.length==0)
			throw new Exception("Unable to bind service");

		listening = true;

		updateFlags();
	}

	this()
	{
		this(false);
	} ///

	this(bool datagram)
	{
		this.datagram = datagram;
	} ///

	/// Creates a Server with the given sockets.
	/// The sockets must have already had `bind` and `listen` called on them.
	this(Socket[] sockets...)
	{
		foreach (socket; sockets)
			listeners ~= new Listener(socket);
	}

	/// Returns all listening addresses.
	final @property Address[] localAddresses()
	{
		Address[] result;
		foreach (listener; listeners)
			result ~= listener.localAddress;
		return result;
	}

	/// Returns `true` if the server is listening for incoming connections.
	final @property bool isListening()
	{
		return listening;
	}

	/// Stop listening on this socket.
	final void close()
	{
		foreach (listener;listeners)
			listener.closeListener();
		listeners = null;
		listening = false;
		if (handleClose)
			handleClose();
	}

	/// Create a SocketServer using the handle passed on standard input,
	/// for which `listen` had already been called. Used by
	/// e.g. FastCGI and systemd sockets with "Listen = yes".
	static SocketServer fromStdin()
	{
		socket_t socket;
		version (Windows)
		{
			import core.sys.windows.winbase : GetStdHandle, STD_INPUT_HANDLE;
			socket = cast(socket_t)GetStdHandle(STD_INPUT_HANDLE);
		}
		else
			socket = cast(socket_t)0;

		auto s = new Socket(socket, AddressFamily.UNSPEC);
		s.blocking = false;
		return new SocketServer(s);
	}

	/// Callback for when the socket was closed.
	void delegate() handleClose;

	private void delegate(SocketConnection incoming) acceptHandler;
	/// Callback for an incoming connection.
	/// Connections will not be accepted unless this handler is set.
	@property final void delegate(SocketConnection incoming) handleAccept() { return acceptHandler; }
	/// ditto
	@property final void handleAccept(void delegate(SocketConnection incoming) value) { acceptHandler = value; updateFlags(); }
}

/// An asynchronous TCP connection server.
class TcpServer : SocketServer
{
protected:
	override SocketConnection createConnection(Socket socket)
	{
		return new TcpConnection(socket);
	}

public:
	this()
	{
	} ///

	this(Socket[] sockets...)
	{
		super(sockets);
	} /// Construct from the given sockets.

	///
	alias listen = SocketServer.listen; // raise overload

	/// Start listening on this socket.
	final ushort listen(ushort port, string addr = null)
	{
		debug(ASOCKETS) stderr.writefln("Attempting to listen on %s:%d", addr, port);
		//assert(!listening, "Attempting to listen on a listening socket");

		auto addressInfos = getAddressInfo(addr, to!string(port), AddressInfoFlags.PASSIVE, SocketType.STREAM, ProtocolType.TCP);

		debug (ASOCKETS)
		{
			stderr.writefln("Resolved to %s addresses:", addressInfos.length);
			foreach (ref addressInfo; addressInfos)
				stderr.writefln("- %s", addressInfo);
		}

		// listen on random ports only on IPv4 for now
		if (port == 0)
		{
			foreach_reverse (i, ref addressInfo; addressInfos)
				if (addressInfo.family != AddressFamily.INET)
					addressInfos = addressInfos[0..i] ~ addressInfos[i+1..$];
		}

		listen(addressInfos);

		foreach (listener; listeners)
		{
			auto address = listener.conn.localAddress();
			if (address.addressFamily == AddressFamily.INET)
				port = to!ushort(address.toPortString());
		}

		return port;
	}

	deprecated("Use SocketServer.fromStdin")
	static TcpServer fromStdin() { return cast(TcpServer) cast(void*) SocketServer.fromStdin; }

	/// Delegate to be called when a connection is accepted.
	@property final void handleAccept(void delegate(TcpConnection incoming) value) { super.handleAccept((SocketConnection c) => value(cast(TcpConnection)c)); }
}

// ***************************************************************************

/// Base class for connection-less socket protocols, i.e. those for
/// which we must use sendto instead of connect/send.
/// These generally correspond to stateless / datagram-based
/// protocols, like UDP.
/// This module's class hierarchy is mostly oriented towards
/// stateful, stream-based protocols; to represent connectionless
/// protocols, this class encapsulates a socket with a fixed
/// destination (sendto) address, and optionally bound to a local
/// address.
/// Currently received packets' address is not exposed.
class ConnectionlessSocketConnection : Connection
{
protected:
	this(Socket conn)
	{
		super(conn);
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		//scope(success) updateFlags();
		onWritableImpl();
		updateFlags();
	}

	// Work around scope(success) breaking debugger stack traces
	final private void onWritableImpl()
	{
		foreach (priority, ref queue; outQueue)
			while (queue.length)
			{
				ptrdiff_t sent;
				queue.front.enter((scope contents) {
					sent = conn.sendTo(contents, remoteAddress);
				});

				if (sent == Socket.ERROR)
				{
					if (wouldHaveBlocked())
						return;
					else
						return onError("send() error: " ~ lastSocketError);
				}
				else
				if (sent < queue.front.length)
				{
					return onError("Sent only %d/%d bytes of the datagram!".format(sent, queue.front.length));
				}
				else
				{
					assert(sent == queue.front.length);
					//debug writefln("[%s] Sent data:", remoteAddressStr);
					//debug writefln("%s", hexDump(pdata.contents[0..sent]));
					queue.front.clear();
					queue.popFront();
					if (queue.length == 0)
						queue = null;
				}
			}

		// outQueue is now empty
		if (bufferFlushedHandler)
			bufferFlushedHandler();
		if (state == ConnectionState.disconnecting)
		{
			debug (ASOCKETS) stderr.writefln("Closing @ %s (Delayed disconnect - buffer flushed)", cast(void*)this);
			close();
		}
	}

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		assert(false); // never called (called only from overridden methods)
	}

	override sizediff_t doReceive(scope void[] buffer)
	{
		return conn.receive(buffer);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New ConnectionlessSocketConnection @ %s", cast(void*)this);
	}

	/// Initialize with the given `AddressFamily`, without binding to an address.
	final void initialize(AddressFamily family, SocketType type, ProtocolType protocol)
	{
		initializeImpl(family, type, protocol);
		if (connectHandler)
			connectHandler();
	}

	private final void initializeImpl(AddressFamily family, SocketType type, ProtocolType protocol)
	{
		assert(state == ConnectionState.disconnected, "Attempting to initialize a %s socket".format(state));
		assert(!conn);

		conn = new Socket(family, type, protocol);
		conn.blocking = false;
		socketManager.register(this);
		state = ConnectionState.connected;
		updateFlags();
	}

	/// Bind to a local address in order to receive packets sent there.
	final ushort bind(AddressInfo addressInfo)
	{
		initialize(addressInfo.family, addressInfo.type, addressInfo.protocol);
		conn.bind(addressInfo.address);

		auto address = conn.localAddress();
		auto port = to!ushort(address.toPortString());

		if (connectHandler)
			connectHandler();

		return port;
	}

// public:
	/// Where to send packets to.
	Address remoteAddress;
}

/// An asynchronous UDP stream.
/// UDP does not have connections, so this class encapsulates a socket
/// with a fixed destination (sendto) address, and optionally bound to
/// a local address.
/// Currently received packets' address is not exposed.
class UdpConnection : ConnectionlessSocketConnection
{
protected:
	this(Socket conn)
	{
		super(conn);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New UdpConnection @ %s", cast(void*)this);
	}

	/// Initialize with the given `AddressFamily`, without binding to an address.
	final void initialize(AddressFamily family, SocketType type = SocketType.DGRAM)
	{
		super.initialize(family, type, ProtocolType.UDP);
	}

	/// Bind to a local address in order to receive packets sent there.
	final ushort bind(string host, ushort port)
	{
		assert(host.length, "Empty host");

		debug (ASOCKETS) stderr.writefln("Connecting to %s:%s", host, port);

		state = ConnectionState.resolving;

		AddressInfo addressInfo;
		try
		{
			auto addresses = getAddress(host, port);
			enforce(addresses.length, "No addresses found");
			debug (ASOCKETS)
			{
				stderr.writefln("Resolved to %s addresses:", addresses.length);
				foreach (address; addresses)
					stderr.writefln("- %s", address.toString());
			}

			Address address;
			if (addresses.length > 1)
			{
				import std.random : uniform;
				address = addresses[uniform(0, $)];
			}
			else
				address = addresses[0];
			addressInfo = AddressInfo(address.addressFamily, SocketType.DGRAM, ProtocolType.UDP, address, host);
		}
		catch (SocketException e)
		{
			onError("Lookup error: " ~ e.msg);
			return 0;
		}

		state = ConnectionState.disconnected;
		return super.bind(addressInfo);
	}
}

///
debug(ae_unittest) unittest
{
	auto server = new UdpConnection();
	server.bind("127.0.0.1", 0);

	auto client = new UdpConnection();
	client.initialize(server.localAddress.addressFamily);

	string[] packets = ["", "Hello", "there"];
	client.remoteAddress = server.localAddress;
	client.send({
		DataVec data;
		foreach (packet; packets)
			data ~= Data(packet.asBytes);
		return data;
	}()[]);

	server.handleReadData = (Data data)
	{
		assert(data.unsafeContents == packets[0]);
		packets = packets[1..$];
		if (!packets.length)
		{
			server.close();
			client.close();
		}
	};
	socketManager.loop();
	assert(!packets.length);
}

// ***************************************************************************

/// Base class for a connection adapter.
/// By itself, does nothing.
class ConnectionAdapter : IConnection
{
	/// The next connection in the chain (towards the raw transport).
	IConnection next;

	this(IConnection next)
	{
		this.next = next;
		next.handleConnect = &onConnect;
		next.handleDisconnect = &onDisconnect;
		next.handleBufferFlushed = &onBufferFlushed;
	} ///

	@property ConnectionState state() { return next.state; } ///

	/// Queue Data for sending.
	void send(scope Data[] data, int priority)
	{
		next.send(data, priority);
	}

	alias send = IConnection.send; /// ditto

	/// Terminate the connection.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		next.disconnect(reason, type);
	}

	protected void onConnect()
	{
		if (connectHandler)
			connectHandler();
	}

	protected void onReadData(Data data)
	{
		// onReadData should be fired only if readDataHandler is set
		assert(readDataHandler, "onReadData caled with null readDataHandler");
		readDataHandler(data);
	}

	protected void onDisconnect(string reason, DisconnectType type)
	{
		if (disconnectHandler)
			disconnectHandler(reason, type);
	}

	protected void onBufferFlushed()
	{
		if (bufferFlushedHandler)
			bufferFlushedHandler();
	}

	/// Callback for when a connection has been established.
	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	protected ConnectHandler connectHandler;

	/// Callback setter for when new data is read.
	@property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
		next.handleReadData = value ? &onReadData : null ;
	}
	protected ReadDataHandler readDataHandler;

	/// Callback setter for when a connection was closed.
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	protected DisconnectHandler disconnectHandler;

	/// Callback setter for when all queued data has been written.
	@property void handleBufferFlushed(BufferFlushedHandler value) { bufferFlushedHandler = value; }
	protected BufferFlushedHandler bufferFlushedHandler;
}

// ***************************************************************************

/// Buffers the data received from the next connection,
/// even when this object is not marked as readable (handleReadData unset).
class BufferingAdapter : ConnectionAdapter
{
	Data[] buffer;

	this(IConnection next)
	{
		super(next);
		next.handleReadData = &onReadData;
	}

	override void onReadData(Data data)
	{
		if (readDataHandler)
		{
			assert(buffer.length == 0);
			readDataHandler(data);
		}
		else
			buffer.queuePush(data);
	}

	override @property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
		while (readDataHandler && buffer.length)
			readDataHandler(buffer.queuePop);
	}
}

// ***************************************************************************

/// Adapter for connections with a line-based protocol.
/// Splits data stream into delimiter-separated lines.
class LineBufferedAdapter : ConnectionAdapter
{
	/// The default `LineBufferedAdapter` delimiter.
	static immutable defaultDelimiter = "\r\n";

	/// The protocol's line delimiter for receiving.
	string delimiter = defaultDelimiter;

	/// The protocol's line delimiter for sending.
	/// If null, uses the same delimiter as for receiving.
	string sendDelimiter = null;

	/// Maximum line length (0 means unlimited).
	size_t maxLength = 0;

	this(IConnection next, string delimiter = defaultDelimiter)
	{
		super(next);
		this.delimiter = delimiter;
	} ///

	/// Expose inherited send overloads hidden by the string overload.
	alias send = typeof(super).send;

	/// Override to append delimiter after each send.
	override void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		super.send(data, priority);
		auto delimiterDatum = Data(this.effectiveSendDelimiter.asBytes);
		super.send(delimiterDatum.asSlice, priority);
	}

	/// Append a line with delimiter to the send buffer.
	void send(string line, int priority = DEFAULT_PRIORITY)
	{
		auto datum = Data(line.asBytes);
		super.send(datum.asSlice, priority);
	}

private:
	@property string effectiveSendDelimiter()
	{
		return sendDelimiter !is null ? sendDelimiter : delimiter;
	}

protected:
	/// The receive buffer.
	Data inBuffer;

	/// Called when data has been received.
	final override void onReadData(Data data)
	{
		import std.string : indexOf;
		auto startIndex = inBuffer.length;
		if (inBuffer.length)
			inBuffer ~= data;
		else
			inBuffer = data;

		assert(delimiter.length >= 1);
		if (startIndex >= delimiter.length)
			startIndex -= delimiter.length - 1;
		else
			startIndex = 0;

		auto index = inBuffer[startIndex .. $].indexOf(delimiter.asBytes);
		while (index >= 0)
		{
			if (!processLine(startIndex + index))
				break;

			startIndex = 0;
			index = inBuffer.indexOf(delimiter.asBytes);
		}

		if (maxLength && inBuffer.length > maxLength)
			disconnect("Line too long", DisconnectType.error);
	}

	// `index` is the index of the delimiter's first character.
	final bool processLine(size_t index)
	{
		if (maxLength && index > maxLength)
		{
			disconnect("Line too long", DisconnectType.error);
			return false;
		}
		auto line = inBuffer[0..index];
		inBuffer = inBuffer[index+delimiter.length..inBuffer.length];
		super.onReadData(line);
		return true;
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		inBuffer.clear();
	}
}

// ***************************************************************************

/// Fires an event handler or disconnects connections
/// after a period of inactivity.
class TimeoutAdapter : ConnectionAdapter
{
	this(IConnection next)
	{
		debug (ASOCKETS) stderr.writefln("New TimeoutAdapter @ %s", cast(void*)this);
		super(next);
	} ///

	/// Set the `Duration` indicating the period of inactivity after which to take action.
	final void setIdleTimeout(Duration timeout)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.setIdleTimeout @ %s", cast(void*)this);
		assert(timeout > Duration.zero);
		this.timeout = timeout;

		// Configure idleTask
		if (idleTask is null)
		{
			idleTask = new TimerTask();
			idleTask.handleTask = &onTask_Idle;
		}
		else if (idleTask.isWaiting())
			idleTask.cancel();

		mainTimer.add(idleTask, now + timeout);
	}

	/// Manually mark this connection as non-idle, restarting the idle timer.
	/// `handleNonIdle` will be called, if set.
	void markNonIdle()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.markNonIdle @ %s", cast(void*)this);
		if (handleNonIdle)
			handleNonIdle();
		if (idleTask && idleTask.isWaiting())
			idleTask.restart(now + timeout);
	}

	/// Stop the idle timer.
	void cancelIdleTimeout()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.cancelIdleTimeout @ %s", cast(void*)this);
		assert(idleTask !is null);
		assert(idleTask.isWaiting());
		idleTask.cancel();
	}

	/// Restart the idle timer.
	void resumeIdleTimeout()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.resumeIdleTimeout @ %s", cast(void*)this);
		assert(idleTask !is null);
		assert(!idleTask.isWaiting());
		mainTimer.add(idleTask, now + timeout);
	}

	/// Returns the point in time when the idle handler is scheduled
	/// to be called, or null if it is not scheduled.
	/*Nullable!MonoTime*/auto when()()
	{
		import std.typecons : Nullable;
		return idleTask.isWaiting()
			? Nullable!MonoTime(idleTask.when)
			: Nullable!MonoTime.init;
 	}

	/// Callback for when a connection has stopped responding.
	/// If unset, the connection will be disconnected.
	void delegate() handleIdleTimeout;

	/// Callback for when a connection is marked as non-idle
	/// (when data is received).
	void delegate() handleNonIdle;

protected:
	override void onConnect()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onConnect @ %s", cast(void*)this);
		markNonIdle();
		super.onConnect();
	}

	override void onReadData(Data data)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onReadData @ %s", cast(void*)this);
		markNonIdle();
		super.onReadData(data);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onDisconnect @ %s", cast(void*)this);
		if (idleTask && idleTask.isWaiting())
			idleTask.cancel();
		super.onDisconnect(reason, type);
	}

private:
	TimerTask idleTask; // non-null if an idle timeout has been set
	Duration timeout;

	final void onTask_Idle(Timer /*timer*/, TimerTask /*task*/)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onTask_Idle @ %s", cast(void*)this);
		if (state == ConnectionState.disconnecting)
			return disconnect("Delayed disconnect - time-out", DisconnectType.error);

		if (state == ConnectionState.disconnected)
			return;

		if (handleIdleTimeout)
		{
			resumeIdleTimeout(); // reschedule (by default)
			handleIdleTimeout();
		}
		else
			disconnect("Time-out", DisconnectType.error);
	}
}

// ***************************************************************************

debug(ae_unittest) unittest
{
	void testTimer()
	{
		bool fired;
		setTimeout({fired = true;}, 10.msecs);
		socketManager.loop();
		assert(fired);
	}

	testTimer();
}
