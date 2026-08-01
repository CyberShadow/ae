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
debug(ASOCKETS_DEBUG_IDLE) import ae.utils.exception : captureStackTrace, printCapturedStackTrace, TraceInfo;
private import std.conv : to;


// https://issues.dlang.org/show_bug.cgi?id=7016
static import ae.utils.array;

private enum EventLoopMechanism { select, epoll, libev, iocp }

// Choose a default event loop mechanism
// If one was explicitly requested, use it:
private enum eventLoopMechanism = {
	version (SELECT) return EventLoopMechanism.select; else
	version (EPOLL) return EventLoopMechanism.epoll; else
	version (LIBEV) return EventLoopMechanism.libev; else
	version (IOCP) return EventLoopMechanism.iocp; else
	// Otherwise, pick a default:
	{
		version (linux)
			return EventLoopMechanism.epoll;
		else
		version (Have_libev)
			return EventLoopMechanism.libev;
		else
		version (Windows)
			return EventLoopMechanism.iocp;
		else
			return EventLoopMechanism.select;
	}
}();

package(ae) enum bool isIocpEventLoop = (eventLoopMechanism == EventLoopMechanism.iocp);

static if (eventLoopMechanism == EventLoopMechanism.epoll)
{
	import core.sys.linux.epoll;
}
static if (eventLoopMechanism == EventLoopMechanism.libev)
{
	import core.memory : GC;
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

static if (eventLoopMechanism == EventLoopMechanism.epoll)
{
	// Use the epoll_event.data.ptr field to store the parent GenericSocket address.
	// Track read/write interest separately and update epoll via epoll_ctl when they change.

	/// `epoll`-based event loop implementation.
	struct SocketManager
	{
	private:
		int epollFd = -1;
		epoll_event[100] events; // Batch size for epoll_wait

		/// List of all sockets to poll (needed for daemon tracking and debug).
		GenericSocket[] sockets;

		/// Debug AA to check for dangling socket references.
		debug GenericSocket[socket_t] socketHandles;

		void delegate()[] nextTickHandlers;
		IdleHandler[] idleHandlers;

	public:
		MonoTime now;

		/// Register a socket with the manager.
		void register(GenericSocket conn)
		{
			debug (ASOCKETS) stderr.writefln("Registering %s (%d total)", conn, sockets.length + 1);
			assert(!conn.socket.blocking, "Trying to register a blocking socket");

			// Lazily create epoll instance
			if (epollFd < 0)
			{
				epollFd = epoll_create1(0);
				assert(epollFd >= 0, "epoll_create1 failed");
			}

			assert(!conn._epollRegistered);
			assert(conn._epollEvents == 0);

			sockets ~= conn;

			debug
			{
				auto handle = conn.socket.handle;
				assert(handle != socket_t.init, "Can't register a closed socket");
				assert(handle !in socketHandles, "This socket handle is already registered");
				socketHandles[handle] = conn;
			}

			debug (ASOCKETS_DEBUG_SHUTDOWN) conn.registrationStackTrace = captureStackTrace();
			else debug (ASOCKETS_DEBUG_IDLE) conn.registrationStackTrace = captureStackTrace();

			conn.updateEpoll();
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

			assert(conn._epollRegistered == (conn._epollEvents != 0));
			if (conn._epollRegistered)
			{
				int ret = epoll_ctl(epollFd, EPOLL_CTL_DEL, conn.socket.handle, null);
				assert(ret == 0, "epoll_ctl DEL failed");
				conn._epollRegistered = false;
			}

			conn._epollEvents = 0;

			foreach (size_t i, GenericSocket s; sockets)
				if (s is conn)
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
			debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.register();

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

				// Check if there are any active (non-daemon) sockets
				bool haveActive;
				foreach (conn; sockets)
				{
					if (!conn.socket)
						continue;
					if (conn.notifyRead && !conn.daemonRead)
						haveActive = true;
					if (conn.notifyWrite && !conn.daemonWrite)
						haveActive = true;
				}

				debug (ASOCKETS) stderr.writefln("Waiting (%sactive with %d sockets, %s timer events, %d idle handlers)...",
					haveActive ? "" : "not ",
					sockets.length,
					mainTimer.isWaiting() ? "with" : "no",
					idleHandlers.length,
				);

				if (!haveActive && !mainTimer.hasNonDaemonTasks() && !nextTickHandlers.length)
				{
					debug (ASOCKETS) stderr.writeln("No more active sockets or timer events, exiting loop.");
					break;
				}

				int nfds;

				// If no sockets are registered, we can't use epoll_wait (epollFd may be -1).
				// Use nanosleep instead to wait for timers.
				if (sockets.length == 0)
				{
					if (mainTimer.isWaiting())
					{
						now = MonoTime.currTime();
						auto remaining = mainTimer.getRemainingTime(now);
						if (remaining > Duration.zero)
						{
							debug (ASOCKETS) stderr.writefln("nanosleep for %s (no sockets)", remaining);
							import core.sys.posix.time : nanosleep, timespec;
							auto ts = timespec(
								cast(typeof(timespec.tv_sec))remaining.total!"seconds",
								cast(typeof(timespec.tv_nsec))(remaining.total!"nsecs" % 1_000_000_000)
							);
							nanosleep(&ts, null);
						}
					}
					nfds = 0;
				}
				else
				{
					int timeout_msec;
					if (mainTimer.isWaiting())
					{
						now = MonoTime.currTime();
						auto remaining = mainTimer.getRemainingTime(now);
						long msec = (remaining.total!"hnsecs" + 9999) / 10_000;
						timeout_msec = msec > int.max ? -1 : (msec <= 0 ? 0 : cast(int)msec);
					}
					else
					{
						timeout_msec = -1; // Wait indefinitely
					}

					debug (ASOCKETS) stderr.writefln("epoll_wait with timeout %d ms", timeout_msec);
					nfds = epoll_wait(epollFd, events.ptr, cast(int)events.length, timeout_msec);
					debug (ASOCKETS) stderr.writefln("%d events fired.", nfds);
				}

				now = MonoTime.currTime();

				if (nfds > 0)
				{
					debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.onActivity();

					// Process events
					foreach (ref ev; events[0 .. nfds])
					{
						auto conn = cast(GenericSocket)ev.data.ptr;
						assert(conn !is null, "epoll event with null socket");

						runUserEventHandler({
							// Skip stale events for connections that were
							// disconnected during this event loop iteration
							// (e.g. Duplex closing both sides when one gets EOF).
							if (conn.conn is null)
								return;

							// Handle errors
							if (ev.events & EPOLLERR)
							{
								debug (ASOCKETS) stderr.writefln("\t%s - error", conn);
								string errMsg = "socket error";
								if (conn.socket)
								{
									try
									{
										auto socketErr = conn.socket.getErrorText();
										if (socketErr.length)
											errMsg = socketErr;
									}
									catch (SocketOSException)
									{
										// getsockopt(SO_ERROR) not supported for non-socket
										// fds (e.g. pipes via FileConnection).
										errMsg = "EPOLLERR on fd " ~ to!string(cast(int) conn.socket.handle);
									}
								}
								conn.onError(errMsg);
								return;
							}

							// Write takes priority (like in select version)
							if ((ev.events & EPOLLOUT) && conn.notifyWrite)
							{
								debug (ASOCKETS) stderr.writefln("\t%s - calling onWritable", conn);
								conn.onWritable();
							}
							// Then read (EPOLLHUP also triggers read so recv() returns 0 for EOF)
							else if ((ev.events & (EPOLLIN | EPOLLHUP)) && conn.notifyRead)
							{
								debug (ASOCKETS) stderr.writefln("\t%s - calling onReadable", conn);
								conn.onReadable();
							}
						});
					}
				}
				else if (nfds == 0 && idleHandlers.length)
				{
					debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.onActivity();

					// Timeout with no events - run idle handlers
					import ae.utils.array : shift;
					auto idleHandler = idleHandlers.shift();

					// Rotate the idle handler queue before running it,
					// in case the handler unregisters itself.
					idleHandlers ~= idleHandler;

					runUserEventHandler({
						idleHandler.dg();
					});
				}

				// Fire timers
				runUserEventHandler({
					mainTimer.prod(now);
				});

				eventCounter++;
			}
		}
	}

	// Use UFCS to allow addIdleHandler/removeIdleHandler
	/// Register a function to be called when the event loop is idle.
	void addIdleHandler(ref SocketManager socketManager, void delegate() handler)
	{
		foreach (ref idleHandler; socketManager.idleHandlers)
			assert(handler !is idleHandler.dg);

		socketManager.idleHandlers ~= IdleHandler(handler);
	}

	/// Unregister a function previously registered with `addIdleHandler`.
	void removeIdleHandler(alias pred=(a, b) => a is b, Args...)(ref SocketManager socketManager, Args args)
	{
		foreach (i, ref idleHandler; socketManager.idleHandlers)
			if (pred(idleHandler.dg, args))
			{
				import std.algorithm : remove;
				socketManager.idleHandlers = socketManager.idleHandlers.remove(i);
				return;
			}
		assert(false, "No such idle handler");
	}

	private mixin template SocketMixin()
	{
		private uint _epollEvents; // Current epoll event mask
		private bool _epollRegistered; // True iff this socket is in the epoll set

		private final void updateEpoll()
		{
			if (!conn)
				return; // Not connected yet
			assert(_epollRegistered == (_epollEvents != 0));

			uint newEvents = 0;
			if (_notifyRead) newEvents |= EPOLLIN;
			if (_notifyWrite) newEvents |= EPOLLOUT;

			if (newEvents == _epollEvents)
				return;

			if (newEvents == 0)
			{
				assert(_epollRegistered);
				int ret = epoll_ctl(socketManager.epollFd, EPOLL_CTL_DEL, conn.handle, null);
				assert(ret == 0, "epoll_ctl DEL failed");
				_epollRegistered = false;
			}
			else
			{
				epoll_event ev;
				ev.events = newEvents;
				ev.data.ptr = cast(void*)this;
				if (_epollRegistered)
				{
					int ret = epoll_ctl(socketManager.epollFd, EPOLL_CTL_MOD, conn.handle, &ev);
					assert(ret == 0, "epoll_ctl MOD failed");
				}
				else
				{
					assert(_epollEvents == 0);
					int ret = epoll_ctl(socketManager.epollFd, EPOLL_CTL_ADD, conn.handle, &ev);
					assert(ret == 0, "epoll_ctl ADD failed");
					_epollRegistered = true;
				}
			}

			_epollEvents = newEvents;
		}

		private bool _notifyRead, _notifyWrite;

		/// Interested in read notifications (onReadable)?
		@property final void notifyRead(bool value)
		{
			_notifyRead = value;
			updateEpoll();
		}
		@property final bool notifyRead() { return _notifyRead; } /// ditto

		/// Interested in write notifications (onWritable)?
		@property final void notifyWrite(bool value)
		{
			_notifyWrite = value;
			updateEpoll();
		}
		@property final bool notifyWrite() { return _notifyWrite; } /// ditto

		/// Don't block the process from exiting, even if the socket is ready to receive data.
		bool daemonRead;

		/// Don't block the process from exiting, even if the socket is ready to send data.
		bool daemonWrite;

		deprecated alias daemon = daemonRead;
	}
}
else
static if (eventLoopMechanism == EventLoopMechanism.libev)
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

			debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.onActivity();

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
		bool evTimerUnreferenced;
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

		private void setTimerReferenced(ev_loop_t* evLoop, bool referenced)
		{
			assert(ev_is_active(&evTimer));
			if (referenced == !evTimerUnreferenced)
				return;

			if (referenced)
			{
				ev_ref(evLoop);
				evTimerUnreferenced = false;
			}
			else
			{
				ev_unref(evLoop);
				evTimerUnreferenced = true;
			}
		}

		void updateTimer(bool force)
		{
			auto evLoop = ev_default_loop(0);
			auto timerActive = !!ev_is_active(&evTimer);
			assert(!evTimerUnreferenced || timerActive);
			assert((lastNextEvent == MonoTime.max) == !timerActive);

			auto nextEvent = mainTimer.getNextEvent();
			if (force || lastNextEvent != nextEvent)
			{
				debug (ASOCKETS) stderr.writefln("Rescheduling timer. Was at %s, now at %s", lastNextEvent, nextEvent);
				if (nextEvent == MonoTime.max) // Stopping
				{
					if (lastNextEvent != MonoTime.max)
					{
						setTimerReferenced(evLoop, true);
						assert(!evTimerUnreferenced);
						ev_timer_stop(evLoop, &evTimer);
						assert(!ev_is_active(&evTimer));
					}
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
						assert(!timerActive);
						assert(!evTimerUnreferenced);
						ev_timer_init(&evTimer, &timerCallback, 0., tstamp);
						ev_timer_start(evLoop, &evTimer);
						assert(ev_is_active(&evTimer));
					}
					else // Adjusting
					{
						setTimerReferenced(evLoop, true);
						assert(!evTimerUnreferenced);
						evTimer.repeat = tstamp;
						ev_timer_again(evLoop, &evTimer);
						assert(ev_is_active(&evTimer));
					}
				}
				lastNextEvent = nextEvent;
			}

			if (ev_is_active(&evTimer))
				setTimerReferenced(evLoop, mainTimer.hasNonDaemonTasks());
			else
				assert(!evTimerUnreferenced);

			timerActive = !!ev_is_active(&evTimer);
			assert(!evTimerUnreferenced || timerActive);
			assert((lastNextEvent == MonoTime.max) == !timerActive);
			if (timerActive)
				assert(evTimerUnreferenced == !mainTimer.hasNonDaemonTasks());
		}

	public:
		MonoTime now;

		/// Register a socket with the manager.
		void register(GenericSocket socket)
		{
			debug (ASOCKETS) stderr.writefln("Registering %s", socket);
			assert(socket.evRead.data is null && socket.evWrite.data is null,
				"Re-registering a started libev socket");
			assert(!socket.evRooted, "Re-registering a GC-rooted or pinned libev socket");
			auto fd = socket.conn.handle;
			assert(fd, "Must have fd before socket registration");
			ev_io_init(&socket.evRead , &ioCallback, fd, EV_READ );
			ev_io_init(&socket.evWrite, &ioCallback, fd, EV_WRITE);
			count++;
			debug (ASOCKETS_DEBUG_SHUTDOWN) socket.registrationStackTrace = captureStackTrace();
			else debug (ASOCKETS_DEBUG_IDLE) socket.registrationStackTrace = captureStackTrace();
		}

		/// Unregister a socket with the manager.
		void unregister(GenericSocket socket)
		{
			debug (ASOCKETS) stderr.writefln("Unregistering %s", socket);
			socket.notifyRead  = false;
			socket.notifyWrite = false;
			assert(socket.evRead.data is null && socket.evWrite.data is null,
				"Unregistering a libev socket with active watchers");
			assert(!socket.evRooted, "Unregistering a GC-rooted or pinned libev socket");
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
			debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.register();

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
		private bool evReadUnreferenced, evWriteUnreferenced;
		private bool evRooted;
		private bool _daemonRead, _daemonWrite;

		private final void retainWatcherOwner()
		{
			assert(!evRooted, "Retaining an already rooted libev watcher owner");
			assert(evRead.data is null && evWrite.data is null,
				"Retaining a libev watcher owner after publication");
			GC.addRoot(cast(void*)this);
			GC.setAttr(cast(void*)this, GC.BlkAttr.NO_MOVE);
			evRooted = true;
		}

		private final void releaseWatcherOwner()
		{
			assert(evRooted, "Releasing an unrooted libev watcher owner");
			assert(evRead.data is null && evWrite.data is null,
				"Releasing a libev watcher owner before the final native stop");
			auto owner = this;
			GC.removeRoot(cast(void*)owner);
			GC.clrAttr(cast(void*)owner, GC.BlkAttr.NO_MOVE);
			evRooted = false;
		}

		private final void setWatcherReferenced(ref ev_io ev, ref bool unreferenced, bool referenced) nothrow @nogc
		{
			assert(ev.data, "Reconciling reference state of a stopped libev watcher");
			if (referenced == !unreferenced)
				return;

			// The deimos-ev binding declares ev_ref/ev_unref/ev_default_loop as
			// plain `nothrow extern(C)` (no @nogc); none of them allocate, so
			// the cast is sound.
			// https://github.com/dlang/phobos/pull/4273
			alias EvDefaultLoopNoGC = extern(C) ev_loop_t* function(uint) nothrow @nogc;
			alias EvRefNoGC = extern(C) void function(ev_loop_t*) nothrow @nogc;
			auto evLoop = (cast(EvDefaultLoopNoGC)&ev_default_loop)(0);
			if (referenced)
			{
				(cast(EvRefNoGC)&ev_ref)(evLoop);
				unreferenced = false;
			}
			else
			{
				(cast(EvRefNoGC)&ev_unref)(evLoop);
				unreferenced = true;
			}
		}

		private final void setWatcherState(ref ev_io ev, bool newValue, ref bool unreferenced, bool daemon)
		{
			if (!conn)
			{
				// Can happen when setting delegates before connecting.
				return;
			}

			assert(ev.data || !unreferenced, "Stale reference bit on an inactive libev watcher");

			auto hasActiveWatcher = evRead.data !is null || evWrite.data !is null;
			assert(evRooted == hasActiveWatcher, "Incoherent libev watcher owner root balance");

			if (newValue && !ev.data)
			{
				// Start
				assert(ev.data is null, "Starting an active libev watcher");
				if (!evRooted)
					retainWatcherOwner();
				ev.data = cast(void*)this;
				ev_io_start(ev_default_loop(0), &ev);
				setWatcherReferenced(ev, unreferenced, !daemon);
			}
			else
			if (!newValue && ev.data)
			{
				// Stop
				assert(ev.data is cast(void*)this);
				// Restore the reference before stopping, so libev's own
				// reference count stays balanced regardless of daemon state.
				setWatcherReferenced(ev, unreferenced, true);
				ev_io_stop(ev_default_loop(0), &ev);
				ev.data = null;
				if (evRead.data is null && evWrite.data is null)
					releaseWatcherOwner();
			}
		}

		private final bool getWatcherState(ref ev_io ev) { return !!ev.data; }

		// Flags that determine socket wake-up events.

		/// Interested in read notifications (onReadable)?
		@property final void notifyRead (bool value) { setWatcherState(evRead , value, evReadUnreferenced , _daemonRead ); }
		@property final bool notifyRead () { return getWatcherState(evRead); } /// ditto
		/// Interested in write notifications (onWritable)?
		@property final void notifyWrite(bool value) { setWatcherState(evWrite, value, evWriteUnreferenced, _daemonWrite); }
		@property final bool notifyWrite() { return getWatcherState(evWrite); } /// ditto

		/// Don't block the process from exiting, even if the socket is ready to receive data.
		@property final void daemonRead(bool value) nothrow @nogc
		{
			if (_daemonRead == value)
				return;
			_daemonRead = value;
			if (evRead.data)
				setWatcherReferenced(evRead, evReadUnreferenced, !value);
		}
		@property final bool daemonRead() nothrow @nogc { return _daemonRead; } /// ditto

		/// Don't block the process from exiting, even if the socket is ready to send data.
		@property final void daemonWrite(bool value) nothrow @nogc
		{
			if (_daemonWrite == value)
				return;
			_daemonWrite = value;
			if (evWrite.data)
				setWatcherReferenced(evWrite, evWriteUnreferenced, !value);
		}
		@property final bool daemonWrite() nothrow @nogc { return _daemonWrite; } /// ditto

		deprecated alias daemon = daemonRead;

		debug ~this() @nogc
		{
			assert(evRead.data is null && evWrite.data is null, "Destroying an active libev socket");
			assert(!evRooted, "Destroying a GC-rooted or pinned libev socket");
			assert(!evReadUnreferenced && !evWriteUnreferenced, "Destroying a libev socket with a stale reference bit");
		}
	}
}
else
static if (eventLoopMechanism == EventLoopMechanism.select)
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

		void delegate()[] nextTickHandlers;
		IdleHandler[] idleHandlers;

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
			else debug (ASOCKETS_DEBUG_IDLE) conn.registrationStackTrace = captureStackTrace();
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
			debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.register();

			SocketSet readset, writeset, exceptset;
			size_t sockcount;
			uint setSize = FD_SETSIZE; // Can't trust SocketSet.max due to Issue 14012
			readset  = new SocketSet(setSize);
			writeset = new SocketSet(setSize);
			exceptset = new SocketSet(setSize);
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
					exceptset = new SocketSet(setSize);
				}
				else
				{
					readset.reset();
					writeset.reset();
					exceptset.reset();
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
						// On Windows, failed non-blocking connects are reported
						// via the exception set, not the write set.
						exceptset.add(conn.socket);
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
				if (!haveActive && !mainTimer.hasNonDaemonTasks() && !nextTickHandlers.length)
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
						events = Socket.select(readset, writeset, exceptset, 0.seconds);
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

					events = Socket.select(readset, writeset, exceptset, mainTimer.getRemainingTime(now));
				}
				else
					events = Socket.select(readset, writeset, exceptset);

				debug (ASOCKETS) stderr.writefln("%d events fired.", events);

				// Update time after sleeping
				now = MonoTime.currTime();

				if (events > 0)
				{
					debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.onActivity();

					// Handle just one event at a time, as the first
					// handler might invalidate select()'s results.
					runUserEventHandler({
						handleEvent(readset, writeset, exceptset);
					});
				}
				else
				if (idleHandlers.length)
				{
					debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.onActivity();

					import ae.utils.array : shift;
					auto idleHandler = idleHandlers.shift();

					// Rotate the idle handler queue before running it,
					// in case the handler unregisters itself.
					idleHandlers ~= idleHandler;

					runUserEventHandler({
						idleHandler.dg();
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

		private void handleEvent(SocketSet readset, SocketSet writeset, SocketSet exceptset)
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
				if (exceptset.isSet(conn.socket))
				{
					debug (ASOCKETS) stderr.writefln("\t%s - calling onWritable (from exceptset)", conn);
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
		foreach (ref idleHandler; socketManager.idleHandlers)
			assert(handler !is idleHandler.dg);

		socketManager.idleHandlers ~= IdleHandler(handler);
	}

	/// Unregister a function previously registered with `addIdleHandler`.
	void removeIdleHandler(alias pred=(a, b) => a is b, Args...)(ref SocketManager socketManager, Args args)
	{
		foreach (i, ref idleHandler; socketManager.idleHandlers)
			if (pred(idleHandler.dg, args))
			{
				import std.algorithm : remove;
				socketManager.idleHandlers = socketManager.idleHandlers.remove(i);
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

		/// Don't block the process from exiting, even if the socket is ready to receive data.
		bool daemonRead;

		/// Don't block the process from exiting, even if the socket is ready to send data.
		bool daemonWrite;

		deprecated alias daemon = daemonRead;
	}
}
else
static if (eventLoopMechanism == EventLoopMechanism.iocp)
{
	import core.sys.windows.windows;
	import core.sys.windows.winsock2 : WSAGetLastError, WSAIoctl;
	import core.sys.windows.ntdef : NTSTATUS;
	import ae.sys.windows.iocp;
	private void _wsaSetLastError(int e) nothrow @nogc { WSASetLastError(e); }


	// ---- The dispatcher kind --------------------------------------------

	/// Discriminator for what to do when a completion arrives, stored
	/// alongside the OVERLAPPED so the dispatcher can route generically.
	package(ae) enum IocpOpKind : ubyte
	{
		socketRecv,
		socketRecvFrom, // WSARecvFrom completion for datagram sockets
		socketSend,
		socketAccept,   // AcceptEx completion on a listening socket
		socketConnect,  // ConnectEx completion on a client socket
		pipeRead,
		pipeWrite,
		pipeConnect,           // ConnectNamedPipe completion (NamedPipeServer)
		processExit,
		dirChange,   // ReadDirectoryChangesW completion
		userPost,    // PostQueuedCompletionStatus from another thread
	}

	/// Header that owners embed inside the per-operation buffer struct.
	/// The OVERLAPPED *must* be the first field so a pointer to it can be
	/// recovered as a pointer to IocpOp via simple cast (or vice-versa
	/// using offsetof). Owners pass `&op.overlapped` to WSARecv/WSASend etc.
	package(ae) struct IocpOp
	{
		OVERLAPPED   overlapped;       // MUST be first
		IocpOpKind   kind;
		bool         inFlight;
	}

	private struct IocpRetention
	{
		Object owner;
		bool draining;
	}

	private extern(Windows) static IocpOp* opFromOverlapped(OVERLAPPED* ov) @system pure nothrow @nogc
	{
		return cast(IocpOp*) ov;
	}

	extern (Windows) nothrow @nogc
	{
		ULONG RtlNtStatusToDosError(NTSTATUS Status);
	}

	pragma(lib, "ntdll");

	private uint normalizeIocpStatus(ULONG_PTR internal) nothrow @nogc
	{
		auto rawStatus = cast(uint)internal;
		if (rawStatus == 0)
			return 0;

		auto status = RtlNtStatusToDosError(cast(NTSTATUS)rawStatus);
		debug (ASOCKETS)
			if (status == ERROR_MR_MID_NOT_FOUND)
				stderr.writefln(
					"[iocp] no Win32 mapping for NTSTATUS 0x%08X", rawStatus);
		return status;
	}

	// ---- SocketManager ---------------------------------------------------

	/// `IOCP`-based event loop implementation.
	struct SocketManager
	{
	private:
		HANDLE iocpPort;
		// Track participants for daemon-state and shutdown.
		GenericSocket[] sockets;
		debug GenericSocket[socket_t] socketHandles;

		void delegate()[] nextTickHandlers;
		IdleHandler[] idleHandlers;

		// Sockets whose notifyWrite became true and need a synthetic
		// onWritable() call. Processed at the top of each loop iteration.
		GenericSocket[] pendingWritables;

		// Non-socket participants (e.g. WindowsPipeConnection,
		// process-exit waiters) that should keep the loop alive.
		IocpParticipant[] participants;

		IocpRetention[OVERLAPPED*] iocpRetentions;

		void ensurePort()
		{
			if (iocpPort is null)
			{
				iocpPort = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0);
				assert(iocpPort !is null, "CreateIoCompletionPort failed");
			}
		}

	public:
		MonoTime now;

		/// Get (creating if necessary) the IOCP port.
		package(ae) HANDLE getIocpPort()
		{
			ensurePort();
			return iocpPort;
		}

		package(ae) void retainIocpOp(IocpOp* op, Object owner)
		{
			enforce(op !is null, "null IOCP operation");
			enforce(owner !is null, "null IOCP operation owner");
			auto overlapped = &op.overlapped;
			enforce(overlapped !in iocpRetentions,
				"OVERLAPPED reused before its prior completion was dequeued");
			iocpRetentions[overlapped] = IocpRetention(owner, false);
		}

		package(ae) void rollbackIocpSubmission(IocpOp* op, Object owner)
		{
			takeIocpRetention(&op.overlapped, owner);
		}

		package(ae) void retireIocpOps(Object owner)
		{
			enforce(owner !is null, "null IOCP retirement owner");
			foreach (overlapped, ref retention; iocpRetentions)
				if (retention.owner is owner)
					retention.draining = true;
		}

		package(ae) bool hasIocpOps(Object owner)
		{
			enforce(owner !is null, "null IOCP operation owner");
			foreach (ref retention; iocpRetentions)
				if (retention.owner is owner)
					return true;
			return false;
		}

		private IocpRetention takeIocpRetention(
			OVERLAPPED* overlapped, Object expectedOwner = null)
		{
			enforce(overlapped !is null, "null IOCP completion");
			auto stored = overlapped in iocpRetentions;
			enforce(stored !is null, "unknown non-null IOCP completion");
			auto retention = *stored;
			enforce(retention.owner !is null, "null retained IOCP owner");
			if (expectedOwner !is null)
				enforce(retention.owner is expectedOwner && !retention.draining,
					"IOCP operation owner mismatch");
			enforce(iocpRetentions.remove(overlapped),
				"could not remove retained IOCP operation");
			return retention;
		}

		private bool hasDrainingIocpOps()
		{
			foreach (ref retention; iocpRetentions)
				if (retention.draining)
					return true;
			return false;
		}

		/// Register a socket. Associates its SOCKET handle with the IOCP
		/// port. Note: this association is *permanent* for the lifetime of
		/// the socket — closing the socket releases it.
		void register(GenericSocket conn)
		{
			debug (ASOCKETS) stderr.writefln("Registering %s (%d total)", conn, sockets.length + 1);
			assert(!conn.socket.blocking, "Trying to register a blocking socket");

			ensurePort();

			auto h = cast(HANDLE)conn.socket.handle;
			auto port = CreateIoCompletionPort(h, iocpPort, cast(ULONG_PTR)cast(void*)conn, 0);
			assert(port == iocpPort, "CreateIoCompletionPort association failed");

			sockets ~= conn;

			debug
			{
				auto handle = conn.socket.handle;
				assert(handle != socket_t.init, "Can't register a closed socket");
				assert(handle !in socketHandles, "This socket handle is already registered");
				socketHandles[handle] = conn;
			}

			debug (ASOCKETS_DEBUG_SHUTDOWN) conn.registrationStackTrace = captureStackTrace();
			else debug (ASOCKETS_DEBUG_IDLE) conn.registrationStackTrace = captureStackTrace();
		}

		/// Unregister a socket. The IOCP association is permanent — the
		/// socket must be closed by the caller after this returns.
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
					retireIocpOps(conn);
					sockets = sockets[0 .. i] ~ sockets[i + 1 .. sockets.length];
					// Drop pending-writable entry too
					import std.algorithm : remove, SwapStrategy;
					pendingWritables = pendingWritables.remove!(s => s is conn, SwapStrategy.unstable);
					return;
				}
			assert(false, "Socket not registered");
		}

		size_t size() { return sockets.length; }

		// Queue this socket for a synthetic onWritable() on the next tick.
		package(ae) void kickWritable(GenericSocket conn)
		{
			foreach (s; pendingWritables)
				if (s is conn)
					return;
			pendingWritables ~= conn;
		}

		// Called by IocpParticipant to register/unregister itself.
		package(ae) void addParticipant(IocpParticipant p)
		{
			participants ~= p;
		}
		package(ae) void removeParticipant(IocpParticipant p)
		{
			foreach (i, q; participants)
				if (q is p)
				{
					import std.algorithm : remove, SwapStrategy;
					participants = participants.remove!(x => x is p, SwapStrategy.unstable)();
					return;
				}
		}

		void loop()
		{
			debug (ASOCKETS) stderr.writeln("Starting event loop.");
			debug (ASOCKETS_DEBUG_SHUTDOWN) ShutdownDebugger.register();
			debug (ASOCKETS_DEBUG_IDLE) IdleDebugger.register();

			ensurePort();

			OVERLAPPED_ENTRY[64] entries;

			while (true)
			{
				// Process nextTick handlers exhaustively first.
				if (nextTickHandlers.length)
				{
					auto thisTickHandlers = nextTickHandlers;
					nextTickHandlers = null;
					foreach (handler; thisTickHandlers)
						handler();
					continue;
				}

				// Synthetic onWritable() for sockets whose notifyWrite
				// just became true. Process these *before* checking
				// daemon state, since onWritable() may post a WSASend
				// that starts holding the socket alive.
				if (pendingWritables.length)
				{
					auto pw = pendingWritables;
					pendingWritables = null;
					foreach (conn; pw)
					{
						if (conn.socket is null) continue;
						if (!conn.notifyWrite) continue;
						runUserEventHandler({
							if (conn.socket !is null && conn.notifyWrite)
								conn.onWritable();
						});
					}
					continue;
				}

				// Daemon-state check: if no non-daemon work remains, exit.
				bool haveActive;
				foreach (conn; sockets)
				{
					if (!conn.socket) continue;
					if (conn.notifyRead && !conn.daemonRead) { haveActive = true; break; }
					if (conn.notifyWrite && !conn.daemonWrite) { haveActive = true; break; }
					// An in-flight ConnectEx keeps a non-daemon client socket
					// alive even though notifyRead/notifyWrite are both false
					// during ConnectionState.connecting (the completion arrives
					// via IOCP, not via select-style readiness flags).
					if (conn._iocpConnectOp.inFlight && !conn.daemonRead && !conn.daemonWrite)
					{ haveActive = true; break; }
				}
				if (!haveActive)
				{
					foreach (p; participants)
						if (p.iocpHasNonDaemonWork())
						{
							haveActive = true;
							break;
						}
				}
				if (!haveActive && hasDrainingIocpOps())
					haveActive = true;

				if (!haveActive && !mainTimer.hasNonDaemonTasks() && !nextTickHandlers.length)
				{
					debug (ASOCKETS) stderr.writeln("No more active work, exiting loop.");
					break;
				}

				DWORD timeoutMs;
				if (mainTimer.isWaiting())
				{
					now = MonoTime.currTime();
					auto remaining = mainTimer.getRemainingTime(now);
					long msec = (remaining.total!"hnsecs" + 9999) / 10_000;
					if (msec < 0) msec = 0;
					if (msec > int.max) msec = int.max;
					timeoutMs = cast(DWORD)msec;
				}
				else
				{
					timeoutMs = INFINITE;
				}

				ULONG removed = 0;
				BOOL ok = GetQueuedCompletionStatusEx(
					iocpPort, entries.ptr, cast(ULONG)entries.length,
					&removed, timeoutMs, FALSE);

				now = MonoTime.currTime();

				if (!ok)
				{
					auto err = GetLastError();
					if (err == WAIT_TIMEOUT)
					{
						// Just a timeout; let timer fire below.
					}
					else
					{
						debug (ASOCKETS) stderr.writefln("GetQueuedCompletionStatusEx error: %d", err);
						// Continue; nothing dispatchable.
					}
				}
				else
				{
					foreach (i; 0 .. removed)
					{
						auto entry = &entries[i];
						auto overlapped = entry.lpOverlapped;

						if (overlapped is null)
						{
							// User-posted completion with no OVERLAPPED.
							// Dispatch via completion key (the participant).
							auto p = cast(IocpParticipant)cast(Object)cast(void*)entry.lpCompletionKey;
							if (p)
								runUserEventHandler({
									p.iocpUserPost(entry.dwNumberOfBytesTransferred);
								});
							continue;
						}

						auto retention = takeIocpRetention(overlapped);
						auto op = opFromOverlapped(overlapped);
						op.inFlight = false;
						auto bytes = entry.dwNumberOfBytesTransferred;
						auto rawStatus = op.overlapped.Internal;
						auto nativeStatus = normalizeIocpStatus(rawStatus);
						debug (ASOCKETS)
							if (rawStatus != 0)
								stderr.writefln("[iocp] completion status: NTSTATUS=0x%08X Win32=%d",
									cast(uint)rawStatus, nativeStatus);
						auto status = retention.draining
							? ERROR_OPERATION_ABORTED : nativeStatus;

						runUserEventHandler({
							dispatchCompletion(retention, op, bytes, status);
						});
					}
				}

				// Timers fire after I/O.
				runUserEventHandler({
					mainTimer.prod(now);
				});

				eventCounter++;
			}
		}

		private void dispatchCompletion(IocpRetention retention, IocpOp* op,
			DWORD bytes, uint status)
		{
			final switch (op.kind)
			{
				case IocpOpKind.socketRecv:
				{
					auto conn = cast(GenericSocket)retention.owner;
					enforce(conn !is null, "IOCP socket completion owner mismatch");
					iocpOnRecvComplete(conn, bytes, status);
					break;
				}
				case IocpOpKind.socketRecvFrom:
				{
					auto conn = cast(GenericSocket)retention.owner;
					enforce(conn !is null, "IOCP datagram completion owner mismatch");
					iocpOnRecvFromComplete(conn, bytes, status);
					break;
				}
				case IocpOpKind.socketSend:
				{
					auto conn = cast(GenericSocket)retention.owner;
					enforce(conn !is null, "IOCP send completion owner mismatch");
					iocpOnSendComplete(conn, bytes, status);
					break;
				}
				case IocpOpKind.socketAccept:
				{
					auto conn = cast(GenericSocket)retention.owner;
					enforce(conn !is null, "IOCP accept completion owner mismatch");
					iocpOnAcceptComplete(conn, bytes, status);
					break;
				}
				case IocpOpKind.socketConnect:
				{
					auto conn = cast(GenericSocket)retention.owner;
					enforce(conn !is null, "IOCP connect completion owner mismatch");
					iocpOnConnectComplete(conn, bytes, status);
					break;
				}
				case IocpOpKind.pipeRead:
				case IocpOpKind.pipeWrite:
				case IocpOpKind.pipeConnect:
				case IocpOpKind.dirChange:
				{
					auto p = cast(IocpParticipant)retention.owner;
					enforce(p !is null, "IOCP participant completion owner mismatch");
					p.iocpOnComplete(op, bytes, status);
					break;
				}
				case IocpOpKind.processExit:
				case IocpOpKind.userPost:
				{
					enforce(false, "non-null IOCP completion used a null-post operation kind");
					break;
				}
			}
		}
	}

	/// Interface for non-socket participants of the IOCP loop
	/// (pipes, process-exit waiters, future extensions).
	package(ae) interface IocpParticipant
	{
		/// Returns true iff this participant has work that should keep
		/// the event loop alive (i.e. should NOT exit if only daemon
		/// sockets remain). Same role as `notifyRead && !daemonRead`.
		bool iocpHasNonDaemonWork();

		/// Dispatched when an OVERLAPPED owned by this participant completes.
		void iocpOnComplete(IocpOp* op, DWORD bytes, uint status);

		/// Dispatched when a PostQueuedCompletionStatus(port, bytes, key, NULL)
		/// arrives where `key == cast(ULONG_PTR)cast(void*)this` and
		/// `lpOverlapped == null`.
		void iocpUserPost(DWORD bytes);
	}

	// ---- Per-socket completion handlers ---------------------------------

	private void iocpOnRecvComplete(GenericSocket conn, DWORD bytes, uint status)
	{
		debug (ASOCKETS) stderr.writefln("[iocp] recv complete: %s bytes=%d status=0x%X",
			conn, bytes, status);

		// Mark "no recv pending" so notifyRead setter can re-arm if needed.
		conn._iocpRecvPending = false;

		if (status == ERROR_OPERATION_ABORTED || conn.socket is null)
		{
			// Socket was closed; ignore.
			return;
		}

		if (status != 0)
			return conn.onError("recv() error: " ~ formatSocketError(cast(int)status));

		if (bytes == 0 && !conn.notifyRead)
			return;

		// Pretend the socket is "level-readable" and let onReadable() do
		// its thing: it will call doReceive() -> recv(), which returns
		// data already buffered by the kernel.
		conn.onReadable();

		// Re-arm if still interested.
		if (conn.socket !is null && conn.notifyRead && !conn._iocpRecvPending)
			conn._iocpArmRecv();
	}

	private void iocpOnRecvFromComplete(GenericSocket conn, DWORD bytes, uint status)
	{
		debug (ASOCKETS) stderr.writefln("[iocp] recvfrom complete: %s bytes=%d status=0x%X",
			conn, bytes, status);

		conn._iocpRecvPending = false;

		if (status == ERROR_OPERATION_ABORTED)
			return;

		if (status == 0)
		{
			// Stash the datagram bytes; doReceive will consume them.
			conn._iocpDgramData = conn._iocpDgramBuf[0 .. bytes];
		}
		// On non-zero status: stash stays null; onReadable/doReceive will
		// call conn.receive() which will surface the error naturally.

		conn.onReadable();

		conn._iocpDgramData = null; // clear stash in case doReceive didn't run

		// Re-arm if still interested.
		if (conn.socket !is null && conn.notifyRead && !conn._iocpRecvPending)
			conn._iocpArmRecv();
	}

	private void iocpOnSendComplete(GenericSocket conn, DWORD bytes, uint status)
	{
		debug (ASOCKETS) stderr.writefln("[iocp] send complete: %s bytes=%d status=0x%X",
			conn, bytes, status);

		// Release our hold on the in-flight buffer.
		conn._iocpSendBuffer = null;

		if (status == ERROR_OPERATION_ABORTED)
			return;

		if (conn.socket is null) return;

		if (status != 0)
			return conn.onError("send() error: " ~ formatSocketError(cast(int)status));

		// If the user wants more writes and queue has data, drive another
		// onWritable round.
		if (conn.notifyWrite)
		{
			conn.onWritable();
			// onWritable will updateFlags() which clears notifyWrite if
			// queue empty.
		}
	}

	private void iocpOnAcceptComplete(GenericSocket conn, DWORD bytes, uint status)
	{
		debug (ASOCKETS) stderr.writefln("[iocp] accept complete: %s status=0x%X", conn, status);

		conn._iocpAcceptOp.inFlight = false;

		if (status == ERROR_OPERATION_ABORTED || conn.socket is null)
		{
			// Listener closed; discard the candidate socket.
			if (conn._iocpCandidateSocket != c_socks.INVALID_SOCKET)
			{
				c_socks.closesocket(conn._iocpCandidateSocket);
				conn._iocpCandidateSocket = c_socks.INVALID_SOCKET;
			}
			return;
		}

		if (status != 0)
		{
			// Accept failed (e.g. peer reset before accept completed).
			if (conn._iocpCandidateSocket != c_socks.INVALID_SOCKET)
			{
				c_socks.closesocket(conn._iocpCandidateSocket);
				conn._iocpCandidateSocket = c_socks.INVALID_SOCKET;
			}
			// Re-arm so the listener keeps working.
			if (conn.socket !is null && conn.notifyRead)
				conn._iocpArmAccept();
			return;
		}

		// SO_UPDATE_ACCEPT_CONTEXT lets the accepted socket inherit the
		// listener's properties (required for getpeername, shutdown, etc.).
		auto listenHandle = cast(size_t)conn.socket.handle;
		c_socks.setsockopt(conn._iocpCandidateSocket,
			c_socks.SOL_SOCKET,
			SO_UPDATE_ACCEPT_CONTEXT,
			cast(const(void)*)&listenHandle, cast(c_socks.socklen_t)listenHandle.sizeof);

		// Extract the remote address from the AcceptEx output buffer.
		c_socks.sockaddr* localAddr, remoteAddr;
		int localLen = 0, remoteLen = 0;
		GetAcceptExSockaddrs(
			conn._iocpAcceptBuf.ptr,
			0,
			ACCEPT_ADDR_SIZE,
			ACCEPT_ADDR_SIZE,
			&localAddr, &localLen,
			&remoteAddr, &remoteLen);

		auto peerAddress = new UnknownAddressReference(
			cast(const(c_socks.sockaddr)*)remoteAddr, remoteLen);

		// Hand off to Listener.onReadable() via the IOCP accept-ready flag.
		conn._iocpAcceptedFd     = cast(socket_t)conn._iocpCandidateSocket;
		conn._iocpAcceptedPeer   = peerAddress;
		conn._iocpAcceptReady    = true;
		conn._iocpCandidateSocket = c_socks.INVALID_SOCKET;

		conn.onReadable();

		// Re-arm for the next incoming connection.
		if (conn.socket !is null && conn.notifyRead && !conn._iocpAcceptOp.inFlight)
			conn._iocpArmAccept();
	}

	private void iocpOnConnectComplete(GenericSocket conn, DWORD bytes, uint status)
	{
		debug (ASOCKETS) stderr.writefln("[iocp] connect complete: %s status=0x%X", conn, status);

		conn._iocpConnectOp.inFlight = false;

		// Closed during connect (disconnect()/closesocket cancelled the op).
		if (status == ERROR_OPERATION_ABORTED || conn.socket is null)
			return;

		auto sc = cast(StreamConnection)conn;
		assert(sc !is null, "ConnectEx owner must be a StreamConnection");

		if (status != 0)
			return sc.disconnect(formatSocketError(status), DisconnectType.error);

		// Make the socket usable for getpeername / shutdown / setsockopt etc.
		auto handle = cast(size_t)conn.socket.handle;
		c_socks.setsockopt(handle,
			c_socks.SOL_SOCKET, SO_UPDATE_CONNECT_CONTEXT,
			null, 0);

		sc._handleConnectComplete();
	}

	private void _iocpBindWildcard(Socket sock, AddressFamily family)
	{
		if (family == AddressFamily.INET)
		{
			c_socks.sockaddr_in addr;
			addr.sin_family = c_socks.AF_INET;
			addr.sin_port   = 0;
			addr.sin_addr.s_addr = 0;  // INADDR_ANY
			if (c_socks.bind(cast(c_socks.SOCKET)sock.handle,
					cast(const(c_socks.sockaddr)*)&addr,
					cast(c_socks.socklen_t)addr.sizeof) != 0)
				throw new SocketOSException("bind(INADDR_ANY) failed");
		}
		else
		if (family == AddressFamily.INET6)
		{
			c_socks.sockaddr_in6 addr;
			addr.sin6_family = c_socks.AF_INET6;
			addr.sin6_port   = 0;
			// sin6_addr is in6addr_any (zero-initialised by D struct init).
			if (c_socks.bind(cast(c_socks.SOCKET)sock.handle,
					cast(const(c_socks.sockaddr)*)&addr,
					cast(c_socks.socklen_t)addr.sizeof) != 0)
				throw new SocketOSException("bind(in6addr_any) failed");
		}
		else
			throw new SocketException("ConnectEx requires AF_INET or AF_INET6, got "
				~ family.to!string);
	}

	// Use UFCS for idle handlers (same shape as select/epoll).
	void addIdleHandler(ref SocketManager socketManager, void delegate() handler)
	{
		foreach (ref idleHandler; socketManager.idleHandlers)
			assert(handler !is idleHandler.dg);
		socketManager.idleHandlers ~= IdleHandler(handler);
	}

	void removeIdleHandler(alias pred=(a, b) => a is b, Args...)(ref SocketManager socketManager, Args args)
	{
		foreach (i, ref idleHandler; socketManager.idleHandlers)
			if (pred(idleHandler.dg, args))
			{
				import std.algorithm : remove;
				socketManager.idleHandlers = socketManager.idleHandlers.remove(i);
				return;
			}
		assert(false, "No such idle handler");
	}

	// ---- SocketMixin: per-socket IOCP state -----------------------------

	private mixin template SocketMixin()
	{
		// Per-direction IocpOps owned by this socket.
		// They live for the lifetime of the GenericSocket (no per-op alloc).
		IocpOp _iocpRecvOp;
		IocpOp _iocpSendOp;

		// In-flight send buffer (kept alive while WSASend pending).
		ubyte[] _iocpSendBuffer;

		bool _iocpRecvPending;
		bool _notifyRead, _notifyWrite;

		// ---- Datagram (UDP) recv state ------------------------------------
		// Set to true for datagram sockets so _iocpArmRecv uses WSARecvFrom
		// instead of the zero-byte WSARecv trick (unreliable on DGRAM sockets).
		bool _iocpIsDatagram;
		// 64 KB recv buffer for WSARecvFrom; allocated lazily on first arm.
		ubyte[] _iocpDgramBuf;
		// Stash filled by iocpOnRecvFromComplete before calling onReadable().
		// Consumed (and cleared) by ConnectionlessSocketConnection.doReceive.
		ubyte[] _iocpDgramData;
		// Source-address output for WSARecvFrom — must stay alive until completion.
		ubyte[128] _iocpFromAddr;  // SOCKADDR_STORAGE is 128 bytes on Windows
		int        _iocpFromAddrLen;
		// ------------------------------------------------------------------

		// ---- AcceptEx state (listener sockets only) -------------------
		// Set to true in Listener constructor so notifyRead arms AcceptEx
		// instead of WSARecv.
		bool     _iocpIsListener;
		IocpOp   _iocpAcceptOp;
		size_t   _iocpCandidateSocket = c_socks.INVALID_SOCKET;
		// AcceptEx output buffer: 2 * (sizeof(SOCKADDR_STORAGE)+16) = 288 bytes.
		ubyte[ACCEPT_ADDR_SIZE * 2] _iocpAcceptBuf;
		// Set by iocpOnAcceptComplete before calling onReadable(), cleared by
		// Listener.onReadable() after consuming.
		socket_t _iocpAcceptedFd;
		Address  _iocpAcceptedPeer;
		bool     _iocpAcceptReady;
		// ---------------------------------------------------------------

		// ---- ConnectEx state (client TCP sockets only) ----------------
		IocpOp          _iocpConnectOp;
		LPFN_CONNECTEX  _iocpConnectExFn;
		// Stable storage for the target sockaddr; ConnectEx requires the buffer
		// to remain valid until completion.  SOCKADDR_STORAGE is 128 bytes.
		ubyte[128] _iocpConnectAddrBuf;
		int        _iocpConnectAddrLen;
		// ---------------------------------------------------------------

		@property final bool notifyRead() const pure nothrow @nogc { return _notifyRead; }
		@property final bool notifyWrite() const pure nothrow @nogc { return _notifyWrite; }

		@property final void notifyRead(bool value)
		{
			bool was = _notifyRead;
			_notifyRead = value;
			if (value && !was && conn !is null)
			{
				if (_iocpIsListener)
				{
					if (!_iocpAcceptOp.inFlight)
						_iocpArmAccept();
				}
				else if (!_iocpRecvPending)
					_iocpArmRecv();
			}
			// If turned off, the in-flight WSARecv will eventually
			// complete (with ERROR_OPERATION_ABORTED if socket closed,
			// or just naturally with bytes — we ignore in onRecvComplete).
		}

		@property final void notifyWrite(bool value)
		{
			bool was = _notifyWrite;
			_notifyWrite = value;
			if (value && !was && conn !is null && _iocpSendBuffer is null)
				socketManager.kickWritable(this);
		}

		/// Don't block the process from exiting, even if the socket is ready to receive data.
		bool daemonRead;

		/// Don't block the process from exiting, even if the socket is ready to send data.
		bool daemonWrite;

		deprecated alias daemon = daemonRead;

		// Kind is set by the arm methods depending on socket type.
		private final void _iocpInitOps()
		{
			_iocpSendOp.kind = IocpOpKind.socketSend;
			_iocpConnectOp.kind  = IocpOpKind.socketConnect;
		}

		/// Arm a recv notification via IOCP.
		/// For stream sockets: posts a zero-byte WSARecv that completes when the
		/// kernel has data; the existing onReadable/doReceive/recv() flow is used.
		/// For datagram sockets: posts a real WSARecvFrom into a 64KB buffer;
		/// on completion the bytes are stashed for doReceive to return.
		final void _iocpArmRecv()
		{
			assert(conn !is null);
			_iocpInitOps();

			if (_iocpIsDatagram)
			{
				if (_iocpDgramBuf is null)
					_iocpDgramBuf = new ubyte[0x10000]; // 64 KB — max UDP datagram
				_iocpRecvOp.overlapped = OVERLAPPED.init;
				_iocpRecvOp.kind = IocpOpKind.socketRecvFrom;
				_iocpRecvPending = true;
				socketManager.retainIocpOp(&_iocpRecvOp, this);

				WSABUF buf;
				buf.len = cast(uint)_iocpDgramBuf.length;
				buf.buf = cast(char*)_iocpDgramBuf.ptr;
				DWORD flags = 0;
				DWORD recvd = 0;
				_iocpFromAddrLen = cast(int)_iocpFromAddr.sizeof;
				int rc = WSARecvFrom(conn.handle, &buf, 1, &recvd, &flags,
					cast(c_socks.sockaddr*)_iocpFromAddr.ptr, &_iocpFromAddrLen,
					&_iocpRecvOp.overlapped, null);
				if (rc == 0)
					return;
				auto err = WSAGetLastError();
				if (err == WSA_IO_PENDING)
					return;
				socketManager.rollbackIocpSubmission(&_iocpRecvOp, this);
				_iocpRecvPending = false;
				socketManager.kickWritable(this); // TODO: kickReadable would be cleaner
				return;
			}

			// Stream path: zero-byte WSARecv trick.
			_iocpRecvOp.overlapped = OVERLAPPED.init;
			_iocpRecvOp.kind = IocpOpKind.socketRecv;
			_iocpRecvPending = true;
			socketManager.retainIocpOp(&_iocpRecvOp, this);
			WSABUF buf;
			buf.len = 0;
			buf.buf = null;
			DWORD flags = 0;
			DWORD recvd = 0;
			int rc = WSARecv(conn.handle, &buf, 1, &recvd, &flags,
				&_iocpRecvOp.overlapped, null);
			if (rc == 0)
			{
				// Completed inline — completion will still be queued to
				// the IOCP because we didn't set FILE_SKIP_COMPLETION_PORT_ON_SUCCESS.
				return;
			}
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING)
				return;
			// Real error: we'll see it in onReadable when recv() is called.
			socketManager.rollbackIocpSubmission(&_iocpRecvOp, this);
			_iocpRecvPending = false;
			// Pretend readable so the connection sees the error.
			socketManager.kickWritable(this); // TODO: kickReadable would be cleaner
		}

		/// Post AcceptEx against a pre-created candidate socket so the IOCP
		/// port delivers a completion when a client connects.
		final void _iocpArmAccept()
		{
			assert(conn !is null);
			assert(_iocpIsListener);

			// Create the candidate socket with the same family/type/protocol
			// as the listener, with WSA_FLAG_OVERLAPPED.
			_iocpCandidateSocket = WSASocketW(
				cast(int)conn.addressFamily,
				cast(int)SocketType.STREAM,
				cast(int)ProtocolType.TCP,
				null, 0, WSA_FLAG_OVERLAPPED);
			if (_iocpCandidateSocket == c_socks.INVALID_SOCKET)
			{
				debug (ASOCKETS) stderr.writefln("[iocp] WSASocketW for AcceptEx failed: %d",
					WSAGetLastError());
				return;
			}

			_iocpAcceptOp.kind       = IocpOpKind.socketAccept;
			_iocpAcceptOp.overlapped = OVERLAPPED.init;
			_iocpAcceptOp.inFlight   = true;
			socketManager.retainIocpOp(&_iocpAcceptOp, this);

			DWORD bytesReceived = 0;
			BOOL ok = AcceptEx(
				cast(size_t)conn.handle,
				_iocpCandidateSocket,
				_iocpAcceptBuf.ptr,
				0,                 // dwReceiveDataLength = 0: no initial data
				ACCEPT_ADDR_SIZE,  // dwLocalAddressLength
				ACCEPT_ADDR_SIZE,  // dwRemoteAddressLength
				&bytesReceived,
				&_iocpAcceptOp.overlapped);

			if (ok)
				return;
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING)
				return;

			// Immediate error — clean up and bail.
			socketManager.rollbackIocpSubmission(&_iocpAcceptOp, this);
			_iocpAcceptOp.inFlight = false;
			c_socks.closesocket(_iocpCandidateSocket);
			_iocpCandidateSocket = c_socks.INVALID_SOCKET;
			debug (ASOCKETS) stderr.writefln("[iocp] AcceptEx failed: %d", err);
		}

		/// Post ConnectEx against the already-bound, IOCP-registered socket so the
		/// IOCP port delivers a completion when the TCP handshake finishes.
		/// The socket must already be bound (caller's responsibility —
		/// see SocketConnection.tryNextAddress).
		final void _iocpArmConnect(Address target)
		{
			assert(conn !is null);

			_iocpInitOps();
			_iocpConnectOp.overlapped = OVERLAPPED.init;

			// Resolve ConnectEx via WSAIoctl on first use for this socket.
			if (_iocpConnectExFn is null)
			{
				GUID guid = WSAID_CONNECTEX;
				DWORD fnBytes;
				int rc = WSAIoctl(
					cast(c_socks.SOCKET)conn.handle,
					SIO_GET_EXTENSION_FUNCTION_POINTER,
					&guid, cast(uint)guid.sizeof,
					&_iocpConnectExFn, cast(uint)_iocpConnectExFn.sizeof,
					&fnBytes,
					null, null);
				if (rc != 0 || _iocpConnectExFn is null)
				{
					auto err = WSAGetLastError();
					debug (ASOCKETS) stderr.writefln(
						"[iocp] WSAIoctl(ConnectEx fn ptr) failed: %d", err);
					_iocpConnectExFn = null;
					(cast(Connection)cast(Object)this).disconnect(
						formatSocketError(err), DisconnectType.error);
					return;
				}
			}

			// Stash the target sockaddr for the duration of the op.
			auto nameLen = target.nameLen;
			assert(nameLen <= _iocpConnectAddrBuf.length, "sockaddr too large");
			_iocpConnectAddrBuf[0 .. nameLen] = (cast(const(ubyte)*)target.name)[0 .. nameLen];
			_iocpConnectAddrLen = nameLen;
			_iocpConnectOp.inFlight = true;
			socketManager.retainIocpOp(&_iocpConnectOp, this);

			DWORD sent = 0;
			BOOL ok = _iocpConnectExFn(
				cast(size_t)conn.handle,
				cast(const(sockaddr)*)_iocpConnectAddrBuf.ptr,
				_iocpConnectAddrLen,
				null, 0,
				&sent,
				&_iocpConnectOp.overlapped);

			if (ok)
			{
				// Synchronous success — kernel still delivers IOCP completion.
				return;
			}

			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING)
				return;

			socketManager.rollbackIocpSubmission(&_iocpConnectOp, this);
			_iocpConnectOp.inFlight = false;
			debug (ASOCKETS) stderr.writefln("[iocp] ConnectEx failed: %d", err);
			(cast(Connection)cast(Object)this).disconnect(
				formatSocketError(err), DisconnectType.error);
		}

		/// Override Connection.doSend hook for IOCP: post overlapped WSASend.
		/// Returns buffer.length on success (claims all bytes accepted),
		/// Socket.ERROR with WSAEWOULDBLOCK if a send is already in flight.
		package final sizediff_t _iocpDoSend(scope const(void)[] buffer)
		{
			return _iocpDoSendVec((&buffer)[0 .. 1]);
		}

		/// Vectored variant: coalesce the buffers into the single in-flight
		/// send buffer and post one overlapped WSASend, instead of posting
		/// one op (and taking one completion round-trip) per buffer.
		package final sizediff_t _iocpDoSendVec(scope const(void)[][] buffers)
		{
			if (_iocpSendBuffer !is null)
			{
				_wsaSetLastError(WSAEWOULDBLOCK);
				return Socket.ERROR;
			}

			_iocpInitOps();

			size_t total = 0;
			foreach (buffer; buffers)
				total += buffer.length;

			// Hold a copy of the data so it outlives the in-flight op.
			auto sendBuffer = new ubyte[total];
			size_t pos = 0;
			foreach (buffer; buffers)
			{
				sendBuffer[pos .. pos + buffer.length] = (cast(const(ubyte)*)buffer.ptr)[0 .. buffer.length];
				pos += buffer.length;
			}
			_iocpSendBuffer = sendBuffer;
			_iocpSendOp.overlapped = OVERLAPPED.init;
			socketManager.retainIocpOp(&_iocpSendOp, this);

			WSABUF wb;
			wb.len = cast(uint)_iocpSendBuffer.length;
			wb.buf = cast(char*)_iocpSendBuffer.ptr;
			DWORD sent = 0;
			int rc = WSASend(conn.handle, &wb, 1, &sent, 0,
				&_iocpSendOp.overlapped, null);
			if (rc == 0)
			{
				return cast(sizediff_t)total;
			}
			auto err = WSAGetLastError();
			if (err == WSA_IO_PENDING)
				return cast(sizediff_t)total;

			// Synchronous failure.
			socketManager.rollbackIocpSubmission(&_iocpSendOp, this);
			_iocpSendBuffer = null;
			_wsaSetLastError(err);
			return Socket.ERROR;
		}
	}

	// -----------------------------------------------------------------------
	// WindowsPipeConnection: full IConnection implementation over a Windows
	// pipe HANDLE (named pipe or anonymous, opened with FILE_FLAG_OVERLAPPED).
	// -----------------------------------------------------------------------

	/// Full IConnection implementation for Windows pipe HANDLEs.
	/// The caller is responsible for opening the HANDLE with
	/// FILE_FLAG_OVERLAPPED (e.g. via CreateNamedPipeW + CreateFileW).
	public class WindowsPipeConnection : IocpParticipant, IConnection
	{
		// --- State machine ---------------------------------------------------

		private ConnectionState _state = ConnectionState.disconnected;

		override @property ConnectionState state() { return _state; }

		// --- Send queue (mirrors Connection) ---------------------------------

		private DataVec[IConnection.MAX_PRIORITY+1] _outQueue;
		private ubyte[] _writeBuf;       // in-flight bytes (stable for WriteFile duration)
		private bool    _writePending;
		private bool    _drainScheduled; // onNextTick drain is pending

		// Saved reason/type for a deferred disconnect(requested) while writing.
		private string         _pendingDisconnectReason;
		private DisconnectType _pendingDisconnectType;

		// --- HANDLE & IOCP ops -----------------------------------------------

		private HANDLE _handle;
		private bool   _ownHandle;
		private IocpOp _readOp;
		private IocpOp _writeOp;

		// --- Read buffer -----------------------------------------------------

		private ubyte[4096] _readBuf;
		private bool        _readPending;

		// --- Callbacks -------------------------------------------------------

		private ConnectHandler       _connectHandler;
		private ReadDataHandler      _readDataHandler;
		private DisconnectHandler    _disconnectHandler;
		private BufferFlushedHandler _bufferFlushedHandler;

		// --- Construction ----------------------------------------------------

		this(HANDLE h, bool ownHandle = true, bool iocpAlreadyRegistered = false)
		{
			_handle = h;
			_ownHandle = ownHandle;
			_readOp.kind = IocpOpKind.pipeRead;
			_writeOp.kind = IocpOpKind.pipeWrite;
			if (!iocpAlreadyRegistered)
			{
				auto port = socketManager.getIocpPort();
				auto rc = CreateIoCompletionPort(h, port, cast(ULONG_PTR)cast(void*)this, 0);
				assert(rc == port, "CreateIoCompletionPort(pipe) failed");
			}
			socketManager.addParticipant(this);
			_state = ConnectionState.connected;
		}

		/// Create a WindowsPipeConnection without a HANDLE. Starts in
		/// `disconnected` state. Use `connect(pipeName)` to open a
		/// named-pipe client connection.
		this()
		{
			_readOp.kind = IocpOpKind.pipeRead;
			_writeOp.kind = IocpOpKind.pipeWrite;
		}

		/// Open a named-pipe client connection. Must be called on a
		/// WindowsPipeConnection constructed with the no-arg ctor.
		void connect(string pipeName, SECURITY_ATTRIBUTES* sa = null)
		{
			import std.utf : toUTF16z;
			import std.conv : to;

			assert(_state == ConnectionState.disconnected,
			       "connect on a " ~ _state.to!string ~ " pipe");
			assert(!socketManager.hasIocpOps(this),
				"previous IOCP generation has not drained");
			_state = ConnectionState.connecting;

			auto h = CreateFileW(pipeName.toUTF16z,
				GENERIC_READ | GENERIC_WRITE,
				0,                  // dwShareMode
				sa,                 // lpSecurityAttributes
				OPEN_EXISTING,
				FILE_FLAG_OVERLAPPED,
				null);              // hTemplateFile
			if (h == INVALID_HANDLE_VALUE)
			{
				auto err = GetLastError();
				onNextTick(socketManager, {
					_state = ConnectionState.disconnected;
					if (_disconnectHandler)
						_disconnectHandler(
							"CreateFileW(" ~ pipeName ~ ") failed: " ~ err.to!string,
							DisconnectType.error);
				});
				return;
			}

			_handle = h;
			_ownHandle = true;
			auto port = socketManager.getIocpPort();
			auto rc = CreateIoCompletionPort(h, port, cast(ULONG_PTR)cast(void*)this, 0);
			assert(rc == port, "CreateIoCompletionPort(pipe) failed");
			socketManager.addParticipant(this);
			_state = ConnectionState.connected;

			onNextTick(socketManager, {
				if (_connectHandler)
					_connectHandler();
				if (_readDataHandler && _state == ConnectionState.connected
					&& !_readPending)
					_armRead();
			});
		}

		final HANDLE handle() pure nothrow @nogc { return _handle; }

		/// Kept for backward compatibility; setting handleReadData now starts
		/// reading automatically.
		final void startReading()
		{
			if (_readDataHandler && _state == ConnectionState.connected && !_readPending)
				_armRead();
		}

		// --- IConnection -----------------------------------------------------

		override void send(scope Data[] data, int priority = IConnection.DEFAULT_PRIORITY)
		{
			assert(_state == ConnectionState.connected,
			       "send on a " ~ _state.to!string ~ " pipe");
			_outQueue[priority] ~= data;
			if (!_writePending && !_drainScheduled)
			{
				// Defer drain to next tick so all sends in the same handler
				// are queued before we pick the highest-priority chunk.
				_drainScheduled = true;
				onNextTick(socketManager, () {
					_drainScheduled = false;
					if (!_writePending && _state != ConnectionState.disconnected)
						_drainQueue();
				});
			}
		}

		alias send = IConnection.send;

		override void disconnect(
			string reason = IConnection.defaultDisconnectReason,
			DisconnectType type = DisconnectType.requested)
		{
			assert(_state.disconnectable,
			       "disconnect on a " ~ _state.to!string ~ " pipe");
			if ((_writePending || _drainScheduled) && type == DisconnectType.requested)
			{
				// Flush in-flight write and any queued sends, then close.
				_state = ConnectionState.disconnecting;
				_pendingDisconnectReason = reason;
				_pendingDisconnectType   = type;
				if (_disconnectHandler)
					_disconnectHandler(reason, type);
				return;
			}
			// Drop remaining queue and close immediately.
			_discardQueues();
			_drainScheduled = false;
			_doClose(reason, type);
		}

		@property override void handleConnect(ConnectHandler value)
		{
			_connectHandler = value;
		}

		@property override void handleReadData(ReadDataHandler value)
		{
			_readDataHandler = value;
			if (value && _state == ConnectionState.connected && !_readPending)
				_armRead();
		}

		@property override void handleDisconnect(DisconnectHandler value)
		{
			_disconnectHandler = value;
		}

		@property override void handleBufferFlushed(BufferFlushedHandler value)
		{
			_bufferFlushedHandler = value;
		}

		// --- IocpParticipant -------------------------------------------------

		override bool iocpHasNonDaemonWork()
		{
			if (_state == ConnectionState.disconnected) return false;
			if (_readDataHandler !is null) return true;
			if (_writePending || _drainScheduled) return true;
			foreach (ref q; _outQueue)
				if (q.length) return true;
			return false;
		}

		override void iocpOnComplete(IocpOp* op, DWORD bytes, uint status)
		{
			if (op is &_readOp)
			{
				_readPending = false;
				if (status == ERROR_OPERATION_ABORTED || _state == ConnectionState.disconnected)
					return;
				if (status == ERROR_BROKEN_PIPE || status == ERROR_HANDLE_EOF
				    || status == ERROR_PIPE_NOT_CONNECTED || bytes == 0)
				{
					_doClose("EOF", DisconnectType.graceful);
					return;
				}
				if (status != 0)
				{
					_doClose("ReadFile failed", DisconnectType.error);
					return;
				}
				if (_readDataHandler)
					_readDataHandler(Data(_readBuf[0 .. bytes].idup));
				if (_readDataHandler && _state == ConnectionState.connected && !_readPending)
					_armRead();
			}
			else if (op is &_writeOp)
			{
				_writePending = false;
				if (status == ERROR_OPERATION_ABORTED || _state == ConnectionState.disconnected)
				{
					_writeBuf = null;
					return;
				}
				if (status != 0)
				{
					_writeBuf = null;
					_doClose("WriteFile failed", DisconnectType.error);
					return;
				}
				if (bytes < _writeBuf.length)
				{
					// Partial write — retry the remainder in-place.
					_writeBuf = _writeBuf[bytes .. $];
					_postWrite(_writeBuf);
					return;
				}
				_writeBuf = null;
				_drainQueue();
			}
		}

		override void iocpUserPost(DWORD bytes) {}

		// --- Internals -------------------------------------------------------

		private void _armRead()
		{
			_readOp.overlapped = OVERLAPPED.init;
			_readOp.kind = IocpOpKind.pipeRead;
			_readPending = true;
			socketManager.retainIocpOp(&_readOp, this);
			DWORD got = 0;
			BOOL ok = ReadFile(_handle, _readBuf.ptr, cast(DWORD)_readBuf.length,
				&got, &_readOp.overlapped);
			if (ok)
				return;
			auto err = GetLastError();
			if (err == ERROR_IO_PENDING)
				return;
			socketManager.rollbackIocpSubmission(&_readOp, this);
			_readPending = false;
			if (err == ERROR_BROKEN_PIPE || err == ERROR_HANDLE_EOF
			    || err == ERROR_PIPE_NOT_CONNECTED)
			{
				_doClose("EOF", DisconnectType.graceful);
				return;
			}
			_doClose("ReadFile failed", DisconnectType.error);
		}

		private void _drainQueue()
		{
			assert(!_writePending);
			if (_state == ConnectionState.disconnected) return;

			foreach (ref queue; _outQueue)
			{
				while (queue.length)
				{
					if (queue.front.empty)
					{
						queue.popFront();
						if (queue.length == 0) queue = null;
						continue;
					}
					_writeBuf = cast(ubyte[])queue.front.unsafeContents.dup;
					queue.popFront();
					if (queue.length == 0) queue = null;
					_postWrite(_writeBuf);
					return;
				}
			}

			// All queues empty.
			if (_bufferFlushedHandler)
				_bufferFlushedHandler();
			if (_state == ConnectionState.disconnecting)
				_doClose(_pendingDisconnectReason, _pendingDisconnectType);
		}

		private void _postWrite(ubyte[] buf)
		{
			_writeOp.overlapped = OVERLAPPED.init;
			_writeOp.kind = IocpOpKind.pipeWrite;
			_writePending = true;
			socketManager.retainIocpOp(&_writeOp, this);
			DWORD written = 0;
			BOOL ok = WriteFile(_handle, buf.ptr, cast(DWORD)buf.length,
				&written, &_writeOp.overlapped);
			if (ok)
				return;
			auto err = GetLastError();
			if (err == ERROR_IO_PENDING)
				return;
			socketManager.rollbackIocpSubmission(&_writeOp, this);
			_writePending = false;
			_writeBuf = null;
			_doClose("WriteFile failed", DisconnectType.error);
		}

		private void _discardQueues()
		{
			foreach (ref q; _outQueue)
				q = DataVec.init;
		}

		private void _doClose(string reason, DisconnectType type)
		{
			if (_state == ConnectionState.disconnected) return;
			// If we were already disconnecting (deferred flush path), the
			// handler was already called when disconnect() set the state;
			// don't call it a second time (matches Connection semantics).
			bool callHandler = _state != ConnectionState.disconnecting;
			_state = ConnectionState.disconnected;
			_discardQueues();

			socketManager.retireIocpOps(this);
			if (_handle !is null)
			{
				if (_readPending)
				{
					if (!CancelIoEx(_handle, &_readOp.overlapped))
					{
						auto err = GetLastError();
						enforce(err == ERROR_NOT_FOUND, "CancelIoEx(read) failed");
					}
				}
				if (_writePending)
				{
					if (!CancelIoEx(_handle, &_writeOp.overlapped))
					{
						auto err = GetLastError();
						enforce(err == ERROR_NOT_FOUND, "CancelIoEx(write) failed");
					}
				}
				if (_ownHandle)
				{
					CloseHandle(_handle);
					_handle = null;
				}
			}

			socketManager.removeParticipant(this);

			if (callHandler && _disconnectHandler)
				_disconnectHandler(reason, type);
		}
	}

	// -----------------------------------------------------------------------
	// WindowsProcessExitWaiter
	// -----------------------------------------------------------------------

	/// Watches a Windows process handle for exit and delivers the exit code
	/// to a user callback on the IOCP event-loop thread.
	public class WindowsProcessExitWaiter : IocpParticipant
	{
		private HANDLE _processHandle;  // owned copy; closed after callback fires
		private HANDLE _waitHandle;
		private HANDLE _iocpPort;
		private void delegate(int) _callback;

		this(HANDLE processHandle, void delegate(int) callback)
		{
			BOOL ok = DuplicateHandle(
				GetCurrentProcess(), processHandle,
				GetCurrentProcess(), &_processHandle,
				SYNCHRONIZE | PROCESS_QUERY_INFORMATION, FALSE, 0);
			assert(ok, "DuplicateHandle failed");

			_iocpPort = socketManager.getIocpPort();
			_callback  = callback;

			// Add to participants before registering the wait so the GC
			// root exists before the thread-pool thread can use the pointer.
			socketManager.addParticipant(this);

			ok = RegisterWaitForSingleObject(
				&_waitHandle, _processHandle,
				cast(WAITORTIMERCALLBACK)&_exitCallback,
				cast(void*)this,
				INFINITE,
				WT_EXECUTEONLYONCE);
			assert(ok, "RegisterWaitForSingleObject failed");
		}

		// Runs on a Win32 thread-pool thread; must not touch GC-managed heap.
		// Just signals the loop thread; exit code is retrieved on the loop thread.
		private static extern(Windows) void _exitCallback(void* ctx, bool) nothrow @nogc
		{
			auto self = cast(WindowsProcessExitWaiter)ctx;
			PostQueuedCompletionStatus(self._iocpPort, 0,
				cast(ULONG_PTR)cast(void*)cast(Object)self, null);
		}

		override bool iocpHasNonDaemonWork() { return _callback !is null; }
		override void iocpOnComplete(IocpOp*, DWORD, uint) { assert(false); }

		override void iocpUserPost(DWORD)
		{
			DWORD code = 0;
			GetExitCodeProcess(_processHandle, &code);

			auto cb = _callback;
			_callback = null;

			socketManager.removeParticipant(this);
			UnregisterWaitEx(_waitHandle, null);  // null = don't wait for in-flight callbacks
			_waitHandle = null;
			CloseHandle(_processHandle);
			_processHandle = null;

			if (cb)
				cb(cast(int)code);
		}
	}

	// -----------------------------------------------------------------------
	// NamedPipeServer
	// -----------------------------------------------------------------------

	/// Listening side of a Windows named-pipe server. Produces fresh
	/// WindowsPipeConnection instances on each accept.
	///
	/// v1 keeps one unconnected pipe instance armed at a time. Between
	/// _onConnected() firing handleAccept and the next _armConnect(), the
	/// server is briefly un-listening (clients get ERROR_PIPE_BUSY and
	/// must retry). Pre-arming N instances is a future-work item.
	public class NamedPipeServer : IocpParticipant
	{
		string pipeName;
		SECURITY_ATTRIBUTES* securityAttributes;
		DWORD outBufferSize = 65536;
		DWORD inBufferSize  = 65536;

		void delegate(WindowsPipeConnection incoming) handleAccept;
		void delegate() handleClose;

		private HANDLE _pendingHandle;
		private IocpOp _connectOp;
		private bool   _pending;
		private bool   _listening;

		this(string pipeName)
		{
			this.pipeName = pipeName;
			_connectOp.kind  = IocpOpKind.pipeConnect;
		}

		@property bool isListening() { return _listening; }

		void listen()
		{
			import std.utf : toUTF16z;
			import std.conv : to;

			assert(!_listening, "NamedPipeServer.listen called twice");
			assert(!socketManager.hasIocpOps(this),
				"previous IOCP generation has not drained");

			_pendingHandle = CreateNamedPipeW(pipeName.toUTF16z,
				PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
				PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT
				    | PIPE_REJECT_REMOTE_CLIENTS,
				PIPE_UNLIMITED_INSTANCES,
				outBufferSize, inBufferSize, 0,
				securityAttributes);
			if (_pendingHandle == INVALID_HANDLE_VALUE)
				throw new Exception(
					"CreateNamedPipeW(" ~ pipeName ~ ") failed: "
					~ GetLastError().to!string);

			auto port = socketManager.getIocpPort();
			auto rc = CreateIoCompletionPort(_pendingHandle, port,
				cast(ULONG_PTR)cast(void*)this, 0);
			assert(rc == port, "CreateIoCompletionPort(pipe-server) failed");

			socketManager.addParticipant(this);
			_listening = true;
			_armConnect();
		}

		void close()
		{
			if (!_listening) return;
			_listening = false;

			if (_pending)
			{
				// Don't removeParticipant here — wait for the abort to
				// complete in iocpOnComplete to ensure the HANDLE is
				// closed and the loop drains.
				socketManager.retireIocpOps(this);
				if (!CancelIoEx(_pendingHandle, &_connectOp.overlapped))
				{
					auto err = GetLastError();
					enforce(err == ERROR_NOT_FOUND, "CancelIoEx(pipe connect) failed");
				}
				return;
			}

			if (_pendingHandle !is null
			    && _pendingHandle != INVALID_HANDLE_VALUE)
			{
				CloseHandle(_pendingHandle);
				_pendingHandle = null;
			}
			socketManager.removeParticipant(this);
			if (handleClose) handleClose();
		}

		private void _armConnect()
		{
			import std.conv : to;
			_connectOp.overlapped = OVERLAPPED.init;
			_connectOp.kind = IocpOpKind.pipeConnect;
			_pending = true;
			socketManager.retainIocpOp(&_connectOp, this);
			BOOL ok = ConnectNamedPipe(_pendingHandle, &_connectOp.overlapped);
			if (ok)
				return;
			auto err = GetLastError();
			switch (err)
			{
				case ERROR_IO_PENDING:
					return;
				case ERROR_PIPE_CONNECTED:
					_connectOp.overlapped = OVERLAPPED.init;
					if (!PostQueuedCompletionStatus(socketManager.getIocpPort(), 0,
						cast(ULONG_PTR)cast(void*)this, &_connectOp.overlapped))
					{
						auto postErr = GetLastError();
						socketManager.rollbackIocpSubmission(&_connectOp, this);
						_pending = false;
						throw new Exception(
							"ConnectNamedPipe failed on " ~ pipeName
							~ ": " ~ postErr.to!string);
					}
					return;
				default:
					socketManager.rollbackIocpSubmission(&_connectOp, this);
					_pending = false;
					throw new Exception(
						"ConnectNamedPipe failed on " ~ pipeName
						~ ": " ~ err.to!string);
			}
		}

		private void _onConnected()
		{
			import std.utf : toUTF16z;
			import std.conv : to;

			auto h = _pendingHandle;
			_pendingHandle = null;

			// The handle is already associated with the IOCP port (done in
			// listen()/_onConnected's re-arm). Skip re-registration.
			auto conn = new WindowsPipeConnection(h, true, true);

			if (handleAccept)
				handleAccept(conn);
			else
				conn.disconnect();

			if (_listening && _pendingHandle is null)
			{
				_pendingHandle = CreateNamedPipeW(pipeName.toUTF16z,
					PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
					PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT
					    | PIPE_REJECT_REMOTE_CLIENTS,
					PIPE_UNLIMITED_INSTANCES,
					outBufferSize, inBufferSize, 0,
					securityAttributes);
				if (_pendingHandle == INVALID_HANDLE_VALUE)
				{
					_listening = false;
					throw new Exception(
						"CreateNamedPipeW(" ~ pipeName ~ ") failed: "
						~ GetLastError().to!string);
				}
				auto port = socketManager.getIocpPort();
				auto rc = CreateIoCompletionPort(_pendingHandle, port,
					cast(ULONG_PTR)cast(void*)this, 0);
				assert(rc == port, "CreateIoCompletionPort(pipe-server) failed");

				_armConnect();
			}
		}

		override void iocpOnComplete(IocpOp* op, DWORD bytes, uint status)
		{
			assert(op is &_connectOp);
			_pending = false;

			if (status != 0)
			{
				// status is a normalized Win32 error. ERROR_OPERATION_ABORTED
				// arrives when close() triggered CancelIoEx; other non-zero
				// statuses indicate unexpected errors. Either way, clean up.
				_listening = false;
				if (_pendingHandle !is null
				    && _pendingHandle != INVALID_HANDLE_VALUE)
				{
					CloseHandle(_pendingHandle);
					_pendingHandle = null;
				}
				socketManager.removeParticipant(this);
				if (handleClose) handleClose();
				return;
			}

			_onConnected();
		}

		override bool iocpHasNonDaemonWork()
		{
			if (_pending) return true;
			return _listening && handleAccept !is null;
		}

		override void iocpUserPost(DWORD)
		{
			assert(false, "NamedPipeServer received unexpected userPost");
		}
	}

	// -----------------------------------------------------------------------
	// WindowsPipeConnection unittests
	// -----------------------------------------------------------------------

	debug(ae_unittest) unittest
	{
		// Named-pipe pair helper used by all three subtests below.
		import std.utf    : toUTF16z;
		import std.format : format;

		enum DWORD PIPE_ACCESS_DUPLEX_         = 0x00000003;
		enum DWORD FILE_FLAG_OVERLAPPED_       = 0x40000000;
		enum DWORD PIPE_TYPE_BYTE_             = 0x00000000;
		enum DWORD PIPE_READMODE_BYTE_         = 0x00000000;
		enum DWORD PIPE_WAIT_                  = 0x00000000;
		enum DWORD PIPE_UNLIMITED_INSTANCES_   = 255;

		int pipeSeq;

		// Returns the server HANDLE; fills `clientOut` with the client HANDLE.
		HANDLE makePipePair(out HANDLE clientOut)
		{
			auto name = format(`\\.\pipe\ae-iocp-wpc-%s-%s`,
			                   GetCurrentProcessId(), pipeSeq++).toUTF16z;
			auto srv = CreateNamedPipeW(name,
				PIPE_ACCESS_DUPLEX_ | FILE_FLAG_OVERLAPPED_,
				PIPE_TYPE_BYTE_ | PIPE_READMODE_BYTE_ | PIPE_WAIT_
				    | PIPE_REJECT_REMOTE_CLIENTS,
				PIPE_UNLIMITED_INSTANCES_, 65536, 65536, 0, null);
			assert(srv != INVALID_HANDLE_VALUE, "CreateNamedPipeW failed");
			auto cli = CreateFileW(name,
				GENERIC_READ | GENERIC_WRITE, 0, null,
				OPEN_EXISTING, FILE_FLAG_OVERLAPPED_, null);
			assert(cli != INVALID_HANDLE_VALUE, "CreateFileW failed");
			clientOut = cli;
			return srv;
		}

		// --- Test 1: priority-queue ordering ---------------------------------
		// Queue sends at priorities 3, 1, 2 before entering the loop;
		// verify the receiver sees them in priority order: 1, 2, 3.
		{
			HANDLE cli;
			auto srv = makePipePair(cli);
			auto sender   = new WindowsPipeConnection(cli);
			auto receiver = new WindowsPipeConnection(srv);

			string received;
			bool senderDone, receiverDone;

			receiver.handleReadData = (Data data) {
				received ~= cast(string)data.unsafeContents.idup;
			};
			receiver.handleDisconnect = (string, DisconnectType) {
				receiverDone = true;
			};
			sender.handleDisconnect = (string, DisconnectType) {
				senderDone = true;
			};
			sender.handleBufferFlushed = () { sender.disconnect("done"); };

			sender.send(Data(cast(immutable ubyte[])"low"),    3);
			sender.send(Data(cast(immutable ubyte[])"high"),   1);
			sender.send(Data(cast(immutable ubyte[])"medium"), 2);

			socketManager.loop();

			assert(received == "highmediumlow",
			       "priority ordering wrong: got `" ~ received ~ "`");
			assert(senderDone,   "sender never disconnected");
			assert(receiverDone, "receiver never disconnected");
		}

		// --- Test 2: multiple queued sends arrive in order -------------------
		{
			HANDLE cli;
			auto srv = makePipePair(cli);
			auto sender   = new WindowsPipeConnection(cli);
			auto receiver = new WindowsPipeConnection(srv);

			string received;
			bool receiverDone;

			receiver.handleReadData = (Data data) {
				received ~= cast(string)data.unsafeContents.idup;
			};
			receiver.handleDisconnect = (string, DisconnectType) {
				receiverDone = true;
			};
			sender.handleDisconnect = (string, DisconnectType) {};
			sender.handleBufferFlushed = () { sender.disconnect("done"); };

			sender.send(Data(cast(immutable ubyte[])"aaa"));
			sender.send(Data(cast(immutable ubyte[])"bbb"));
			sender.send(Data(cast(immutable ubyte[])"ccc"));

			socketManager.loop();

			assert(received == "aaabbbccc",
			       "queued-sends ordering wrong: got `" ~ received ~ "`");
			assert(receiverDone, "receiver never disconnected");
		}

		// --- Test 3: disconnect(requested) while writes are queued -----------
		// All queued data must be flushed to the receiver before the sender
		// closes, and both sides must reach the disconnected state.
		{
			HANDLE cli;
			auto srv = makePipePair(cli);
			auto sender   = new WindowsPipeConnection(cli);
			auto receiver = new WindowsPipeConnection(srv);

			string received;
			bool senderDone, receiverDone;

			receiver.handleReadData = (Data data) {
				received ~= cast(string)data.unsafeContents.idup;
			};
			receiver.handleDisconnect = (string, DisconnectType) {
				receiverDone = true;
			};
			sender.handleDisconnect = (string, DisconnectType) {
				senderDone = true;
			};

			sender.send(Data(cast(immutable ubyte[])"x"));
			sender.send(Data(cast(immutable ubyte[])"y"));
			sender.send(Data(cast(immutable ubyte[])"z"));
			// disconnect(requested) while drain is scheduled but not yet started.
			sender.disconnect("flush-test", DisconnectType.requested);
			assert(sender.state == ConnectionState.disconnecting
			    || sender.state == ConnectionState.disconnected,
			       "expected disconnecting or disconnected after flush-disconnect");

			socketManager.loop();

			assert(received == "xyz",
			       "mid-send disconnect did not flush data: got `" ~ received ~ "`");
			assert(senderDone,   "sender never disconnected");
			assert(receiverDone, "receiver never disconnected");
		}
	}

	// -----------------------------------------------------------------------
	// NamedPipeServer unittests
	// -----------------------------------------------------------------------

	debug(ae_unittest) version (Windows) unittest
	{
		import std.format : format;

		static int seq;

		string makeName()
		{
			return format(`\\.\pipe\ae-iocp-nps-%s-%s`,
			              GetCurrentProcessId(), seq++);
		}

		// --- Subtest 1: deferred-connect round-trip --------------------------
		{
			auto name = makeName();
			auto server = new NamedPipeServer(name);

			WindowsPipeConnection acceptedConn;
			bool clientConnectFired, gotByteOnServer, gotByteOnClient;
			bool clientDisconnected, serverDisconnected;

			server.handleAccept = (WindowsPipeConnection inc) {
				acceptedConn = inc;
				inc.handleReadData = (Data data) {
					gotByteOnServer = true;
					assert(cast(string)data.unsafeContents.idup == "X");
					inc.send(Data(cast(immutable ubyte[])"Y"));
				};
				inc.handleBufferFlushed = () { inc.disconnect("server-done"); };
				inc.handleDisconnect = (string, DisconnectType) {
					serverDisconnected = true;
					server.close();
				};
			};
			server.listen();

			auto client = new WindowsPipeConnection();
			assert(client.state == ConnectionState.disconnected,
			       "no-arg ctor did not start in disconnected state");

			client.handleConnect = () {
				clientConnectFired = true;
				client.send(Data(cast(immutable ubyte[])"X"));
			};
			client.handleReadData = (Data data) {
				gotByteOnClient = true;
				assert(cast(string)data.unsafeContents.idup == "Y");
				client.disconnect("client-done");
			};
			client.handleDisconnect = (string, DisconnectType) {
				clientDisconnected = true;
			};
			client.connect(name);

			socketManager.loop();

			assert(clientConnectFired,  "client handleConnect never fired");
			assert(gotByteOnServer,     "server never received the byte");
			assert(gotByteOnClient,     "client never received the byte");
			assert(clientDisconnected,  "client never disconnected");
			assert(serverDisconnected,  "server never disconnected");
		}

		// --- Subtest 2: close() cancels pending ConnectNamedPipe -------------
		{
			auto name = makeName();
			auto server = new NamedPipeServer(name);

			bool handleCloseFired;
			server.handleAccept = (WindowsPipeConnection /*inc*/) {
				assert(false, "no client should connect in this subtest");
			};
			server.handleClose = () { handleCloseFired = true; };

			server.listen();
			assert(server.isListening);
			server.close();
			assert(!server.isListening);

			socketManager.loop();

			assert(handleCloseFired, "handleClose never fired");
		}
	}

	// Regression: every submitted OVERLAPPED has exactly one manager-owned
	// retention.  In particular, a duplicate must not overwrite the first
	// owner, submission rollback must restore the exact baseline, and an
	// unknown raw pointer must be rejected before it can be dereferenced.
	debug(ae_unittest) version (Windows) unittest
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			import core.exception : AssertError;

			void assertRejected(void delegate() action, string description)
			{
				bool rejected;
				try
					action();
				catch (Exception)
					rejected = true;
				catch (AssertError)
					rejected = true;
				assert(rejected, description);
			}

			auto baseline = socketManager.iocpRetentions.length;
			auto owner = new Object;
			IocpOp op;

			socketManager.retainIocpOp(&op, owner);
			assert(socketManager.iocpRetentions.length == baseline + 1,
				"initial IOCP retention was not recorded");
			auto retained = &op.overlapped in socketManager.iocpRetentions;
			assert(retained !is null && retained.owner is owner && !retained.draining,
				"initial IOCP retention did not retain the expected active owner");

			assertRejected({ socketManager.retainIocpOp(&op, owner); },
				"duplicate IOCP retention did not fail");
			assert(socketManager.iocpRetentions.length == baseline + 1,
				"duplicate IOCP retention changed the registry");
			retained = &op.overlapped in socketManager.iocpRetentions;
			assert(retained !is null && retained.owner is owner,
				"duplicate IOCP retention replaced the original owner");

			socketManager.rollbackIocpSubmission(&op, owner);
			assert(socketManager.iocpRetentions.length == baseline,
				"immediate IOCP submission rollback did not restore the registry baseline");

			// Address 1 is deliberately non-null and non-dereferenceable.  The
			// registry lookup must reject it by value, before any IocpOp field is
			// read or dynamically cast.
			auto unknown = cast(OVERLAPPED*)cast(void*)1;
			assertRejected({ socketManager.takeIocpRetention(unknown); },
				"unknown non-null IOCP completion was not rejected before dereference");
			assert(socketManager.iocpRetentions.length == baseline,
				"unknown IOCP completion changed the registry");
		}
	}

	// Regression: dequeue takes the old retention before dispatch, so a
	// completion may legitimately re-retain the same embedded OVERLAPPED
	// address for its next generation.
	debug(ae_unittest) version (Windows) unittest
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			class RearmProbe : IocpParticipant
			{
				IocpOp op;
				bool completed;

				this()
				{
					op.kind = IocpOpKind.pipeRead;
					op.inFlight = true;
				}

				override bool iocpHasNonDaemonWork() { return false; }

				override void iocpOnComplete(IocpOp* completedOp, DWORD, uint status)
				{
					assert(completedOp is &op,
						"same-address IOCP re-arm dispatched the wrong operation");
					assert(status == ERROR_OPERATION_ABORTED,
						"same-address IOCP re-arm did not receive draining cleanup");
					socketManager.retainIocpOp(&op, this);
					completed = true;
				}

				override void iocpUserPost(DWORD)
				{
					assert(false, "same-address IOCP re-arm received an unexpected user post");
				}
			}

			auto baseline = socketManager.iocpRetentions.length;
			auto probe = new RearmProbe;
			socketManager.retainIocpOp(&probe.op, probe);
			socketManager.retireIocpOps(probe);
			assert(PostQueuedCompletionStatus(socketManager.getIocpPort(), 0, 0,
				&probe.op.overlapped),
				"could not post same-address IOCP re-arm completion");

			socketManager.loop();
			assert(probe.completed,
				"same-address IOCP re-arm completion was not dispatched");
			auto newRetention = &probe.op.overlapped in socketManager.iocpRetentions;
			assert(newRetention !is null && newRetention.owner is probe
				&& !newRetention.draining,
				"dispatch cleanup removed the same-address re-arm retention");

			socketManager.rollbackIocpSubmission(&probe.op, probe);
			assert(socketManager.iocpRetentions.length == baseline,
				"same-address IOCP re-arm test did not restore the registry baseline");
		}
	}

	// Regression: an ordinary retained operation has no independent liveness
	// meaning (it may belong to a daemon endpoint), whereas retirement after
	// close/cancel must keep the loop alive until its exact completion drains.
	debug(ae_unittest) version (Windows) unittest
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			import ae.sys.timing : setTimeout, TimerTask;
			import core.time : msecs;

			class RetentionProbe : IocpParticipant
			{
				IocpOp op;
				int completionCalls;

				this()
				{
					op.kind = IocpOpKind.pipeRead;
					op.inFlight = true;
				}

				override bool iocpHasNonDaemonWork() { return false; }

				override void iocpOnComplete(IocpOp* completed, DWORD, uint status)
				{
					assert(completed is &op,
						"retired IOCP completion used the wrong embedded operation");
					assert(status == ERROR_OPERATION_ABORTED,
						"retired IOCP completion was not converted to aborted cleanup");
					completionCalls++;
				}

				override void iocpUserPost(DWORD)
				{
					assert(false, "retention probe received an unexpected user post");
				}
			}

			assert(!mainTimer.hasNonDaemonTasks(),
				"IOCP retention liveness test requires no pending non-daemon timer");
			auto baseline = socketManager.iocpRetentions.length;
			auto probe = new RetentionProbe;
			socketManager.retainIocpOp(&probe.op, probe);

			// A daemon timer turns an accidental wait into a bounded assertion while
			// remaining invisible to the normal loop-liveness decision.
			TimerTask watchdog = setTimeout({
				assert(false, "ordinary retained IOCP work kept the loop alive");
			}, 100.msecs);
			watchdog.daemon = true;
			socketManager.loop();
			assert(watchdog.isWaiting(),
				"ordinary retained IOCP work did not leave the loop immediately idle");
			watchdog.cancel();
			assert(probe.completionCalls == 0,
				"ordinary retained IOCP work was dispatched without a completion");

			socketManager.retireIocpOps(probe);
			auto retained = &probe.op.overlapped in socketManager.iocpRetentions;
			assert(retained !is null && retained.owner is probe && retained.draining,
				"retiring an IOCP operation did not mark its retention draining");
			assert(socketManager.hasDrainingIocpOps(),
				"retired IOCP work was not visible to loop liveness");
			assert(PostQueuedCompletionStatus(socketManager.getIocpPort(), 0, 0,
				&probe.op.overlapped),
				"could not post the retained IOCP completion");

			socketManager.loop();
			assert(probe.completionCalls == 1,
				"retired IOCP work did not keep the loop alive through its drain");
			assert(!probe.op.inFlight,
				"drained IOCP operation retained its in-flight state");
			assert(socketManager.iocpRetentions.length == baseline,
				"retired IOCP work did not restore the registry baseline");
		}
	}

	// Regression: closing a listener with a real in-flight AcceptEx must move
	// its embedded operation into the draining registry.  No ordinary test
	// reference survives the helper scope; collection and allocation pressure
	// therefore exercise the registry's owner root before the abort packet is
	// dequeued.
	debug(ae_unittest) version (Windows) unittest
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			import ae.sys.timing : setTimeout, TimerTask;
			import core.memory : GC;
			import core.time : seconds;

			auto managerBaseline = socketManager.size();
			auto retentionBaseline = socketManager.iocpRetentions.length;
			size_t candidate;

			void armAndRetireListener()
			{
				auto server = new TcpServer;
				server.handleAccept = (TcpConnection) {
					assert(false, "closed listener accepted a connection");
				};
				server.listen(0, "127.0.0.1");
				assert(server.listeners.length == 1,
					"AcceptEx retention test did not create exactly one listener");

				auto listener = server.listeners[0];
				assert(listener._iocpAcceptOp.inFlight,
					"listener did not submit its initial AcceptEx");
				auto active = &listener._iocpAcceptOp.overlapped in socketManager.iocpRetentions;
				assert(active !is null && active.owner is listener && !active.draining,
					"in-flight AcceptEx was not actively retained by the registry");
				candidate = listener._iocpCandidateSocket;
				assert(candidate != c_socks.INVALID_SOCKET,
					"in-flight AcceptEx did not retain its candidate socket");

				server.close();
				assert(socketManager.size() == managerBaseline,
					"closed listener remained registered with the socket manager");
				auto draining = &listener._iocpAcceptOp.overlapped in socketManager.iocpRetentions;
				assert(draining !is null && draining.owner is listener && draining.draining,
					"closed listener's AcceptEx was not retained as draining work");

				// The registry is deliberately the only owner retained beyond this
				// helper.  Clearing locals makes that contract explicit to readers;
				// the subsequent full collections and allocation churn make a stale
				// self-reference insufficient in practice as well.
				listener = null;
				server = null;
			}

			TimerTask timeout = setTimeout({
				assert(false, "retired AcceptEx completion did not drain within 5 seconds");
			}, 5.seconds);
			timeout.daemon = true;

			armAndRetireListener();
			assert(socketManager.iocpRetentions.length == retentionBaseline + 1,
				"closed listener did not leave exactly one retained AcceptEx operation");

			GC.collect();
			ubyte[][] pressure;
			foreach (index; 0 .. 256)
			{
				auto block = new ubyte[64 * 1024];
				block[0] = cast(ubyte)index;
				pressure ~= block;
			}
			assert(pressure.length == 256,
				"AcceptEx retention test did not allocate the requested GC pressure");
			pressure = null;
			GC.collect();

			socketManager.loop();
			assert(timeout.isWaiting(),
				"retired AcceptEx drain exceeded its watchdog deadline");
			timeout.cancel();
			assert(socketManager.size() == managerBaseline,
				"AcceptEx drain did not restore the socket-manager baseline");
			assert(socketManager.iocpRetentions.length == retentionBaseline,
				"AcceptEx drain did not restore the registry baseline");

			// The numeric SOCKET value is not a GC root.  A second close must fail,
			// proving the cancellation path disposed of the AcceptEx candidate.
			assert(c_socks.closesocket(cast(c_socks.SOCKET)candidate) == Socket.ERROR
				&& WSAGetLastError() == c_socks.WSAENOTSOCK,
				"retired AcceptEx completion leaked its candidate socket");
		}
	}

	// Regression: ERROR_PIPE_CONNECTED owns no kernel packet, so the server
	// must synthesize one retained zero-status completion.  It must reach the
	// normal server-success path once, rather than dispatching directly or
	// leaving a stale retained operation behind.
	debug(ae_unittest) version (Windows) unittest
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			import ae.sys.timing : setTimeout, TimerTask;
			import core.time : seconds;
			import std.format : format;
			import std.utf : toUTF16z;

			enum DWORD PIPE_ACCESS_DUPLEX_       = 0x00000003;
			enum DWORD FILE_FLAG_OVERLAPPED_     = 0x40000000;
			enum DWORD PIPE_TYPE_BYTE_           = 0x00000000;
			enum DWORD PIPE_READMODE_BYTE_       = 0x00000000;
			enum DWORD PIPE_WAIT_                = 0x00000000;
			enum DWORD PIPE_UNLIMITED_INSTANCES_ = 255;

			static int sequence;
			HANDLE makePreconnectedPipe(out HANDLE client)
			{
				auto name = format(`\\.\pipe\ae-iocp-synthetic-%s-%s`,
					GetCurrentProcessId(), sequence++);
				auto serverHandle = CreateNamedPipeW(name.toUTF16z,
					PIPE_ACCESS_DUPLEX_ | FILE_FLAG_OVERLAPPED_,
					PIPE_TYPE_BYTE_ | PIPE_READMODE_BYTE_ | PIPE_WAIT_
						| PIPE_REJECT_REMOTE_CLIENTS,
					PIPE_UNLIMITED_INSTANCES_, 65536, 65536, 0, null);
				assert(serverHandle != INVALID_HANDLE_VALUE,
					"CreateNamedPipeW failed for ERROR_PIPE_CONNECTED regression");

				client = CreateFileW(name.toUTF16z,
					GENERIC_READ | GENERIC_WRITE, 0, null,
					OPEN_EXISTING, FILE_FLAG_OVERLAPPED_, null);
				assert(client != INVALID_HANDLE_VALUE,
					"CreateFileW failed for ERROR_PIPE_CONNECTED regression");
				return serverHandle;
			}

			auto retentionBaseline = socketManager.iocpRetentions.length;
			HANDLE client;
			auto pendingHandle = makePreconnectedPipe(client);
			auto server = new NamedPipeServer("unused-test-name");
			auto port = socketManager.getIocpPort();
			assert(CreateIoCompletionPort(pendingHandle, port,
				cast(ULONG_PTR)cast(void*)server, 0) == port,
				"CreateIoCompletionPort failed for preconnected named pipe");
			server._pendingHandle = pendingHandle;
			server._listening = true;
			socketManager.addParticipant(server);

			int accepted, closed;
			WindowsPipeConnection acceptedConnection;
			TimerTask timeout = setTimeout({
				assert(false, "ERROR_PIPE_CONNECTED synthetic completion did not arrive");
			}, 5.seconds);
			timeout.daemon = true;
			server.handleClose = { closed++; };
			server.handleAccept = (WindowsPipeConnection incoming) {
				accepted++;
				assert(accepted == 1,
					"ERROR_PIPE_CONNECTED reached server success more than once");
				assert(server._connectOp.overlapped.Internal == 0,
					"synthetic ERROR_PIPE_CONNECTED completion did not carry success status");
				acceptedConnection = incoming;
				timeout.cancel();
				incoming.disconnect("synthetic-connect test complete");
				server.close();
			};

			// The client already connected before ConnectNamedPipe, forcing the
			// documented ERROR_PIPE_CONNECTED branch without relying on a race.
			server._armConnect();
			assert(server._pending,
				"ERROR_PIPE_CONNECTED did not preserve its pending synthetic operation");
			auto retained = &server._connectOp.overlapped in socketManager.iocpRetentions;
			assert(retained !is null && retained.owner is server && !retained.draining,
				"ERROR_PIPE_CONNECTED synthetic completion was not retained before post");

			socketManager.loop();
			assert(!timeout.isWaiting(),
				"ERROR_PIPE_CONNECTED success path did not cancel its watchdog");
			assert(accepted == 1 && closed == 1,
				"ERROR_PIPE_CONNECTED did not complete and close exactly once");
			assert(acceptedConnection.state == ConnectionState.disconnected,
				"accepted synthetic named-pipe connection was not cleaned up");
			assert(socketManager.iocpRetentions.length == retentionBaseline,
				"ERROR_PIPE_CONNECTED synthetic completion did not restore the registry baseline");
			assert(CloseHandle(client),
				"CloseHandle failed for ERROR_PIPE_CONNECTED test client");
		}
	}

	// Regression: a forced WindowsPipeConnection close must retire and drain
	// both its outstanding ReadFile and WriteFile, preserving their owner-held
	// buffers until the two abort completions have cleared all pending state.
	debug(ae_unittest) version (Windows) unittest
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			import ae.sys.timing : setTimeout, TimerTask;
			import core.time : seconds;
			import std.format : format;
			import std.utf : toUTF16z;

			enum DWORD PIPE_ACCESS_DUPLEX_       = 0x00000003;
			enum DWORD FILE_FLAG_OVERLAPPED_     = 0x40000000;
			enum DWORD PIPE_TYPE_BYTE_           = 0x00000000;
			enum DWORD PIPE_READMODE_BYTE_       = 0x00000000;
			enum DWORD PIPE_WAIT_                = 0x00000000;
			enum DWORD PIPE_UNLIMITED_INSTANCES_ = 255;

			static int sequence;
			HANDLE makePipePair(out HANDLE client)
			{
				auto name = format(`\\.\pipe\ae-iocp-close-drain-%s-%s`,
					GetCurrentProcessId(), sequence++);
				auto serverHandle = CreateNamedPipeW(name.toUTF16z,
					PIPE_ACCESS_DUPLEX_ | FILE_FLAG_OVERLAPPED_,
					PIPE_TYPE_BYTE_ | PIPE_READMODE_BYTE_ | PIPE_WAIT_
						| PIPE_REJECT_REMOTE_CLIENTS,
					PIPE_UNLIMITED_INSTANCES_, 65536, 65536, 0, null);
				assert(serverHandle != INVALID_HANDLE_VALUE,
					"CreateNamedPipeW failed for pipe close-drain regression");

				client = CreateFileW(name.toUTF16z,
					GENERIC_READ | GENERIC_WRITE, 0, null,
					OPEN_EXISTING, FILE_FLAG_OVERLAPPED_, null);
				assert(client != INVALID_HANDLE_VALUE,
					"CreateFileW failed for pipe close-drain regression");
				return serverHandle;
			}

			auto retentionBaseline = socketManager.iocpRetentions.length;
			HANDLE client;
			auto serverHandle = makePipePair(client);
			auto connection = new WindowsPipeConnection(client);
			auto peer = new WindowsPipeConnection(serverHandle);
			connection.handleReadData = (Data) {
				assert(false, "close-drain pipe read delivered data unexpectedly");
			};
			assert(connection._readPending,
				"pipe close-drain test did not submit its ReadFile operation");
			connection.send(Data(cast(immutable ubyte[])"pending write"));

			bool closedWhileBothPending;
			TimerTask timeout = setTimeout({
				assert(false, "WindowsPipeConnection close did not drain both operations");
			}, 5.seconds);
			timeout.daemon = true;
			onNextTick(socketManager, {
				// send() queues its drain first, so this test callback runs after
				// WriteFile has been posted but before the loop dequeues either I/O.
				assert(connection._readPending && connection._writePending,
					"pipe close did not begin with both ReadFile and WriteFile pending");
				assert(connection._writeBuf !is null,
					"pipe close did not retain the in-flight WriteFile buffer");
				assert(socketManager.iocpRetentions.length == retentionBaseline + 2,
					"pipe close did not retain both submitted operations");

				connection.disconnect("forced pipe close", DisconnectType.error);
				closedWhileBothPending = true;
				assert(connection.state == ConnectionState.disconnected,
					"forced pipe close did not synchronously enter disconnected state");
				assert(connection._readPending && connection._writePending
					&& connection._writeBuf !is null,
					"forced pipe close released operation state before completion drain");
				auto readRetention = &connection._readOp.overlapped in socketManager.iocpRetentions;
				auto writeRetention = &connection._writeOp.overlapped in socketManager.iocpRetentions;
				assert(readRetention !is null && readRetention.owner is connection
					&& readRetention.draining,
					"forced pipe close did not retire its pending read");
				assert(writeRetention !is null && writeRetention.owner is connection
					&& writeRetention.draining,
					"forced pipe close did not retire its pending write");
			});

			socketManager.loop();
			assert(timeout.isWaiting(),
				"WindowsPipeConnection close-drain exceeded its watchdog deadline");
			timeout.cancel();
			assert(closedWhileBothPending,
				"pipe close-drain test never observed its two pending operations");
			assert(!connection._readPending && !connection._writePending,
				"drained WindowsPipeConnection retained pending read/write state");
			assert(connection._writeBuf is null && !connection._drainScheduled,
				"drained WindowsPipeConnection retained write buffer or scheduled drain");
			foreach (ref queue; connection._outQueue)
				assert(queue.length == 0,
					"drained WindowsPipeConnection retained queued output");
			assert(socketManager.iocpRetentions.length == retentionBaseline,
				"WindowsPipeConnection close-drain did not restore the registry baseline");

			peer.disconnect("pipe close-drain peer cleanup");
		}
	}
}
else
	static assert(false, "No event loop mechanism selected");

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
debug (ASOCKETS_SLOW_EVENT_HANDLER)
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
	private:
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

	public:
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

private struct IdleHandler
{
	void delegate() dg;
	debug (ASOCKETS_DEBUG_SHUTDOWN) TraceInfo stackTrace;
	else debug (ASOCKETS_DEBUG_IDLE) TraceInfo stackTrace;

	this(void delegate() dg)
	{
		this.dg = dg;
		debug (ASOCKETS_DEBUG_SHUTDOWN) stackTrace = captureStackTrace();
		else debug (ASOCKETS_DEBUG_IDLE) stackTrace = captureStackTrace();
	}

	bool opEquals(void delegate() other) const
	{
		return dg is other;
	}
}

// Common event loop state printing functions, used by both ASOCKETS_DEBUG_SHUTDOWN and ASOCKETS_DEBUG_IDLE.
private debug (ASOCKETS_DEBUG_SHUTDOWN)
{
	import ae.utils.exception : captureStackTrace, printCapturedStackTrace, TraceInfo;
	enum haveEventLoopDebug = true;
}
else debug (ASOCKETS_DEBUG_IDLE)
{
	import ae.utils.exception : captureStackTrace, printCapturedStackTrace, TraceInfo;
	enum haveEventLoopDebug = true;
}
else
	enum haveEventLoopDebug = false;

static if (haveEventLoopDebug)
{
	/// Prints the current state of the event loop to stderr.
	/// Params:
	///   onlyBlocking = If true, only show non-daemon sockets that are blocking shutdown.
	///                  If false, show all registered sockets.
	///   skipTask = Timer task to skip (e.g., the debugger's own watchdog task).
	///   skipTaskLabel = Label to use when the only pending task is the skipped one.
	void printEventLoopState(bool onlyBlocking, TimerTask skipTask = null, string skipTaskLabel = "watchdog")
	{
		printEventLoopSockets(onlyBlocking);
		printEventLoopTimerTasks(skipTask, skipTaskLabel);
		printEventLoopIdleHandlers();
		printEventLoopNextTickHandlers();
	}

	void printEventLoopSockets(bool onlyBlocking)
	{
		import std.stdio : stderr;

		static if (eventLoopMechanism == EventLoopMechanism.libev)
		{
			stderr.writeln("SOCKETS: Not tracked with LIBEV\n");
		}
		else
		{
			size_t count;

			foreach (sock; socketManager.sockets)
			{
				if (sock is null || sock.socket is null)
					continue;
				if (onlyBlocking && !(sock.notifyRead && !sock.daemonRead || sock.notifyWrite && !sock.daemonWrite))
					continue;

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

			if (count == 0)
				stderr.writeln(onlyBlocking ? "SOCKETS: None blocking\n" : "SOCKETS: None registered\n");
			else
				stderr.writefln("SOCKETS: %d %s\n", count, onlyBlocking ? "blocking" : "registered");
		}
	}

	void printEventLoopTimerTasks(TimerTask skipTask, string skipTaskLabel)
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
			if (task is skipTask)
				continue;

			count++;
			stderr.writefln("TIMER TASK: %s%s", cast(void*)task, task.daemon ? " (daemon)" : "");
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
			stderr.writefln("TIMER TASKS: Only the %s is pending\n", skipTaskLabel);
		else
			stderr.writefln("TIMER TASKS: %d pending\n", count);
	}

	void printEventLoopIdleHandlers()
	{
		import std.stdio : stderr;

		static if (eventLoopMechanism == EventLoopMechanism.libev)
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
			foreach (i, ref handler; handlers)
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

	void printEventLoopNextTickHandlers()
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
}

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
			watchdogTask.daemon = true;  // Don't keep the event loop alive
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

			printEventLoopState(true, watchdogTask, "shutdown watchdog");

			stderr.writeln("=".repeat(72).join);
			stderr.flush();
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
}

// Idle debugging: prints objects blocking the event loop when it's been idle
// (no socket events or idle handlers) for too long, then aborts.
private debug (ASOCKETS_DEBUG_IDLE)
{
	import std.process : environment;
	import ae.utils.time.parsedur : parseDuration;
	import core.stdc.stdlib : abort;

	struct IdleDebugger
	{
	static:
		bool registered = false;
		Duration timeout;
		Duration checkInterval;
		TimerTask periodicTask;
		MonoTime lastActivityTime;
		bool inPeriodicCallback = false;

		/// Called when real activity (socket events, idle handlers) occurs.
		void onActivity()
		{
			if (!registered || inPeriodicCallback)
				return;
			lastActivityTime = MonoTime.currTime();
		}

		void onPeriodicCheck(Timer, TimerTask)
		{
			import std.stdio : stderr;

			inPeriodicCallback = true;
			scope(exit) inPeriodicCallback = false;

			auto now = MonoTime.currTime();
			auto elapsed = now - lastActivityTime;

			if (elapsed >= timeout)
			{
				import std.range : repeat;
				import std.array : join;

				stderr.writeln("\n[ASOCKETS_DEBUG_IDLE] Event loop has been idle for ", elapsed, "!");
				stderr.writeln("=".repeat(72).join);
				stderr.writeln("Objects in the event loop:");
				stderr.writeln();

				printEventLoopState(false, periodicTask, "idle watchdog");

				stderr.writeln("=".repeat(72).join);
				stderr.flush();

				abort();
			}

			// Reschedule periodic check
			mainTimer.add(periodicTask, now + checkInterval);
		}

		/// Register lazily, only for threads that actually run an event loop.
		void register()
		{
			import std.stdio : stderr;

			if (registered)
				return;
			registered = true;

			timeout = parseDuration(environment.get("AE_DEBUG_IDLE_TIMEOUT", "30 secs"));
			checkInterval = timeout / 6;  // Check 6 times per timeout period
			if (checkInterval < 1.seconds)
				checkInterval = 1.seconds;

			lastActivityTime = MonoTime.currTime();

			stderr.writeln("[ASOCKETS_DEBUG_IDLE] Idle watchdog enabled with timeout ", timeout, ".");
			stderr.flush();

			periodicTask = new TimerTask((Timer t, TimerTask task) { onPeriodicCheck(t, task); });
			periodicTask.daemon = true;  // Don't keep the event loop alive
			mainTimer.add(periodicTask, MonoTime.currTime() + checkInterval);
		}
	}
}

// ***************************************************************************

/// General methods for an asynchronous socket.
abstract class GenericSocket
{
	/// Declares notifyRead and notifyWrite.
	mixin SocketMixin;

	debug (ASOCKETS_DEBUG_SHUTDOWN) TraceInfo registrationStackTrace;
	else debug (ASOCKETS_DEBUG_IDLE) TraceInfo registrationStackTrace;

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

	/// Enable or disable Nagle's algorithm (TCP_NODELAY).
	/// Only valid for TCP sockets.
	private final void setNoDelay(bool enabled = true)
	{
		assert(conn, "Attempting to set TCP_NODELAY on an uninitialized socket");
		conn.setOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, enabled);
	}

	/// Returns a string containing the class name, address, and file descriptor.
	override string toString() const
	{
		import std.string : format, split;
		return "%s {this=%s, fd=%s}".format(this.classinfo.name.split(".")[$-1], cast(void*)this, conn ? conn.handle : -1);
	}
}

// ***************************************************************************

// Regression: daemonRead/daemonWrite must independently determine whether a
// socket's declared read/write interest keeps socketManager.loop() alive,
// consistently across every event-loop backend.
debug (ae_unittest) unittest
{
	import core.time : msecs, seconds;
	import std.socket : socketPair;

	final class DaemonDirectionProbe : GenericSocket
	{
		this(Socket socket)
		{
			conn = socket;
			socketManager.register(this);
		}

		void close()
		{
			// Not all backends clear these on unregister(); do it ourselves
			// so cleanup is correct regardless of backend.
			notifyRead = false;
			notifyWrite = false;
			socketManager.unregister(this);
			conn.close();
			conn = null;
		}
	}

	auto idleManagerSize = socketManager.size();
	assert(!mainTimer.hasNonDaemonTasks(),
		"daemon socket direction regression test requires no pending non-daemon timer");

	// Run `arrange` on a fresh probe, then require socketManager.loop() to
	// return without ever needing to wait for anything.
	void assertLoopReturnsPromptly(void delegate(DaemonDirectionProbe probe) arrange)
	{
		auto pair = socketPair();
		pair[0].blocking = false;
		auto probe = new DaemonDirectionProbe(pair[0]);
		scope(exit) { probe.close(); pair[1].close(); }

		arrange(probe);

		auto watchdog = setTimeout({
			assert(false, "a daemon-flagged direction unexpectedly kept socketManager.loop() alive");
		}, 2.seconds);
		watchdog.daemon = true;

		socketManager.loop();

		assert(watchdog.isWaiting(),
			"socketManager.loop() blocked past a daemon-flagged direction's watchdog");
		watchdog.cancel();
	}

	// Run `arrange` on a fresh probe, schedule `release` to run shortly
	// afterwards, and require socketManager.loop() to return only once
	// `release` has actually run -- i.e. that it genuinely blocked first.
	void assertLoopBlocksUntilReleased(
		void delegate(DaemonDirectionProbe probe) arrange,
		void delegate(DaemonDirectionProbe probe) release)
	{
		auto pair = socketPair();
		pair[0].blocking = false;
		auto probe = new DaemonDirectionProbe(pair[0]);
		scope(exit) { probe.close(); pair[1].close(); }

		arrange(probe);

		bool released;
		auto releaseTask = setTimeout({ released = true; release(probe); }, 20.msecs);
		releaseTask.daemon = true;

		auto watchdog = setTimeout({
			assert(false, "a non-daemon direction failed to keep socketManager.loop() alive");
		}, 2.seconds);
		watchdog.daemon = true;

		socketManager.loop();

		assert(released,
			"socketManager.loop() returned before the non-daemon direction was released");
		watchdog.cancel();
	}

	// 1. daemonRead=true with declared read interest does not keep the loop
	// alive.
	assertLoopReturnsPromptly((probe) {
		probe.daemonRead = true;
		probe.notifyRead = true;
	});

	// 2. The same connection with daemonRead=false does, until read interest
	// is withdrawn.
	assertLoopBlocksUntilReleased(
		(probe) { probe.notifyRead = true; },
		(probe) { probe.notifyRead = false; });

	// 3. Same, independently, for daemonWrite.
	assertLoopReturnsPromptly((probe) {
		probe.daemonWrite = true;
		probe.notifyWrite = true;
	});
	assertLoopBlocksUntilReleased(
		(probe) { probe.notifyWrite = true; },
		(probe) { probe.notifyWrite = false; });

	// 4. Independence: daemonizing one direction must not silence the
	// other's still-non-daemon contribution. A single shared bit would make
	// these two cases return promptly instead of blocking until released.
	assertLoopBlocksUntilReleased(
		(probe) {
			probe.notifyRead = true;
			probe.notifyWrite = true;
			probe.daemonRead = true;
			assert(!probe.daemonWrite);
		},
		(probe) { probe.daemonWrite = true; });
	assertLoopBlocksUntilReleased(
		(probe) {
			probe.notifyRead = true;
			probe.notifyWrite = true;
			probe.daemonWrite = true;
			assert(!probe.daemonRead);
		},
		(probe) { probe.daemonRead = true; });

	// 5. The deprecated `daemon` spelling remains a working alias for
	// daemonRead.
	assertLoopReturnsPromptly((probe) {
		probe.daemon = true;
		assert(probe.daemonRead);
		probe.notifyRead = true;
	});

	assert(socketManager.size() == idleManagerSize,
		"daemon socket direction regression test did not restore the idle socket-manager state");
	assert(!mainTimer.hasNonDaemonTasks(),
		"daemon socket direction regression test leaked a non-daemon timer");
}

// ***************************************************************************

static if (eventLoopMechanism == EventLoopMechanism.libev)
version (Posix)
debug (ae_unittest)
{
	/// Exercise the LIBEV timer's daemon/reference balance from either the
	/// module unittest runner or a package-scoped disposable runner.
	/// Requires a `socketManager.loop()` to have already run in this
	/// process, so that the `ASOCKETS_DEBUG_IDLE` watchdog is armed and can
	/// be suspended for the test's duration.
	package(ae) void testLibevDaemonTimers()
	{
		import core.time : days, msecs, seconds;

		void updateNativeTimer(bool force)
		{
			socketManager.now = MonoTime.currTime();
			socketManager.updateTimer(force);
		}

		void assertTimerState(
			bool active,
			bool unreferenced,
			MonoTime nextEvent,
			string stage)
		{
			assert(mainTimer.getNextEvent() == nextEvent,
				stage ~ ": unexpected logical timer deadline");
			assert(socketManager.lastNextEvent == nextEvent,
				stage ~ ": unexpected native timer deadline");
			assert(!!ev_is_active(&socketManager.evTimer) == active,
				stage ~ ": unexpected native timer activity");
			assert(socketManager.evTimerUnreferenced == unreferenced,
				stage ~ ": unexpected native timer reference balance");
		}

		// ASOCKETS_DEBUG_IDLE's idle watchdog task is suspended for this
		// test's whole duration (see below), so mainTimer is under this
		// test's exclusive ownership throughout: it is genuinely empty
		// between phases, never left with a lingering daemon task.
		void assertTimerCleared(string stage)
		{
			assert(!mainTimer.isWaiting(),
				stage ~ ": timer unexpectedly still waiting");
			assertTimerState(false, false, MonoTime.max, stage);
		}

		// This test verifies the manager's native timer against mainTimer's
		// head, so it requires exclusive ownership of mainTimer for its
		// duration.  ASOCKETS_DEBUG_IDLE arms a permanent daemon watchdog
		// task on the first loop() in the process; this test requires that
		// loop() to have already run (its wrapper unittest runs one before
		// calling this function), so the watchdog is already armed here.
		// Suspend it and restore it to its original absolute deadline on the
		// way out, even if an assertion below fails.
		debug (ASOCKETS_DEBUG_IDLE)
		{
			auto idleTask = IdleDebugger.periodicTask;
			assert(idleTask !is null && idleTask.isWaiting(),
				"testLibevDaemonTimers requires a loop() to have already run "
				~ "in this process, to arm the ASOCKETS_DEBUG_IDLE watchdog");
			assert(!mainTimer.hasNonDaemonTasks(),
				"idle watchdog task coexists with non-daemon timer work");
			auto idleDeadline = idleTask.when;
			assert(mainTimer.getNextEvent() == idleDeadline,
				"idle watchdog task is not the timer head");
			idleTask.cancel();
			scope(exit) mainTimer.add(idleTask, idleDeadline);
		}

		assert(!mainTimer.isWaiting(),
			"libev daemon-timer test requires an empty timer");
		// The manager's ev_timer is reconciled with mainTimer only at loop
		// entry and after each dispatched event, never at timer-mutation
		// time.  An earlier test may therefore legitimately have cancelled a
		// daemon task after its socketManager.loop() returned, leaving the
		// watcher armed for that cancelled deadline.  That state is
		// manager-private, so establishing it is this test's job, exactly as
		// it is at every other assertTimerState call below.
		updateNativeTimer(true);
		assertTimerCleared("initial empty timer");

		auto headDeadline = MonoTime.currTime() + 3.days;
		auto head = new TimerTask((Timer, TimerTask) {
			assert(false, "far-future daemon head timer unexpectedly fired");
		});
		head.daemon = true;
		mainTimer.add(head, headDeadline);
		updateNativeTimer(true);
		assert(head.isWaiting(), "far-future daemon head timer was not scheduled");
		assertTimerState(true, true, headDeadline, "initial daemon head");

		// Changing daemon status does not alter the head deadline, so this must
		// update the native reference balance without rescheduling the timer.
		head.daemon = false;
		assert(mainTimer.getNextEvent() == headDeadline,
			"changing the head daemon state changed its deadline");
		updateNativeTimer(false);
		assertTimerState(true, false, headDeadline, "daemon head made non-daemon");
		head.daemon = true;
		assert(mainTimer.getNextEvent() == headDeadline,
			"restoring the head daemon state changed its deadline");
		updateNativeTimer(false);
		assertTimerState(true, true, headDeadline, "non-daemon head made daemon");

		auto later = new TimerTask((Timer, TimerTask) {
			assert(false, "far-future later non-daemon timer unexpectedly fired");
		});
		mainTimer.add(later, headDeadline + 1.days);
		assert(mainTimer.getNextEvent() == headDeadline,
			"adding later non-daemon work changed the daemon head deadline");
		updateNativeTimer(false);
		assert(later.isWaiting(), "later non-daemon timer was not scheduled");
		assertTimerState(true, false, headDeadline, "later non-daemon work added");
		later.cancel();
		assert(mainTimer.getNextEvent() == headDeadline,
			"removing later non-daemon work changed the daemon head deadline");
		updateNativeTimer(false);
		assertTimerState(true, true, headDeadline, "later non-daemon work removed");

		auto earlierDeadline = MonoTime.currTime() + 1.days;
		auto earlier = new TimerTask((Timer, TimerTask) {
			assert(false, "far-future earlier daemon timer unexpectedly fired");
		});
		earlier.daemon = true;
		mainTimer.add(earlier, earlierDeadline);
		updateNativeTimer(false);
		assert(earlier.isWaiting(), "earlier daemon timer was not scheduled");
		assertTimerState(true, true, earlierDeadline, "earlier daemon head replaced timer");

		earlier.cancel();
		head.cancel();
		updateNativeTimer(false);
		assert(!mainTimer.isWaiting(), "cancelled daemon timers remained scheduled");
		assertTimerState(false, false, MonoTime.max, "all daemon timers cancelled");

		auto fresh = new TimerTask((Timer, TimerTask) {
			assert(false, "fresh far-future daemon timer unexpectedly fired");
		});
		fresh.daemon = true;
		auto freshDeadline = MonoTime.currTime() + 1.days;
		mainTimer.add(fresh, freshDeadline);
		updateNativeTimer(false);
		assertTimerState(true, true, freshDeadline, "fresh daemon timer started");
		fresh.cancel();
		updateNativeTimer(false);
		assertTimerState(false, false, MonoTime.max, "fresh daemon timer stopped");

		bool tenSecondDaemonFired;
		auto tenSecondDaemon = new TimerTask((Timer, TimerTask) {
			tenSecondDaemonFired = true;
			assert(false, "ten-second daemon timer unexpectedly fired");
		});
		tenSecondDaemon.daemon = true;
		mainTimer.add(tenSecondDaemon, MonoTime.currTime() + 10.seconds);
		socketManager.loop();
		assert(!tenSecondDaemonFired && tenSecondDaemon.isWaiting(),
			"first libev loop consumed ten-second daemon work");
		socketManager.loop();
		assert(!tenSecondDaemonFired && tenSecondDaemon.isWaiting(),
			"second libev loop consumed ten-second daemon work");
		tenSecondDaemon.cancel();
		updateNativeTimer(false);
		assertTimerCleared("ten-second daemon timer cleaned up");

		bool daemonRan;
		bool nonDaemonRan;
		auto callbackStart = MonoTime.currTime();
		auto daemonCallback = new TimerTask((Timer, TimerTask) {
			assert(!daemonRan, "daemon callback ran more than once");
			assert(!nonDaemonRan, "later non-daemon callback ran before daemon callback");
			daemonRan = true;
		});
		daemonCallback.daemon = true;
		auto nonDaemonCallback = new TimerTask((Timer, TimerTask) {
			assert(daemonRan, "later non-daemon callback ran before daemon callback");
			assert(!nonDaemonRan, "later non-daemon callback ran more than once");
			nonDaemonRan = true;
		});
		mainTimer.add(daemonCallback, callbackStart + 10.msecs);
		mainTimer.add(nonDaemonCallback, callbackStart + 20.msecs);
		socketManager.loop();
		assert(daemonRan, "earlier daemon callback did not run");
		assert(nonDaemonRan, "later non-daemon callback did not keep libev alive");
		assert(!daemonCallback.isWaiting() && !nonDaemonCallback.isWaiting(),
			"timer callbacks remained scheduled after the loop");
		assertTimerCleared("daemon callback followed by non-daemon callback");
	}

	debug (ae_unittest) unittest
	{
		import core.time : seconds;

		// Regression: cancelling a daemon task after socketManager.loop() has
		// returned leaves the manager's ev_timer armed for the cancelled
		// deadline.  That is legal -- the native mirror is reconciled at loop
		// entry and after each dispatched event, not at mutation time -- so
		// testLibevDaemonTimers must establish its own native-timer
		// precondition rather than assume it is the first code in the process
		// to touch the manager.
		auto watchdog = setTimeout({
			assert(false, "daemon watchdog unexpectedly fired");
		}, 10.seconds);
		watchdog.daemon = true;
		socketManager.loop();
		assert(watchdog.isWaiting(),
			"socketManager.loop() consumed the daemon watchdog");
		watchdog.cancel();
		assert(socketManager.lastNextEvent != MonoTime.max,
			"cancelling a daemon task outside loop() unexpectedly reconciled "
			~ "the manager's native timer");

		testLibevDaemonTimers();
	}
}

// ***************************************************************************

static if (eventLoopMechanism == EventLoopMechanism.libev)
version (Posix)
debug (ae_unittest)
{
	// This state is intentionally kept separate from the probe: the forced-GC
	// test may retain it to observe dispatch, but it never retains the owner.
	private final class LibevWatcherDispatchState
	{
		TimerTask watchdog;
		int callbacks;
		bool ownerBalanceHeldDuringDispatch;
		bool ownerBalanceReleasedAfterNativeStop;
		bool unregistered;
		bool closed;
	}

	/// Small registered GenericSocket used to exercise the LIBEV-only watcher
	/// fields directly from this module.
	private final class LibevWatcherProbe : GenericSocket
	{
		private LibevWatcherDispatchState dispatchState;

		this(Socket socket, LibevWatcherDispatchState dispatchState = null)
		{
			conn = socket;
			this.dispatchState = dispatchState;
			socketManager.register(this);
		}

		override void onReadable()
		{
			assert(dispatchState !is null, "unexpected libev watcher probe dispatch");
			assert(dispatchState.callbacks == 0,
				"libev watcher probe dispatched more than once");

			ubyte[1] received;
			assert(conn.receive(received[]) == received.length,
				"libev watcher probe did not receive its readable byte");
			assert(received[0] == 0xA5,
				"libev watcher probe received an unexpected byte");

			dispatchState.callbacks++;
			dispatchState.ownerBalanceHeldDuringDispatch = evRooted;
			assert(dispatchState.ownerBalanceHeldDuringDispatch,
				"libev watcher owner balance was not held during dispatch");
			if (libevNoMoveIsObservable())
				assert(libevWatcherProbePinned(this),
					"libev watcher owner was not pinned during dispatch");

			// `notifyRead = false` synchronously calls ev_io_stop. Only after it
			// returns may the shared owner balance be released.
			notifyRead = false;
			dispatchState.ownerBalanceReleasedAfterNativeStop = evRead.data is null
				&& evWrite.data is null
				&& !evRooted;
			assert(dispatchState.ownerBalanceReleasedAfterNativeStop,
				"libev watcher owner balance survived native watcher stop");
			if (libevNoMoveIsObservable())
				assert(!libevWatcherProbePinned(this),
					"libev watcher owner pin survived native watcher stop");

			socketManager.unregister(this);
			dispatchState.unregistered = true;
			conn.close();
			conn = null;
			dispatchState.closed = true;
			assert(dispatchState.watchdog.isWaiting(),
				"libev watcher probe dispatch reached an inactive watchdog");
			dispatchState.watchdog.cancel();
		}

		final void close()
		{
			assert(conn !is null, "closing an already closed libev watcher probe");
			socketManager.unregister(this);
			conn.close();
			conn = null;
		}
	}

	private bool libevWatcherProbePinned(GenericSocket socket)
	{
		return (GC.getAttr(cast(void*)socket) & GC.BlkAttr.NO_MOVE) != 0;
	}

	// The conservative collector accepts NO_MOVE but deliberately does not
	// retain it in getAttr. Check the active bit whenever the runtime exposes
	// it, while evRooted remains the portable balance authority for root/pin.
	private bool libevNoMoveIsObservable()
	{
		static bool initialized;
		static bool observable;
		if (!initialized)
		{
			auto block = new ubyte[1];
			auto pointer = cast(void*)block.ptr;
			GC.setAttr(pointer, GC.BlkAttr.NO_MOVE);
			observable = (GC.getAttr(pointer) & GC.BlkAttr.NO_MOVE) != 0;
			GC.clrAttr(pointer, GC.BlkAttr.NO_MOVE);
			initialized = true;
		}
		return observable;
	}

	private void assertLibevWatcherProbeState(
		LibevWatcherProbe probe,
		bool readActive,
		bool writeActive,
		bool rooted,
		string stage)
	{
		assert(probe.notifyRead == readActive,
			stage ~ ": unexpected read watcher state");
		assert(probe.notifyWrite == writeActive,
			stage ~ ": unexpected write watcher state");
		assert((probe.evRead.data !is null) == readActive,
			stage ~ ": unexpected read watcher publication");
		assert((probe.evWrite.data !is null) == writeActive,
			stage ~ ": unexpected write watcher publication");
		assert(!!ev_is_active(&probe.evRead) == readActive,
			stage ~ ": unexpected native read watcher state");
		assert(!!ev_is_active(&probe.evWrite) == writeActive,
			stage ~ ": unexpected native write watcher state");
		if (readActive)
			assert(probe.evRead.data is cast(void*)probe,
				stage ~ ": read watcher has the wrong owner");
		if (writeActive)
			assert(probe.evWrite.data is cast(void*)probe,
				stage ~ ": write watcher has the wrong owner");
		assert(probe.evRooted == rooted,
			stage ~ ": unexpected shared root state");
		if (libevNoMoveIsObservable())
			assert(libevWatcherProbePinned(probe) == rooted,
				stage ~ ": unexpected NO_MOVE state");
	}

	/// Exercise the focused LIBEV owner-retention tests from either the module
	/// unittest runner or a package-scoped disposable runner.
	package(ae) void testLibevWatcherOwners()
	{
		import core.time : seconds;
		import std.socket : socketPair;

		// The two embedded watcher directions must share one root/pin pair,
		// while registration itself must retain neither.
		{
			auto managerBaseline = socketManager.size();
			auto pair = socketPair();
			pair[0].blocking = false;
			auto probe = new LibevWatcherProbe(pair[0]);

			assert(socketManager.size() == managerBaseline + 1,
				"registered libev watcher probe did not increment the manager size");
			assertLibevWatcherProbeState(probe, false, false, false,
				"registration alone");

			probe.notifyRead = true;
			assertLibevWatcherProbeState(probe, true, false, true, "after starting read");
			probe.notifyWrite = true;
			assertLibevWatcherProbeState(probe, true, true, true, "after starting write");

			probe.notifyRead = false;
			assertLibevWatcherProbeState(probe, false, true, true, "after stopping read");
			probe.notifyWrite = false;
			assertLibevWatcherProbeState(probe, false, false, false, "after stopping write");

			probe.notifyRead = true;
			probe.notifyWrite = true;
			assertLibevWatcherProbeState(probe, true, true, true, "after restarting both");
			probe.notifyWrite = false;
			assertLibevWatcherProbeState(probe, true, false, true, "after stopping write");
			probe.notifyRead = false;
			assertLibevWatcherProbeState(probe, false, false, false, "after stopping read");

			probe.close();
			pair[1].close();
			assert(socketManager.size() == managerBaseline,
				"libev watcher probe did not restore the socket-manager baseline");
		}

		// Native libev only sees raw pointers to embedded watchers. Verify that
		// its callback reaches an owner retained solely by the active watcher root.
		{
			auto managerBaseline = socketManager.size();
			assert(!mainTimer.hasNonDaemonTasks(),
				"libev forced-GC watcher test requires no pending non-daemon timer");

			auto pair = socketPair();
			pair[0].blocking = false;
			auto peer = pair[1];
			auto state = new LibevWatcherDispatchState;

			void armWatcher(Socket socket, LibevWatcherDispatchState dispatchState)
			{
				auto probe = new LibevWatcherProbe(socket, dispatchState);
				assertLibevWatcherProbeState(probe, false, false, false,
					"forced-GC registration alone");
				probe.notifyRead = true;
				assertLibevWatcherProbeState(probe, true, false, true,
					"forced-GC active read watcher");
				probe = null;
			}

			armWatcher(pair[0], state);
			pair = typeof(pair).init;

			ubyte[][] pressure;
			foreach (i; 0 .. 256)
			{
				auto block = new ubyte[64 * 1024];
				block[0] = cast(ubyte)i;
				pressure ~= block;
			}
			assert(pressure.length == 256,
				"libev forced-GC watcher test did not allocate pressure");
			pressure = null;
			GC.collect();
			GC.minimize();

			ubyte[1] ping = [0xA5];
			assert(peer.send(ping[]) == ping.length,
				"libev forced-GC watcher test could not make the peer readable");

			TimerTask watchdog = setTimeout({
				assert(false, "libev rooted watcher was not dispatched within one second");
			}, 1.seconds);
			assert(!watchdog.daemon,
				"libev forced-GC watcher watchdog unexpectedly became daemon work");
			state.watchdog = watchdog;

			socketManager.loop();

			assert(state.callbacks == 1,
				"libev forced-GC watcher callback did not execute exactly once");
			assert(state.ownerBalanceHeldDuringDispatch,
				"libev forced-GC watcher lost its owner balance before callback dispatch");
			assert(state.ownerBalanceReleasedAfterNativeStop,
				"libev forced-GC watcher did not release owner balance after native stop");
			assert(state.unregistered && state.closed,
				"libev forced-GC watcher callback did not unregister and close itself");
			assert(!watchdog.isWaiting(),
				"libev forced-GC watcher callback did not cancel its watchdog");

			peer.close();
			assert(socketManager.size() == managerBaseline,
				"libev forced-GC watcher test did not restore the socket-manager baseline");
			assert(!mainTimer.hasNonDaemonTasks(),
				"libev forced-GC watcher test leaked a non-daemon timer");
		}
	}

	debug (ae_unittest) unittest
	{
		testLibevWatcherOwners();
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
		{
			static if (eventLoopMechanism == EventLoopMechanism.iocp)
				// ConnectEx delivers the connecting→connected transition via an
				// IOCP completion, not via a writable-edge.  Suppress the kick.
				notifyWrite = false;
			else
				notifyWrite = true;
		}
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

			// Repository streams already verify connected state, a consumer, and
			// current interest. ConnectionlessSocketConnection remains tolerant
			// because an IOCP WSARecvFrom may have consumed a datagram when state
			// or the read handler changes.
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
				updateFlags();
				//setIdleTimeout(30.seconds);
				if (disconnectHandler)
					disconnectHandler(reason, type);
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
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
			if (_iocpSendBuffer !is null)
				return true;
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

	/// Maximum number of buffers gathered into one `doSendVec` call.
	/// Kept well below IOV_MAX (1024 on Linux, 16 on some BSDs was the
	/// historical minimum; POSIX guarantees at least 16).
	enum maxSendBuffers = 16;

	/// Send multiple buffers with one operation, if the transport
	/// supports scatter/gather I/O.
	/// The fallback implementation sends the buffers one at a time,
	/// stopping at the first short or failed send.
	/// Returns the total number of bytes sent, or `Socket.ERROR`
	/// if nothing was sent and an error occurred.
	sizediff_t doSendVec(scope const(void)[][] buffers)
	{
		sizediff_t total = 0;
		foreach (buffer; buffers)
		{
			auto sent = doSend(buffer);
			if (sent == Socket.ERROR)
				return total ? total : Socket.ERROR;
			total += sent;
			if (sent < buffer.length)
				break;
		}
		return total;
	}

	/// Called when a stream is readable.
	override void onReadable()
	{
		assert(state == ConnectionState.connected,
			"onReadable called on a %s stream connection".format(state));
		assert(readDataHandler,
			"onReadable called with null stream readDataHandler");
		assert(notifyRead,
			"onReadable called while stream read notifications are disabled");
		super.onReadable();
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		//scope(success) updateFlags();
		onWritableImpl();
		updateFlags();
	}

	// Shared connect-complete logic for POSIX (called from onWritableImpl) and
	// IOCP (called from iocpOnConnectComplete after SO_UPDATE_CONNECT_CONTEXT).
	package final void _handleConnectComplete()
	{
		state = ConnectionState.connected;

		try
			setKeepAlive();
		catch (Exception e)
			return disconnect(e.msg, DisconnectType.error);
		if (connectHandler)
			connectHandler();

		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			// Safety net: if data was queued before connect (unusual — public
			// connect() requires disconnected state so the queue is empty), the
			// notifyWrite setter was suppressed while in connecting state.
			// Also handles the case where connectHandler queued a send but the
			// state has already changed (e.g. to disconnecting).
			if (writePending && _iocpSendBuffer is null)
				socketManager.kickWritable(this);
			updateFlags();
		}
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
			_handleConnectComplete();
			return;
		}
		//debug writefln(remoteAddressStr, ": Writable - handler ", handleBufferFlushed?"OK":"not set", ", outBuffer.length=", outBuffer.length);

		foreach (sendPartial; [true, false])
			foreach (int priority, ref queue; outQueue)
				while (queue.length && (!sendPartial || priority == partiallySent))
				{
					assert(partiallySent == -1 || partiallySent == priority);

					// Gather a run of buffers from the head of the queue, so
					// that transports supporting scatter/gather I/O can send
					// them with one system call.
					// In the partial pass, complete the partially-sent Data
					// alone: the rest of its queue must not jump ahead of
					// higher-priority queues.
					const(void)[][maxSendBuffers] buffers;
					size_t numBuffers, numData;
					size_t bytesGathered;
					auto dataLimit = sendPartial ? 1 : queue.length;
					foreach (ref data; queue[])
					{
						if (numData == dataLimit || numBuffers == maxSendBuffers)
							break;
						if (!data.empty)
						{
							buffers[numBuffers++] = data.unsafeContents;
							bytesGathered += data.length;
						}
						numData++;
					}

					ptrdiff_t sent = 0;
					if (numBuffers)
					{
						sent = doSendVec(buffers[0 .. numBuffers]);
						debug (ASOCKETS) stderr.writefln("\t\t%s: sent %d/%d bytes (%d buffers)", this, sent, bytesGathered, numBuffers);

						if (sent == Socket.ERROR)
						{
							if (wouldHaveBlocked())
								return;
							else
								return onError("send() error: " ~ lastSocketError);
						}
						assert(sent <= bytesGathered);
					}
					else
					{
						debug (ASOCKETS) stderr.writefln("\t\t%s: %d empty Data objects", this, numData);
					}

					// Pop whole sent Data items off the queue.
					size_t remaining = sent;
					foreach (i; 0 .. numData)
					{
						if (remaining < queue.front.length)
							break;
						remaining -= queue.front.length;
						queue.front.clear();
						queue.popFront();
						partiallySent = -1;
					}

					if (remaining)
					{
						// The queue front was sent only partially.
						queue.front = queue.front[remaining..queue.front.length];
						partiallySent = priority;
					}

					if (queue.length == 0)
						queue = null;

					if (sent < bytesGathered)
						return; // Socket buffer is full
				}

		// outQueue is now empty
		// On IOCP, the last WSASend may still be in flight even though the queue is
		// empty (we dequeue eagerly after posting the overlapped op).  Defer the
		// flush/close notifications until iocpOnSendComplete clears _iocpSendBuffer.
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
			if (_iocpSendBuffer !is null)
				return;
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

	this(Socket conn, Address peerAddress, bool datagram = false)
	{
		super(conn);
		this.datagram = datagram;
		cachedAddress[false] = peerAddress;
	}

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			if (!datagram)
				return _iocpDoSend(buffer);
		}
		return conn.send(buffer);
	}

	override sizediff_t doSendVec(scope const(void)[][] buffers)
	{
		if (datagram)
			return super.doSendVec(buffers); // Preserve datagram boundaries

		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			return _iocpDoSendVec(buffers);
		}
		else
		version (Posix)
		{
			import core.sys.posix.sys.uio : iovec, writev;

			iovec[maxSendBuffers] iov = void;
			assert(buffers.length <= iov.length);
			foreach (i, buffer; buffers)
			{
				iov[i].iov_base = cast(void*)buffer.ptr;
				iov[i].iov_len = buffer.length;
			}
			return writev(conn.handle, iov.ptr, cast(int)buffers.length);
		}
		else
			return super.doSendVec(buffers);
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
			static if (eventLoopMechanism == EventLoopMechanism.iocp)
			{
				// Create the socket with WSA_FLAG_OVERLAPPED so it can
				// participate in IOCP (mirrors the AcceptEx candidate path).
				auto sock = WSASocketW(
					cast(int)addressInfo.family,
					cast(int)addressInfo.type,
					cast(int)addressInfo.protocol,
					null, 0, WSA_FLAG_OVERLAPPED);
				if (sock == c_socks.INVALID_SOCKET)
					throw new SocketOSException("WSASocketW failed");
				conn = new Socket(cast(socket_t)sock, addressInfo.family);
				conn.blocking = false;
				if (_noDelay && addressInfo.protocol == ProtocolType.TCP)
					setNoDelay();

				// ConnectEx requires the socket to be bound first.
				_iocpBindWildcard(conn, addressInfo.family);

				socketManager.register(this);
				debug (ASOCKETS) stderr.writefln("Attempting connection to %s",
					addressInfo.address.toString());
				_iocpArmConnect(addressInfo.address);
			}
			else
			{
				conn = new Socket(addressInfo.family, addressInfo.type, addressInfo.protocol);
				conn.blocking = false;
				if (_noDelay && addressInfo.protocol == ProtocolType.TCP)
					setNoDelay();

				socketManager.register(this);
				updateFlags();
				debug (ASOCKETS) stderr.writefln("Attempting connection to %s",
					addressInfo.address.toString());
				conn.connect(addressInfo.address);
			}
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
	/// Whether to disable Nagle's algorithm (TCP_NODELAY) on TCP
	/// connections.  While a TCP socket exists, this queries and sets
	/// the socket option directly; otherwise, the stored setting is
	/// applied when the socket is created.
	/// Has no effect on non-TCP (e.g. Unix-domain or datagram)
	/// connections.
	@property bool noDelay()
	{
		if (conn !is null && !datagram && isTcpFamily(conn.addressFamily))
		{
			int32_t value;
			conn.getOption(SocketOptionLevel.TCP, SocketOption.TCP_NODELAY, value);
			return value != 0;
		}
		return _noDelay;
	}

	/// ditto
	@property void noDelay(bool value)
	{
		_noDelay = value;
		if (conn !is null && !datagram && isTcpFamily(conn.addressFamily))
			setNoDelay(value);
	}

	private bool _noDelay = true;

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
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
			assert(!socketManager.hasIocpOps(this),
				"previous IOCP generation has not drained");

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

	this(Socket conn, Address peerAddress)
	{
		super(conn, peerAddress, false);
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

// Whether a stream socket of this address family is a TCP socket
// (and thus accepts TCP-level socket options such as TCP_NODELAY).
private bool isTcpFamily(AddressFamily family)
{
	return family == AddressFamily.INET || family == AddressFamily.INET6;
}

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
			static if (eventLoopMechanism == EventLoopMechanism.iocp)
				_iocpIsListener = true;
			socketManager.register(this);
		}

		/// Called when a socket is readable.
		override void onReadable()
		{
			debug (ASOCKETS) stderr.writefln("Accepting connection from listener @ %s", cast(void*)this);

			static if (eventLoopMechanism == EventLoopMechanism.iocp)
			{
				// AcceptEx path: iocpOnAcceptComplete() already created the
				// socket and stored the peer address for us.
				if (_iocpAcceptReady)
				{
					_iocpAcceptReady = false;
					auto acceptSocket = new Socket(_iocpAcceptedFd, conn.addressFamily);
					acceptSocket.blocking = false;
					if (handleAccept)
					{
						auto connection = createConnection(acceptSocket, _iocpAcceptedPeer);
						debug (ASOCKETS) stderr.writefln("\tAccepted connection %s from %s",
							connection, connection.remoteAddressStr);
						connection.setKeepAlive();
						connection.noDelay = noDelay;
						acceptHandler(connection);
					}
					else
						acceptSocket.close();
					return;
				}
			}

			// Use C accept() directly to atomically capture the peer address.
			// This avoids a race condition where the peer disconnects before
			// we can call getpeername(), which would fail with ENOTCONN.
			// TODO: Use Phobos accept(out Address) overload once available:
			// https://github.com/dlang/phobos/pull/10941
			ubyte[128] buf; // Enough for any socket address (sockaddr_storage is 128 bytes)
			auto sa = cast(c_socks.sockaddr*)buf.ptr;
			c_socks.socklen_t saLen = buf.length;
			auto newsock = c_socks.accept(conn.handle, sa, &saLen);
			if (newsock == cast(typeof(newsock))-1)
				throw new SocketOSException("Unable to accept socket connection");

			auto peerAddress = new UnknownAddressReference(cast(const(c_socks.sockaddr)*)sa, saLen);
			auto acceptSocket = new Socket(cast(socket_t)newsock, conn.addressFamily);
			acceptSocket.blocking = false;
			if (handleAccept)
			{
				auto connection = createConnection(acceptSocket, peerAddress);
				debug (ASOCKETS) stderr.writefln("\tAccepted connection %s from %s", connection, connection.remoteAddressStr);
				connection.setKeepAlive();
				connection.noDelay = noDelay;
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

	SocketConnection createConnection(Socket socket, Address peerAddress)
	{
		return new SocketConnection(socket, peerAddress, datagram);
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
	/// $(PARAM backlog) is the kernel-side SYN/accept-queue depth passed to $(D listen(2)).
	final void listen(AddressInfo[] addressInfos, int backlog = 1024)
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
				conn.listen(backlog);

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

	/// Whether to disable Nagle's algorithm (TCP_NODELAY) on accepted
	/// TCP connections.  Takes effect for connections accepted after
	/// the change.
	@property bool noDelay() { return _noDelay; }

	/// ditto
	@property void noDelay(bool value) { _noDelay = value; }

	private bool _noDelay = true;

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
	override SocketConnection createConnection(Socket socket, Address peerAddress)
	{
		return new TcpConnection(socket, peerAddress);
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
	/// $(PARAM backlog) is forwarded to the underlying $(D SocketServer.listen) call.
	final ushort listen(ushort port, string addr = null, int backlog = 1024)
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

		listen(addressInfos, backlog);

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
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
		{
			// On IOCP, WSARecvFrom already read the datagram into _iocpDgramBuf.
			// Return those bytes instead of calling recv() (which would find nothing).
			// Use ptr != null (not length > 0) to correctly handle zero-byte datagrams.
			if (_iocpDgramData.ptr !is null)
			{
				import std.algorithm.comparison : min;
				auto n = min(buffer.length, _iocpDgramData.length);
				if (n > 0)
					buffer[0 .. n] = _iocpDgramData[0 .. n];
				_iocpDgramData = null;
				return cast(sizediff_t)n;
			}
		}
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
		static if (eventLoopMechanism == EventLoopMechanism.iocp)
			_iocpIsDatagram = (type == SocketType.DGRAM);
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

// Exercises the IOCP WSARecvFrom path for datagram sockets.
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		import ae.sys.timing : setTimeout;
		import core.time : seconds;

		enum payload = "iocp-udp-test";

		auto server = new UdpConnection();
		server.bind("127.0.0.1", 0);

		auto client = new UdpConnection();
		client.initialize(server.localAddress.addressFamily);
		client.remoteAddress = server.localAddress;

		bool received;
		TimerTask t = setTimeout({
			assert(false, "IOCP UDP test timed out after 10s");
		}, 10.seconds);

		server.handleReadData = (Data data)
		{
			assert(cast(string)data.toGC.idup == payload,
				"IOCP UDP: unexpected payload: " ~ cast(string)data.toGC.idup);
			received = true;
			t.cancel();
			server.close();
			client.close();
		};

		client.send(Data(payload.asBytes));

		socketManager.loop();
		assert(received, "IOCP UDP: handleReadData was never called");
	}
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

	/// Called by the wrapped connection when data is available.
	/// Can also be called directly to inject e.g. initial buffered data.
	/// Note: downstream data handler (`handleReadData`) must be set up
	/// before calling this method.
	public void onReadData(Data data)
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
		this.send(datum.asSlice, priority);
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

debug(ae_unittest) unittest
{
	// Regression test: LineBufferedAdapter must append its delimiter to
	// outgoing data, regardless of which `send` overload is used.
	static class CaptureConnection : IConnection
	{
		ubyte[] sent;

		@property ConnectionState state() { return ConnectionState.connected; }

		void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
		{
			foreach (ref d; data)
				d.enter((contents) { sent ~= cast(ubyte[])contents; });
		}
		alias send = IConnection.send;

		void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested) {}
		@property void handleConnect(ConnectHandler value) {}
		@property void handleReadData(ReadDataHandler value) {}
		@property void handleDisconnect(DisconnectHandler value) {}
		@property void handleBufferFlushed(BufferFlushedHandler value) {}
	}

	auto capture = new CaptureConnection;
	auto line = new LineBufferedAdapter(capture);
	line.delimiter = "\n";
	line.sendDelimiter = "\r\n";

	line.send("hello");
	assert(cast(string)capture.sent == "hello\r\n", cast(string)capture.sent);

	capture.sent = null;
	line.send(Data("world".asBytes));
	assert(cast(string)capture.sent == "world\r\n", cast(string)capture.sent);
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

// ***************************************************************************

// Regression: a requested delayed disconnect must withdraw epoll read
// interest before its callback can recursively run the manager.
version (Posix)
static if (eventLoopMechanism == EventLoopMechanism.epoll)
debug(ae_unittest) unittest
{
	import core.time : Duration;
	import std.socket : SocketShutdown, socketPair, wouldHaveBlocked;

	class CountingSocketConnection : SocketConnection
	{
		int readableEntries;

		this(Socket socket)
		{
			super(socket);
		}

		override void onReadable()
		{
			readableEntries++;
			super.onReadable();
		}
	}

	// Another module may retain a daemon anchor socket; preserve that otherwise
	// idle baseline rather than treating it as part of this regression.
	auto idleManagerSize = socketManager.size();
	assert(!mainTimer.hasNonDaemonTasks(),
		"recursive disconnect regression test requires no pending non-daemon timer");

	auto pair = socketPair();
	pair[0].blocking = false;

	// Leave the peer's receive side undrained so the tested endpoint's kernel
	// send buffer becomes full before the library queues its own output.
	ubyte[64 * 1024] fill = 0x5A;
	size_t kernelBytesQueued;
	while (true)
	{
		auto sent = pair[0].send(fill[]);
		if (sent == Socket.ERROR)
		{
			assert(wouldHaveBlocked(),
				"filling the stream pair failed for a reason other than would-block");
			break;
		}
		assert(sent > 0, "nonblocking stream pair send made no progress");
		kernelBytesQueued += sent;
	}
	assert(kernelBytesQueued > 0, "stream pair send buffer did not accept any data");

	auto connection = new CountingSocketConnection(pair[0]);
	connection.handleReadData = (Data) {
		assert(false, "EOF must not reach the managed read handler");
	};
	connection.send(Data(cast(const(ubyte)[])"library queued output"));
	assert(connection.writePending,
		"library output was not queued after the kernel send buffer filled");
	assert(connection.notifyRead,
		"installed stream read handler did not enable read interest");
	assert(connection.notifyWrite,
		"queued library output did not enable write interest");

	// Make EOF readable without allowing the peer to drain the blocked output.
	pair[1].shutdown(SocketShutdown.SEND);
	connection.daemonWrite = true;
	assert(connection.writePending,
		"daemonizing the write direction discarded pending output");
	assert(connection.notifyWrite,
		"daemonizing the write direction disabled pending write interest");

	TimerTask cleanup;
	bool cleanupRan;
	bool nestedLoopReturned;
	int disconnectCalls;
	int cleanupCalls;
	connection.handleDisconnect = (string, DisconnectType type) {
		disconnectCalls++;
		assert(type == DisconnectType.requested,
			"delayed disconnect callback received the wrong disconnect type");
		assert(connection.state == ConnectionState.disconnecting,
			"delayed disconnect callback observed the wrong connection state");
		assert(connection.writePending,
			"delayed disconnect callback lost pending output");
		assert(!connection.notifyRead,
			"delayed disconnect callback observed stale read interest");
		assert(connection.notifyWrite,
			"delayed disconnect callback lost pending write interest");

		cleanup = setTimeout({
			assert(!cleanup.isWaiting(),
				"recursive cleanup timer was still waiting while it ran");
			assert(!nestedLoopReturned,
				"recursive socket-manager loop returned before cleanup");
			assert(!cleanupRan,
				"recursive cleanup ran more than once");
			assert(connection.state == ConnectionState.disconnecting,
				"recursive cleanup observed the wrong connection state");
			assert(connection.writePending,
				"recursive cleanup lost pending output");
			assert(!connection.notifyRead,
				"recursive cleanup restored read interest");
			assert(connection.notifyWrite,
				"recursive cleanup lost pending write interest");
			assert(connection.socket !is null,
				"recursive cleanup observed a closed socket");
			assert(socketManager.epollFd >= 0,
				"recursive cleanup observed a closed epoll descriptor");
			cleanupCalls++;
			connection.onError("recursive disconnect regression cleanup");
			cleanupRan = true;
		}, Duration.zero);
		assert(!cleanup.daemon,
			"recursive cleanup timer unexpectedly became daemon work");
		assert(cleanup.isWaiting(),
			"recursive cleanup timer was not waiting before loop entry");
		socketManager.loop();
		nestedLoopReturned = true;
	};

	connection.disconnect("recursive disconnect regression", DisconnectType.requested);

	assert(nestedLoopReturned, "recursive socket-manager loop did not return");
	assert(connection.readableEntries == 0,
		"recursive socket-manager loop dispatched a stale readable entry");
	assert(cleanupRan, "recursive cleanup timer did not run");
	assert(!cleanup.isWaiting(), "recursive cleanup timer remained waiting after the loop");
	assert(cleanupCalls == 1, "recursive cleanup did not run exactly once");
	assert(connection.state == ConnectionState.disconnected,
		"Connection.onError cleanup did not close the delayed connection");
	assert(connection.socket is null,
		"Connection.onError cleanup retained the tested socket");
	assert(disconnectCalls == 1,
		"recursive cleanup repeated the requested disconnect callback");

	pair[1].close();
	assert(socketManager.size() == idleManagerSize,
		"recursive disconnect regression test did not restore the idle socket-manager state");
	assert(!mainTimer.hasNonDaemonTasks(),
		"recursive disconnect regression test leaked a non-daemon timer");
}

// ***************************************************************************

// Regression: the epoll descriptor is manager-scoped.  A daemon socket is by
// definition still registered when socketManager.loop() returns, so loop()
// must not invalidate the descriptor its registration refers to.
version (Posix)
static if (eventLoopMechanism == EventLoopMechanism.epoll)
debug(ae_unittest) unittest
{
	import std.socket : socketPair;

	// Another module may retain a daemon anchor socket; preserve that otherwise
	// idle baseline rather than treating it as part of this regression.
	auto idleManagerSize = socketManager.size();
	assert(!mainTimer.hasNonDaemonTasks(),
		"epoll descriptor lifetime regression test requires no pending "
		~ "non-daemon timer");

	auto pair = socketPair();
	pair[0].blocking = false;
	auto conn = new SocketConnection(pair[0]);
	conn.handleReadData = (Data data) { assert(false, "unexpected read"); };
	conn.daemonRead = true;

	assert(socketManager.epollFd >= 0,
		"registering a socket did not create the epoll descriptor");
	assert(socketManager.size() == idleManagerSize + 1);

	socketManager.loop();

	// The daemon socket is still registered, so its epoll registration must
	// still refer to a live descriptor.
	assert(socketManager.size() == idleManagerSize + 1,
		"the daemon socket did not survive socketManager.loop()");
	assert(socketManager.epollFd >= 0,
		"socketManager.loop() invalidated the epoll descriptor of a "
		~ "surviving registered socket");

	// Both paths that a surviving socket reaches next must succeed:
	// an interest change (updateEpoll) and unregistration.
	conn.handleReadData = null;
	assert(!conn.notifyRead,
		"withdrawing the read handler did not clear read interest");
	conn.disconnect();
	pair[1].close();

	assert(socketManager.epollFd >= 0);
	assert(socketManager.size() == idleManagerSize,
		"the epoll descriptor lifetime regression test did not restore the "
		~ "idle socket-manager state");
}

// ***************************************************************************

// Regression: StreamConnection must reject every invalid readable entry
// before the shared Connection implementation can call doReceive.
debug(ae_unittest) unittest
{
	import core.exception : AssertError;

	class ReadableInvariantProbe : StreamConnection
	{
		int receiveCalls;

		this()
		{
			super();
		}

		override sizediff_t doSend(scope const(void)[] buffer)
		{
			return cast(sizediff_t)buffer.length;
		}

		override sizediff_t doReceive(scope void[])
		{
			receiveCalls++;
			return 0;
		}

		void enterReadable()
		{
			onReadable();
		}
	}

	void assertFailsBeforeReceive(ReadableInvariantProbe probe, string expectedDiagnostic)
	{
		string actualDiagnostic;
		try
			probe.enterReadable();
		catch (AssertError error)
			actualDiagnostic = error.msg;

		assert(actualDiagnostic == expectedDiagnostic,
			"unexpected stream readable invariant diagnostic: " ~ actualDiagnostic);
		assert(probe.receiveCalls == 0,
			"stream readable invariant invoked doReceive before failing: " ~ expectedDiagnostic);
	}

	auto nonconnected = new ReadableInvariantProbe;
	assertFailsBeforeReceive(nonconnected,
		"onReadable called on a disconnected stream connection");

	auto handlerless = new ReadableInvariantProbe;
	handlerless.state = ConnectionState.connected;
	assertFailsBeforeReceive(handlerless,
		"onReadable called with null stream readDataHandler");

	auto staleInterest = new ReadableInvariantProbe;
	staleInterest.state = ConnectionState.connected;
	// Deliberately bypass handleReadData: the test needs a consumer with stale
	// backend bookkeeping, which the public setter would immediately repair.
	staleInterest.readDataHandler = (Data) {};
	assert(!staleInterest.notifyRead,
		"direct raw handler assignment unexpectedly enabled read interest");
	assertFailsBeforeReceive(staleInterest,
		"onReadable called while stream read notifications are disabled");
}

// ***************************************************************************

// Regression: current stream handler/read interest governs dispatch even for
// readiness already observed by the event loop.
debug(ae_unittest) unittest
{
	import core.time : seconds;

	// Another module may retain a daemon anchor socket; preserve that otherwise
	// idle baseline rather than treating it as part of this regression.
	auto idleManagerSize = socketManager.size();
	assert(!mainTimer.hasNonDaemonTasks(),
		"stale sibling interest regression test requires no pending non-daemon timer");

	auto server = new TcpServer;
	TcpConnection[2] clients, accepted;
	void delegate(Data)[2] readHandlers;
	ubyte[][2] received;
	int acceptedCount;
	int connectedCount;
	int callbackCount;
	int firstIndex = -1;
	int restoredIndex = -1;
	bool siblingRestored;
	bool startQueued;
	bool started;
	bool finished;
	bool timedOut;
	TimerTask timeout;

	void cleanupAfterFailure()
	{
		foreach (connection; accepted)
			if (connection !is null && connection.state.disconnectable)
				connection.disconnect("stale sibling interest regression cleanup");
		foreach (connection; clients)
			if (connection !is null && connection.state.disconnectable)
				connection.disconnect("stale sibling interest regression cleanup");
		if (server.isListening)
			server.close();
	}

	void finish()
	{
		assert(!finished);
		finished = true;
		timeout.cancel();
		foreach (connection; accepted)
			if (connection.state.disconnectable)
				connection.disconnect("stale sibling interest regression complete");
		foreach (connection; clients)
			if (connection.state.disconnectable)
				connection.disconnect("stale sibling interest regression complete");
		if (server.isListening)
			server.close();
	}

	void maybeFinish()
	{
		if (received[0].length == 1 && received[1].length == 1)
			finish();
	}

	void onRead(size_t index, Data data)
	{
		if (firstIndex >= 0 && index != firstIndex)
		{
			assert(restoredIndex == index && siblingRestored,
				"sibling delivery ran before its read handler was restored");
		}

		received[index] ~= data.unsafeContents;
		callbackCount++;
		assert(callbackCount <= 2,
			"stale sibling interest regression delivered too many managed reads");
		assert(received[index].length == 1,
			"stale sibling interest regression received unexpected extra bytes");

		if (firstIndex < 0)
		{
			firstIndex = cast(int)index;
			auto sibling = 1 - index;
			accepted[sibling].handleReadData = null;
			onNextTick(socketManager, {
				accepted[sibling].handleReadData = readHandlers[sibling];
				restoredIndex = cast(int)sibling;
				siblingRestored = true;
			});
		}

		maybeFinish();
	}

	readHandlers[0] = (Data data) { onRead(0, data); };
	readHandlers[1] = (Data data) { onRead(1, data); };

	void start()
	{
		assert(!started);
		started = true;
		assert(acceptedCount == 2 && connectedCount == 2);

		assert(clients[0].socket.send("A") == 1);
		assert(clients[1].socket.send("B") == 1);

		// Establish public readiness for both accepted streams without consuming
		// either original byte before ae returns to its event loop.
		auto readSet = new SocketSet(1024);
		readSet.add(accepted[0].socket);
		readSet.add(accepted[1].socket);
		auto ready = Socket.select(readSet, null, null, 1.seconds);
		assert(ready == 2 &&
			readSet.isSet(accepted[0].socket) && readSet.isSet(accepted[1].socket),
			"could not establish readiness for both accepted loopback streams");
	}

	void maybeStart()
	{
		if (!startQueued && acceptedCount == 2 && connectedCount == 2)
		{
			startQueued = true;
			onNextTick(socketManager, &start);
		}
	}

	server.handleAccept = (TcpConnection connection) {
		assert(acceptedCount < 2);
		auto index = acceptedCount++;
		accepted[index] = connection;
		connection.handleReadData = readHandlers[index];
		maybeStart();
	};
	auto port = server.listen(0, "127.0.0.1");

	foreach (index; 0 .. 2)
	{
		clients[index] = new TcpConnection;
		clients[index].handleConnect = {
			connectedCount++;
			maybeStart();
		};
		clients[index].connect("127.0.0.1", port);
	}

	timeout = setTimeout({
		timedOut = true;
		cleanupAfterFailure();
	}, 5.seconds);

	socketManager.loop();

	assert(!timedOut, "stale sibling interest regression test timed out");
	assert(started && finished);
	assert(callbackCount == 2,
		"stale sibling interest regression did not deliver exactly two managed reads");
	assert(firstIndex == 0 || firstIndex == 1);
	assert(restoredIndex == 1 - firstIndex && siblingRestored);
	assert(received[0].length == 1 && received[1].length == 1);
	assert((received[0][0] == 'A' && received[1][0] == 'B') ||
		(received[0][0] == 'B' && received[1][0] == 'A'),
		"the two original loopback bytes were not delivered intact");
	foreach (connection; accepted)
		assert(connection.state == ConnectionState.disconnected);
	foreach (connection; clients)
		assert(connection.state == ConnectionState.disconnected);
	assert(!server.isListening);
	assert(!timeout.isWaiting());
	assert(socketManager.size() == idleManagerSize,
		"stale sibling interest regression test did not restore the idle socket-manager state");
	assert(!mainTimer.hasNonDaemonTasks(),
		"stale sibling interest regression test leaked a non-daemon timer");
}

// Regression: a peer FIN while a requested disconnect is flushing output must
// not dispatch a stale read or prevent the queued bytes from reaching the peer.
debug(ae_unittest) unittest
{
	import core.time : msecs, seconds;
	import std.algorithm.comparison : max;
	import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
		SocketOptionLevel, SocketShutdown, TcpSocket;

	// Another module may retain a daemon anchor socket; preserve that otherwise
	// idle baseline rather than treating it as part of this regression.
	auto idleManagerSize = socketManager.size();
	assert(!mainTimer.hasNonDaemonTasks(),
		"delayed disconnect FIN regression test requires no pending non-daemon timer");

	int socketBuffer(Socket socket, SocketOption option)
	{
		int32_t value;
		auto length = socket.getOption(SocketOptionLevel.SOCKET, option, value);
		assert(length == int32_t.sizeof,
			"integer socket-option read returned an unexpected length");
		assert(value > 0, "integer socket-option read returned a nonpositive value");
		return value;
	}

	enum requestedBuffer = 16 * 1024;
	enum chunkSize = 16 * 1024;
	enum bufferHeadroom = 16;
	enum minimumPayloadSize = 4 * 1024 * 1024;
	size_t payloadSize;
	size_t chunkCount;
	ubyte[] payload;
	Data[] chunks;

	auto listenerSocket = new TcpSocket(AddressFamily.INET);
	auto listenerDefaultRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	listenerSocket.setOption(
		SocketOptionLevel.SOCKET, SocketOption.RCVBUF, requestedBuffer);
	auto listenerAfterSetRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	listenerSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	listenerSocket.blocking = false;
	listenerSocket.bind(new InternetAddress("127.0.0.1", 0));
	auto listenerAfterBindRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	listenerSocket.listen(1);
	auto listenerAfterListenRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	auto port = (cast(InternetAddress)listenerSocket.localAddress).port;

	auto server = new TcpServer(listenerSocket);
	auto listenerAliveAfterConstructor = listenerSocket.isAlive;
	auto sender = new TcpConnection;
	TcpConnection peer;
	ubyte[] received;
	bool accepted;
	bool connected;
	bool startQueued;
	bool started;
	bool finished;
	bool timedOut;
	bool probeFired;
	bool releaseFired;
	bool serverClosed;
	bool listenerAliveBeforeClose;
	bool listenerAliveAfterClose;
	int senderReadCount;
	int senderDisconnectCount;
	int peerDisconnectCount;
	int flushCount;
	int serverCloseCount;
	int acceptedInheritedRcvbuf = -1;
	int acceptedAfterSetRcvbuf = -1;
	int senderBeforeSetSndbuf = -1;
	int senderAfterSetSndbuf = -1;
	int senderAtConnectSndbuf = -1;
	ConnectionState senderDisconnectState;
	ConnectionState flushState;
	DisconnectType senderDisconnectType;
	DisconnectType peerDisconnectType;
	TimerTask probeTimer;
	TimerTask releaseTimer;
	TimerTask timeout;

	void closeServer()
	{
		assert(!serverClosed, "raw listener server was closed more than once");
		serverClosed = true;
		listenerAliveBeforeClose = listenerSocket.isAlive;
		server.close();
		listenerAliveAfterClose = listenerSocket.isAlive;
	}

	void cleanupAfterFailure()
	{
		if (probeTimer !is null && probeTimer.isWaiting())
			probeTimer.cancel();
		if (releaseTimer !is null && releaseTimer.isWaiting())
			releaseTimer.cancel();
		// A timeout is not a successful requested disconnect. Detach the test's
		// success-only callbacks before closing endpoints, because disconnect()
		// invokes its handler synchronously when there is no pending output.
		sender.handleConnect = null;
		sender.handleReadData = null;
		sender.handleDisconnect = null;
		sender.handleBufferFlushed = null;
		if (peer !is null)
		{
			peer.handleReadData = null;
			peer.handleDisconnect = null;
			peer.handleBufferFlushed = null;
		}
		server.handleAccept = null;
		// The raw listener is owned by this test. Close it before endpoints so
		// an endpoint callback can never bypass listener ownership cleanup.
		closeServer();
		if (sender.state.disconnectable)
			sender.disconnect("delayed disconnect FIN regression cleanup");
		if (peer !is null && peer.state.disconnectable)
			peer.disconnect("delayed disconnect FIN regression cleanup");
	}

	void finish()
	{
		assert(!finished);
		finished = true;
		assert(received == payload,
			"peer payload differs from the bytes queued before disconnect");
		assert(probeFired && releaseFired,
			"terminal peer close preceded a required delayed event");
		assert(flushCount == 1,
			"terminal peer close preceded the exact sender flush");
		timeout.cancel();
		closeServer();
	}

	void onPeerRead(Data data)
	{
		received ~= data.unsafeContents;
		assert(received.length <= payload.length,
			"peer received more bytes than the sender queued");
	}

	sender.handleReadData = (Data) {
		senderReadCount++;
	};
	sender.handleDisconnect = (string, DisconnectType type) {
		senderDisconnectCount++;
		senderDisconnectState = sender.state;
		senderDisconnectType = type;
		assert(senderDisconnectCount == 1,
			"requested sender disconnect callback ran more than once");
		assert(senderDisconnectState == ConnectionState.disconnecting,
			"requested sender disconnect callback observed the wrong state");
		assert(type == DisconnectType.requested,
			"requested sender disconnect callback observed the wrong type");
	};
	sender.handleBufferFlushed = {
		flushCount++;
		flushState = sender.state;
		assert(flushCount == 1,
			"sender buffer-flushed callback ran more than once");
		assert(flushState == ConnectionState.disconnecting,
			"sender buffer-flushed callback observed the wrong state");
		assert(!sender.writePending && sender.bytesQueued == 0 &&
			sender.packetsQueued == 0,
			"sender flush callback observed pending application output");
	};

	void start()
	{
		assert(!started);
		started = true;
		assert(accepted && connected);
		assert(listenerDefaultRcvbuf > 0 && listenerAfterSetRcvbuf > 0 &&
			listenerAfterBindRcvbuf > 0 && listenerAfterListenRcvbuf > 0);
		assert(acceptedInheritedRcvbuf > 0 && acceptedAfterSetRcvbuf > 0);
		assert(senderBeforeSetSndbuf > 0 && senderAfterSetSndbuf > 0 &&
			senderAtConnectSndbuf > 0);
		auto largestEffectiveBuffer = max(listenerAfterListenRcvbuf,
			max(acceptedAfterSetRcvbuf, senderAtConnectSndbuf));
		auto largestEffectiveBufferSize = cast(size_t) largestEffectiveBuffer;
		assert(largestEffectiveBufferSize <=
			(size_t.max - (cast(size_t) chunkSize - 1)) /
				cast(size_t) bufferHeadroom,
			"effective socket buffer is too large to size delayed-FIN payload");
		auto roundedEffectivePayload =
			((cast(size_t) bufferHeadroom * largestEffectiveBufferSize +
			chunkSize - 1) / chunkSize) * chunkSize;
		payloadSize = max(cast(size_t) minimumPayloadSize, roundedEffectivePayload);
		chunkCount = payloadSize / chunkSize;
		payload = new ubyte[payloadSize];
		foreach (index, ref value; payload)
			value = cast(ubyte)((index * 31 + 7) & 0xff);
		chunks = new Data[chunkCount];
		foreach (index, ref chunk; chunks)
		{
			auto begin = index * chunkSize;
			chunk = Data(payload[begin .. begin + chunkSize]);
		}
		assert(payloadSize >= cast(size_t) bufferHeadroom * listenerAfterListenRcvbuf &&
			payloadSize >= cast(size_t) bufferHeadroom * acceptedAfterSetRcvbuf &&
			payloadSize >= cast(size_t) bufferHeadroom * senderAtConnectSndbuf,
			"runtime payload lacks effective socket-buffer headroom");

		sender.send(chunks);
		auto sendPending = sender.writePending;
		auto sendBytes = sender.bytesQueued;
		auto sendPackets = sender.packetsQueued;
		sender.disconnect("requested disconnect with queued output", DisconnectType.requested);
		auto disconnectPending = sender.writePending;
		auto disconnectBytes = sender.bytesQueued;
		auto disconnectPackets = sender.packetsQueued;

		assert(sender.state == ConnectionState.disconnecting,
			"send plus requested disconnect did not synchronously enter disconnecting");
		assert(sendPending && sendBytes == payloadSize && sendPackets == chunkCount,
			"one send(Data[]) call did not synchronously queue the full chunk vector");
		assert(disconnectPending && disconnectBytes == payloadSize &&
			disconnectPackets == chunkCount,
			"requested disconnect did not retain the full queued chunk vector");
		assert(senderDisconnectCount == 1,
			"requested sender disconnect callback was not synchronous");
		assert(senderReadCount == 0 && flushCount == 0,
			"I/O callback ran synchronously during send/disconnect setup");

		// Half-close only the peer-to-sender direction. The peer remains open to
		// receive and validate the sender's queued payload.
		peer.socket.shutdown(SocketShutdown.SEND);

		probeTimer = setTimeout({
			probeFired = true;
			assert(!releaseFired,
				"peer reader was released before the delayed FIN probe");
			assert(sender.state == ConnectionState.disconnecting,
				"sender left disconnecting before the delayed FIN probe");
			assert(sender.writePending && sender.bytesQueued > 0 &&
				sender.packetsQueued > 0,
				"sender application queue drained despite receiver backpressure");
			assert(senderReadCount == 0,
				"peer FIN reached the sender's managed read handler while disconnecting");
			assert(senderDisconnectCount == 1 && flushCount == 0 && received.length == 0,
				"unexpected callback or peer delivery preceded the release timer");
		}, 20.msecs);
		releaseTimer = setTimeout({
			releaseFired = true;
			peer.handleReadData = &onPeerRead;
		}, 100.msecs);
	}

	void maybeStart()
	{
		if (!startQueued && accepted && connected)
		{
			startQueued = true;
			onNextTick(socketManager, &start);
		}
	}

	server.handleAccept = (TcpConnection connection) {
		assert(!accepted);
		accepted = true;
		peer = connection;
		acceptedInheritedRcvbuf = socketBuffer(peer.socket, SocketOption.RCVBUF);
		peer.socket.setOption(
			SocketOptionLevel.SOCKET, SocketOption.RCVBUF, requestedBuffer);
		acceptedAfterSetRcvbuf = socketBuffer(peer.socket, SocketOption.RCVBUF);
		peer.handleDisconnect = (string, DisconnectType type) {
			peerDisconnectCount++;
			peerDisconnectType = type;
			assert(peerDisconnectCount == 1,
				"peer disconnect callback ran more than once");
			assert(type == DisconnectType.graceful,
				"peer did not observe a graceful sender close after the flush");
			assert(received == payload,
				"peer payload differs from the bytes queued before disconnect");
			finish();
		};
		maybeStart();
	};
	server.handleClose = { serverCloseCount++; };

	sender.handleConnect = {
		assert(!connected);
		connected = true;
		senderAtConnectSndbuf = socketBuffer(sender.socket, SocketOption.SNDBUF);
		maybeStart();
	};
	sender.connect("127.0.0.1", port);
	assert(sender.socket !is null,
		"TcpConnection did not expose its created socket after connect returned");
	senderBeforeSetSndbuf = socketBuffer(sender.socket, SocketOption.SNDBUF);
	sender.socket.setOption(
		SocketOptionLevel.SOCKET, SocketOption.SNDBUF, requestedBuffer);
	senderAfterSetSndbuf = socketBuffer(sender.socket, SocketOption.SNDBUF);

	timeout = setTimeout({
		timedOut = true;
		cleanupAfterFailure();
	}, 10.seconds);

	socketManager.loop();

	assert(!timedOut, "delayed disconnect FIN regression test timed out");
	assert(started && probeFired && finished);
	assert(senderReadCount == 0,
		"sender managed read handler ran while disconnecting");
	assert(senderDisconnectCount == 1 &&
		senderDisconnectType == DisconnectType.requested &&
		senderDisconnectState == ConnectionState.disconnecting,
		"requested sender disconnect callback did not run exactly once in disconnecting");
	assert(flushCount == 1 && flushState == ConnectionState.disconnecting,
		"sender buffer-flushed callback did not run exactly once in disconnecting");
	assert(peerDisconnectCount == 1 && peerDisconnectType == DisconnectType.graceful,
		"peer disconnect callback was not exactly one graceful close");
	assert(received == payload,
		"peer payload differs from the bytes queued before disconnect");
	assert(sender.state == ConnectionState.disconnected);
	assert(peer.state == ConnectionState.disconnected);
	assert(!sender.writePending && sender.bytesQueued == 0 &&
		sender.packetsQueued == 0,
		"sender queue was not empty after its successful flush");
	assert(serverClosed && !server.isListening);
	assert(listenerAliveAfterConstructor && listenerAliveBeforeClose &&
		!listenerAliveAfterClose,
		"raw listener did not transition from alive to dead when closed");
	assert(serverCloseCount == 1,
		"raw listener server close callback did not run exactly once");
	assert(!probeTimer.isWaiting());
	assert(!releaseTimer.isWaiting());
	assert(!timeout.isWaiting());
	assert(socketManager.size() == idleManagerSize,
		"delayed disconnect FIN regression test did not restore the idle socket-manager state");
	assert(!mainTimer.hasNonDaemonTasks(),
		"delayed disconnect FIN regression test leaked a non-daemon timer");
}

// Regression: positive data that becomes readable after requested disconnect
// must not be dispatched. StreamConnection rejects a stale dispatch before a
// shared receive could silently discard the late bytes.
debug(ae_unittest) unittest
{
	import core.time : msecs, seconds;
	import std.algorithm.comparison : max;
	import std.socket : AddressFamily, InternetAddress, Socket, SocketOption,
		SocketOptionLevel, TcpSocket;

	// Another module may retain a daemon anchor socket; preserve that otherwise
	// idle baseline rather than treating it as part of this regression.
	auto idleManagerSize = socketManager.size();
	assert(!mainTimer.hasNonDaemonTasks(),
		"late positive data regression test requires no pending non-daemon timer");

	int socketBuffer(Socket socket, SocketOption option)
	{
		int32_t value;
		auto length = socket.getOption(SocketOptionLevel.SOCKET, option, value);
		assert(length == int32_t.sizeof,
			"integer socket-option read returned an unexpected length");
		assert(value > 0, "integer socket-option read returned a nonpositive value");
		return value;
	}

	enum requestedBuffer = 16 * 1024;
	enum chunkSize = 16 * 1024;
	enum bufferHeadroom = 16;
	enum minimumPayloadSize = 4 * 1024 * 1024;
	size_t payloadSize;
	size_t chunkCount;
	ubyte[] payload;
	Data[] chunks;
	immutable latePayload = "late-positive-data";

	auto listenerSocket = new TcpSocket(AddressFamily.INET);
	auto listenerDefaultRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	listenerSocket.setOption(
		SocketOptionLevel.SOCKET, SocketOption.RCVBUF, requestedBuffer);
	auto listenerAfterSetRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	listenerSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	listenerSocket.blocking = false;
	listenerSocket.bind(new InternetAddress("127.0.0.1", 0));
	auto listenerAfterBindRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	listenerSocket.listen(1);
	auto listenerAfterListenRcvbuf = socketBuffer(listenerSocket, SocketOption.RCVBUF);
	auto port = (cast(InternetAddress)listenerSocket.localAddress).port;

	auto server = new TcpServer(listenerSocket);
	auto listenerAliveAfterConstructor = listenerSocket.isAlive;
	auto sender = new TcpConnection;
	TcpConnection peer;
	bool accepted;
	bool connected;
	bool startQueued;
	bool started;
	bool probeFired;
	bool finished;
	bool timedOut;
	bool serverClosed;
	bool listenerAliveBeforeClose;
	bool listenerAliveAfterClose;
	int senderReadCount;
	int senderDisconnectCount;
	int peerDisconnectCount;
	int flushCount;
	int serverCloseCount;
	int acceptedInheritedRcvbuf = -1;
	int acceptedAfterSetRcvbuf = -1;
	int senderBeforeSetSndbuf = -1;
	int senderAfterSetSndbuf = -1;
	int senderAtConnectSndbuf = -1;
	ConnectionState senderDisconnectState;
	DisconnectType senderDisconnectType;
	TimerTask probeTimer;
	TimerTask completionObserver;
	TimerTask timeout;

	void closeServer()
	{
		assert(!serverClosed, "raw listener server was closed more than once");
		serverClosed = true;
		listenerAliveBeforeClose = listenerSocket.isAlive;
		server.close();
		listenerAliveAfterClose = listenerSocket.isAlive;
	}

	void cleanupAfterFailure()
	{
		if (probeTimer !is null && probeTimer.isWaiting())
			probeTimer.cancel();
		if (completionObserver !is null && completionObserver.isWaiting())
			completionObserver.cancel();
		// A timeout is not a successful requested disconnect. Detach the test's
		// success-only callbacks before closing endpoints, because disconnect()
		// invokes its handler synchronously when there is no pending output.
		sender.handleConnect = null;
		sender.handleReadData = null;
		sender.handleDisconnect = null;
		sender.handleBufferFlushed = null;
		if (peer !is null)
		{
			peer.handleReadData = null;
			peer.handleDisconnect = null;
			peer.handleBufferFlushed = null;
		}
		server.handleAccept = null;
		// The raw listener is owned by this test. Close it before endpoints so
		// an endpoint callback can never bypass listener ownership cleanup.
		closeServer();
		if (sender.state.disconnectable)
			sender.disconnect("late positive data regression cleanup");
		if (peer !is null && peer.state.disconnectable)
			peer.disconnect("late positive data regression cleanup");
	}

	void finish()
	{
		assert(!finished);
		finished = true;
		completionObserver.cancel();
		timeout.cancel();
		closeServer();
	}

	sender.handleReadData = (Data) {
		senderReadCount++;
	};
	sender.handleDisconnect = (string, DisconnectType type) {
		senderDisconnectCount++;
		senderDisconnectState = sender.state;
		senderDisconnectType = type;
		assert(senderDisconnectCount == 1,
			"requested sender disconnect callback ran more than once");
		assert(senderDisconnectState == ConnectionState.disconnecting,
			"requested sender disconnect callback observed the wrong state");
		assert(type == DisconnectType.requested,
			"requested sender disconnect callback observed the wrong type");
	};
	sender.handleBufferFlushed = { flushCount++; };

	void start()
	{
		assert(!started);
		started = true;
		assert(accepted && connected);
		assert(listenerDefaultRcvbuf > 0 && listenerAfterSetRcvbuf > 0 &&
			listenerAfterBindRcvbuf > 0 && listenerAfterListenRcvbuf > 0);
		assert(acceptedInheritedRcvbuf > 0 && acceptedAfterSetRcvbuf > 0);
		assert(senderBeforeSetSndbuf > 0 && senderAfterSetSndbuf > 0 &&
			senderAtConnectSndbuf > 0);
		auto largestEffectiveBuffer = max(listenerAfterListenRcvbuf,
			max(acceptedAfterSetRcvbuf, senderAtConnectSndbuf));
		auto largestEffectiveBufferSize = cast(size_t) largestEffectiveBuffer;
		assert(largestEffectiveBufferSize <=
			(size_t.max - (cast(size_t) chunkSize - 1)) /
				cast(size_t) bufferHeadroom,
			"effective socket buffer is too large to size late-positive-data payload");
		auto roundedEffectivePayload =
			((cast(size_t) bufferHeadroom * largestEffectiveBufferSize +
			chunkSize - 1) / chunkSize) * chunkSize;
		payloadSize = max(cast(size_t) minimumPayloadSize, roundedEffectivePayload);
		chunkCount = payloadSize / chunkSize;
		payload = new ubyte[payloadSize];
		foreach (index, ref value; payload)
			value = cast(ubyte)((index * 31 + 7) & 0xff);
		chunks = new Data[chunkCount];
		foreach (index, ref chunk; chunks)
		{
			auto begin = index * chunkSize;
			chunk = Data(payload[begin .. begin + chunkSize]);
		}
		assert(payloadSize >= cast(size_t) bufferHeadroom * listenerAfterListenRcvbuf &&
			payloadSize >= cast(size_t) bufferHeadroom * acceptedAfterSetRcvbuf &&
			payloadSize >= cast(size_t) bufferHeadroom * senderAtConnectSndbuf,
			"runtime payload lacks effective socket-buffer headroom");

		sender.send(chunks);
		auto sendPending = sender.writePending;
		auto sendBytes = sender.bytesQueued;
		auto sendPackets = sender.packetsQueued;
		sender.disconnect("requested disconnect before late positive data", DisconnectType.requested);
		auto disconnectPending = sender.writePending;
		auto disconnectBytes = sender.bytesQueued;
		auto disconnectPackets = sender.packetsQueued;

		assert(sender.state == ConnectionState.disconnecting,
			"send plus requested disconnect did not synchronously enter disconnecting");
		assert(sendPending && sendBytes == payloadSize && sendPackets == chunkCount,
			"one send(Data[]) call did not synchronously queue the full chunk vector");
		assert(disconnectPending && disconnectBytes == payloadSize &&
			disconnectPackets == chunkCount,
			"requested disconnect did not retain the full queued chunk vector");
		assert(senderDisconnectCount == 1,
			"requested sender disconnect callback was not synchronous");
		assert(senderReadCount == 0 && flushCount == 0,
			"I/O callback ran synchronously during send/disconnect setup");

		assert(peer.socket.send(latePayload) == latePayload.length);
		auto readSet = new SocketSet(1024);
		readSet.add(sender.socket);
		auto ready = Socket.select(readSet, null, null, 1.seconds);
		assert(ready == 1 && readSet.isSet(sender.socket),
			"could not establish sender readability for late positive data");

		// A timer, unlike onNextTick, lets the event loop dispatch I/O first.
		probeTimer = setTimeout({
			probeFired = true;
			assert(sender.state == ConnectionState.disconnecting,
				"sender left disconnecting before the late-data probe");
			assert(sender.writePending && sender.bytesQueued > 0 &&
				sender.packetsQueued > 0,
				"sender application queue drained before the late-data probe");
			assert(senderReadCount == 0,
				"late positive data reached the sender's managed read handler");
			assert(senderDisconnectCount == 1 && flushCount == 0,
				"unexpected callback preceded late-data cleanup");

			// Closing with unread data may reset the peer. Both the reset close and
			// a successful drain/close are valid cleanup outcomes for this test.
			peer.disconnect("late positive data regression cleanup");
			completionObserver = setInterval({
				if (sender.state == ConnectionState.disconnected &&
					peer.state == ConnectionState.disconnected)
					finish();
			}, 1.msecs);
		}, 20.msecs);
	}

	void maybeStart()
	{
		if (!startQueued && accepted && connected)
		{
			startQueued = true;
			onNextTick(socketManager, &start);
		}
	}

	server.handleAccept = (TcpConnection connection) {
		assert(!accepted);
		accepted = true;
		peer = connection;
		acceptedInheritedRcvbuf = socketBuffer(peer.socket, SocketOption.RCVBUF);
		peer.socket.setOption(
			SocketOptionLevel.SOCKET, SocketOption.RCVBUF, requestedBuffer);
		acceptedAfterSetRcvbuf = socketBuffer(peer.socket, SocketOption.RCVBUF);
		peer.handleDisconnect = (string, DisconnectType) {
			peerDisconnectCount++;
			assert(peerDisconnectCount == 1,
				"peer disconnect callback ran more than once");
		};
		maybeStart();
	};
	server.handleClose = { serverCloseCount++; };

	sender.handleConnect = {
		assert(!connected);
		connected = true;
		senderAtConnectSndbuf = socketBuffer(sender.socket, SocketOption.SNDBUF);
		maybeStart();
	};
	sender.connect("127.0.0.1", port);
	assert(sender.socket !is null,
		"TcpConnection did not expose its created socket after connect returned");
	senderBeforeSetSndbuf = socketBuffer(sender.socket, SocketOption.SNDBUF);
	sender.socket.setOption(
		SocketOptionLevel.SOCKET, SocketOption.SNDBUF, requestedBuffer);
	senderAfterSetSndbuf = socketBuffer(sender.socket, SocketOption.SNDBUF);

	timeout = setTimeout({
		timedOut = true;
		cleanupAfterFailure();
	}, 10.seconds);

	socketManager.loop();

	assert(!timedOut, "late positive data regression test timed out");
	assert(started && probeFired && finished);
	assert(senderReadCount == 0,
		"sender managed read handler ran while disconnecting");
	assert(senderDisconnectCount == 1 &&
		senderDisconnectType == DisconnectType.requested &&
		senderDisconnectState == ConnectionState.disconnecting,
		"requested sender disconnect callback did not run exactly once in disconnecting");
	assert(peerDisconnectCount == 1,
		"peer disconnect callback did not run exactly once");
	assert(sender.state == ConnectionState.disconnected);
	assert(peer.state == ConnectionState.disconnected);
	assert(serverClosed && !server.isListening);
	assert(listenerAliveAfterConstructor && listenerAliveBeforeClose &&
		!listenerAliveAfterClose,
		"raw listener did not transition from alive to dead when closed");
	assert(serverCloseCount == 1,
		"raw listener server close callback did not run exactly once");
	assert(!probeTimer.isWaiting());
	assert(!completionObserver.isWaiting());
	assert(!timeout.isWaiting());
	assert(socketManager.size() == idleManagerSize,
		"late positive data regression test did not restore the idle socket-manager state");
	assert(!mainTimer.hasNonDaemonTasks(),
		"late positive data regression test leaked a non-daemon timer");
}

// ***************************************************************************

/// Test: TcpServer.listen() + TcpConnection.connect() — exercises AcceptEx on
/// Windows IOCP and the select/epoll accept path on POSIX.  Two sequential
/// connections verify that AcceptEx re-arming works.
debug(ae_unittest) unittest
{
	import std.conv : to;

	auto server = new TcpServer();
	ushort port = server.listen(0);

	int accepted, completed;
	string[2] srvRecv, cliRecv;
	bool[2] srvDone, cliDone;

	void startClient(int round)
	{
		auto client = new TcpConnection();
		client.handleConnect = () {
			client.send(Data("ping".asBytes.idup));
		};
		client.handleReadData = (Data data) {
			cliRecv[round] ~= cast(string)data.unsafeContents.idup;
			if (cliRecv[round] == "pong")
				client.disconnect("done");
		};
		client.handleDisconnect = (string, DisconnectType) {
			cliDone[round] = true;
			if (round == 0)
				onNextTick(socketManager, { startClient(1); });
			else
				server.close();
		};
		client.connect("127.0.0.1", port);
	}

	server.handleAccept = (TcpConnection c) {
		int round = accepted++;
		c.handleReadData = (Data data) {
			srvRecv[round] ~= cast(string)data.unsafeContents.idup;
			if (srvRecv[round] == "ping")
				c.send(Data("pong".asBytes.idup));
		};
		c.handleDisconnect = (string, DisconnectType) { srvDone[round] = true; completed++; };
	};

	startClient(0);
	socketManager.loop();

	assert(accepted   == 2, "expected 2 accepted, got " ~ to!string(accepted));
	assert(completed  == 2, "expected 2 completed, got " ~ to!string(completed));
	foreach (i; 0..2)
	{
		assert(srvRecv[i] == "ping");
		assert(cliRecv[i] == "pong");
		assert(srvDone[i]);
		assert(cliDone[i]);
	}
}

/// Test: the noDelay property reflects and controls the actual socket
/// option on a live connection, on both ends of the connection.
debug(ae_unittest) unittest
{
	auto server = new TcpServer();
	server.noDelay = true;
	ushort port = server.listen(0);

	bool serverChecked, clientChecked;

	server.handleAccept = (TcpConnection c) {
		assert(c.noDelay, "Accepted connection does not report TCP_NODELAY");
		serverChecked = true;
		c.disconnect();
		server.close();
	};

	auto client = new TcpConnection();
	client.noDelay = true;
	client.handleConnect = () {
		assert(client.noDelay, "Client does not report TCP_NODELAY");
		client.noDelay = false;
		assert(!client.noDelay, "TCP_NODELAY was not cleared");
		client.noDelay = true;
		assert(client.noDelay, "TCP_NODELAY was not restored");
		clientChecked = true;
		client.disconnect();
	};
	client.connect("127.0.0.1", port);

	socketManager.loop();
	assert(serverChecked && clientChecked);
}

// Stress test: 256 concurrent TCP connections, each sending/receiving data.
// Exercises the IOCP backend under load: many simultaneous WSARecv/WSASend
// operations, large IOCP completion queue, concurrent accept loop.
// Gated to IOCP because the test was authored against Windows kernel
// semantics (large default backlog, IOCP completion queue); on POSIX
// `select`-based loops it is sensitive to the listen-backlog tunable and
// the kernel phantom-accept behaviour, and historically broke unrelated
// integration-test binaries that happened to import ae.net.asockets.
static if (eventLoopMechanism == EventLoopMechanism.iocp)
debug(ae_unittest) unittest
{
	import std.conv : to;
	import ae.sys.timing : setTimeout;
	import core.time : seconds;

	enum N = 256;

	auto server = new TcpServer();
	ushort port = server.listen(0, "127.0.0.1");

	int serverAccepted;
	int serverCompleted;
	int clientCompleted;
	bool done;

	// Fail fast instead of hanging indefinitely (e.g. on small listen backlog).
	// Cancelled below on success so it doesn't keep the event loop alive.
	TimerTask timeoutTimer = setTimeout({
		import std.stdio : stderr;
		stderr.writefln("Stress test timed out: serverAccepted=%d serverCompleted=%d clientCompleted=%d",
			serverAccepted, serverCompleted, clientCompleted);
		assert(false, "Stress test timed out after 30s");
	}, 30.seconds);

	server.handleAccept = (TcpConnection c) {
		serverAccepted++;
		c.handleReadData = (Data data) {
			// Echo back whatever we receive
			c.send(Data(data.toGC.idup));
		};
		c.handleDisconnect = (string, DisconnectType) {
			serverCompleted++;
			if (serverCompleted == N)
				server.close();
		};
	};

	// Nested function to give each connection its own closure frame,
	// avoiding the D closure-in-loop variable-capture problem.
	void setupClient(int idx)
	{
		auto client = new TcpConnection();
		immutable payload = "hello-" ~ idx.to!string;
		string received;
		client.handleConnect = () {
			client.send(Data(cast(immutable ubyte[])payload));
		};
		client.handleReadData = (Data data) {
			received ~= cast(string)data.toGC.idup;
			if (received == payload)
				client.disconnect("done");
		};
		client.handleDisconnect = (string, DisconnectType) {
			assert(received == payload, "client " ~ payload ~ " got " ~ received);
			clientCompleted++;
			if (clientCompleted == N)
			{
				done = true;
				// Cancel the timeout timer so the event loop can exit now.
				timeoutTimer.cancel();
			}
		};
		client.connect("127.0.0.1", port);
	}

	foreach (i; 0 .. N)
		setupClient(i);

	socketManager.loop();
	assert(done, "stress test did not complete");
	assert(serverAccepted  == N, "expected " ~ N.to!string ~ " accepted, got "  ~ serverAccepted.to!string);
	assert(serverCompleted == N, "expected " ~ N.to!string ~ " srv done, got "  ~ serverCompleted.to!string);
	assert(clientCompleted == N, "expected " ~ N.to!string ~ " cli done, got "  ~ clientCompleted.to!string);
}

// Regression: IOCP completion status values are NTSTATUS codes and must be
// normalized before they are passed to socket completion handlers.
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		import std.format : format;

		enum ULONG_PTR success = 0;
		enum ULONG_PTR cancelled = 0xC0000120;
		enum ULONG_PTR unmapped = 0xDEADBEEF;

		assert(normalizeIocpStatus(success) == 0);
		assert(normalizeIocpStatus(cancelled) == ERROR_OPERATION_ABORTED);
		assert(normalizeIocpStatus(unmapped) == ERROR_MR_MID_NOT_FOUND,
			format("unmapped raw IOCP status 0x%08X", unmapped));
	}
}

// Regression: a failed IOCP send completion must report the send error rather
// than continue the writable path or repeat a requested disconnect callback.
// The same handle-free fixture covers the corresponding recv completion paths.
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		class PlaceholderSocket : Socket
		{
			this()
			{
				super();
			}

			override void close() scope @trusted nothrow @nogc
			{
			}
		}

		class RecordingTcpConnection : TcpConnection
		{
			string[] errorReasons;
			int readableCalls;
			int writableCalls;

		protected:
			override void onError(string reason)
			{
				errorReasons ~= reason;
			}

			override void onReadable()
			{
				readableCalls++;
				// Use the raw field so this handle-free fixture cannot try to
				// arm WSARecv after the successful completion callback.
				_notifyRead = false;
			}

			override void onWritable()
			{
				writableCalls++;
				auto previousState = state;
				state = ConnectionState.connected;
				super.onWritable();
				state = previousState;
			}
		}

		int requestedDisconnects;
		int bufferFlushedCalls;
		auto placeholder = new PlaceholderSocket;
		auto c = new RecordingTcpConnection;
		scope(exit)
		{
			c.conn = null;
			destroy(placeholder);
		}
		c.handleDisconnect = (string reason, DisconnectType type) {
			assert(type == DisconnectType.requested);
			requestedDisconnects++;
		};
		c.conn = placeholder;
		c.state = ConnectionState.connected;
		auto initialManagerSize = socketManager.size();

		void assertHandleFreePlaceholder()
		{
			assert(c.socket is placeholder,
				"direct IOCP completion replaced the placeholder socket");
			assert(placeholder.handle == socket_t.init,
				"direct IOCP completion used a real socket handle");
			assert(socketManager.size() == initialManagerSize,
				"direct IOCP completion registered a socket with the manager");
		}

		// Completion status has already been normalized at the IOCP dequeue
		// boundary.  These direct calls avoid a real socket and event loop.
		c._iocpRecvPending = true;
		c._notifyRead = false;
		iocpOnRecvComplete(c, 0, ERROR_OPERATION_ABORTED);
		assert(!c._iocpRecvPending,
			"aborted recv completion retained its pending flag");
		assert(c.readableCalls == 0,
			"aborted recv completion entered onReadable");
		assert(c.errorReasons.length == 0,
			"aborted recv completion reported an error");
		assertHandleFreePlaceholder();

		auto recvStatus = cast(uint)c_socks.WSAECONNRESET;
		c._iocpRecvPending = true;
		c._notifyRead = false;
		iocpOnRecvComplete(c, 0, recvStatus);
		assert(!c._iocpRecvPending,
			"failed recv completion retained its pending flag");
		assert(c.readableCalls == 0,
			"failed recv completion entered onReadable");
		assert(c.errorReasons.length == 1,
			"failed recv completion did not report exactly one error");
		assert(c.errorReasons[0] == "recv() error: " ~ formatSocketError(cast(int)recvStatus));
		assertHandleFreePlaceholder();

		c.errorReasons = null;
		c.readableCalls = 0;
		c._iocpRecvPending = true;
		c._notifyRead = false;
		iocpOnRecvComplete(c, 0, 0);
		assert(!c._iocpRecvPending,
			"uninterested successful recv completion retained its pending flag");
		assert(c.readableCalls == 0,
			"uninterested successful recv completion entered onReadable");
		assert(c.errorReasons.length == 0,
			"uninterested successful recv completion reported an error");
		assertHandleFreePlaceholder();

		c._iocpRecvPending = true;
		c._notifyRead = true;
		iocpOnRecvComplete(c, 0, 0);
		assert(!c._iocpRecvPending,
			"interested successful recv completion retained its pending flag");
		assert(c.readableCalls == 1,
			"interested successful recv completion did not enter onReadable");
		assert(c.errorReasons.length == 0,
			"interested successful recv completion reported an error");
		assert(!c._notifyRead,
			"readable callback did not withdraw raw read interest");
		assertHandleFreePlaceholder();

		c.errorReasons = null;
		c.readableCalls = 0;
		c._iocpSendBuffer = [cast(ubyte) 0];
		c._notifyWrite = true;
		c.bufferFlushedHandler = { bufferFlushedCalls++; };

		// The outstanding send makes this callback synchronous, without
		// registering a socket or driving the event loop.
		c.disconnect();
		assert(requestedDisconnects == 1,
			"requested disconnect callback was not delivered exactly once");

		auto status = cast(uint)c_socks.WSAECONNRESET;
		iocpOnSendComplete(c, 0, status);

		assert(c._iocpSendBuffer is null,
			"failed send completion retained its in-flight buffer");
		assert(c.errorReasons.length == 1,
			"failed send completion did not report exactly one error");
		assert(c.errorReasons[0] == "send() error: " ~ formatSocketError(cast(int)status));
		assert(c.readableCalls == 0, "failed send completion entered onReadable");
		assert(c.writableCalls == 0, "failed send completion continued writing");
		assert(bufferFlushedCalls == 0,
			"failed send completion called bufferFlushedHandler");
		assert(requestedDisconnects == 1,
			"failed send completion repeated the requested disconnect callback");
		assertHandleFreePlaceholder();
	}
}

// Regression: a successful stale stream probe must not consume data after
// public read interest was removed.  Restoring that interest must post a fresh
// probe and deliver the original byte once.
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		import ae.sys.timing : setInterval, setTimeout, TimerTask;
		import core.time : msecs, seconds;

		enum payload = "R";

		// `socketManager.loop()` returns only while idle.  Preserve that idle
		// baseline, which may include a daemon socket owned by another unittest.
		auto idleManagerSize = socketManager.size();
		auto server = new TcpServer;
		auto client = new TcpConnection;
		TcpConnection receiver;
		bool clientConnected;
		bool serverAccepted;
		bool setupScheduled;
		bool staleCompletionObserved;
		int delivered;
		string received;
		TimerTask staleCompletionObserver;
		TimerTask timeout;

		void finish()
		{
			assert(staleCompletionObserved,
				"stream byte was delivered before the stale probe completed");
			assert(delivered == 1,
				"restored stream read handler did not receive exactly one delivery");
			assert(received == payload,
				"restored stream read handler did not receive the original byte");
			timeout.cancel();
			receiver.disconnect();
			client.disconnect();
			server.close();
		}

		void scheduleStaleProbe()
		{
			if (!clientConnected || !serverAccepted || setupScheduled)
				return;
			setupScheduled = true;

			// The callbacks above may have run in either completion order.  Move
			// one tick forward so the accepted stream's initial zero-byte probe
			// has been posted before public read interest is removed.
			onNextTick(socketManager, {
				assert(receiver._iocpRecvPending,
					"accepted stream did not have an initial IOCP recv probe pending");
				receiver.handleReadData = null;
				client.send(Data(payload.asBytes.idup));

				staleCompletionObserver = setInterval({
					if (receiver._iocpRecvPending)
						return;

					staleCompletionObserver.cancel();
					assert(!receiver._iocpRecvPending,
						"stale successful recv completion did not clear pending state");
					assert(delivered == 0,
						"stale successful recv completion delivered data without read interest");
					staleCompletionObserved = true;

					receiver.handleReadData = (Data data) {
						delivered++;
						received ~= cast(string)data.unsafeContents.idup;
						finish();
					};
					assert(receiver._iocpRecvPending,
						"restoring public read interest did not post a fresh recv probe");
				}, 1.msecs);
			});
		}

		server.handleAccept = (TcpConnection c) {
			assert(!serverAccepted, "loopback test accepted more than one connection");
			receiver = c;
			receiver.handleReadData = (Data data) {
				assert(false, "initial read handler received data before interest was removed");
			};
			serverAccepted = true;
			scheduleStaleProbe();
		};

		auto port = server.listen(0, "127.0.0.1");
		client.handleConnect = {
			assert(!clientConnected, "loopback test connected more than once");
			clientConnected = true;
			scheduleStaleProbe();
		};
		client.connect("127.0.0.1", port);

		// Fail fast instead of letting a pre-fix stale-read regression hang.
		timeout = setTimeout({
			assert(false, "IOCP stale stream probe regression test timed out after 5s");
		}, 5.seconds);

		socketManager.loop();
		assert(staleCompletionObserved,
			"IOCP stale stream probe completion was never observed");
		assert(delivered == 1,
			"restored stream read handler did not receive exactly one delivery");
		assert(received == payload,
			"restored stream read handler did not receive the original byte");
		assert(socketManager.size() == idleManagerSize,
			"IOCP stale stream probe test did not restore the idle socket-manager state");
	}
}

// Regression: connectHandler that calls send() then disconnect() must still
// deliver the data on the IOCP backend. Without the fix the kick is skipped
// because state has already transitioned to disconnecting by the time the
// guard runs, leaving outQueue drained never and the event loop wedged.
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		bool received;
		auto srv = new TcpServer;
		srv.handleAccept = (TcpConnection s) {
			s.handleReadData = (Data d) {
				received = true;
				s.disconnect();
				srv.close();
			};
		};
		auto port = srv.listen(0, "127.0.0.1");

		auto c = new TcpConnection;
		c.handleConnect = {
			c.send(Data("ping".asBytes));
			c.disconnect();
		};
		c.connect("127.0.0.1", port);

		socketManager.loop();
		assert(received, "data sent in connectHandler was never delivered (IOCP kick bug)");
	}
}

// ConnectEx failure path: connect to a refused port drives onError → tryNextAddress.
// Verifies iocpOnConnectComplete's status != 0 branch is wired to disconnect(error).
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		import std.conv : to;
		import std.socket : InternetAddress;

		// Bind a TcpServer to get an ephemeral port, then close it.
		// Any connect attempt to that port will be refused (WSAECONNREFUSED).
		auto srv = new TcpServer;
		ushort refusedPort = srv.listen(0, "127.0.0.1");
		srv.close();

		string disconnectReason;
		DisconnectType disconnectType;
		bool disconnected;

		auto c = new TcpConnection;
		c.handleDisconnect = (string reason, DisconnectType type) {
			disconnectReason = reason;
			disconnectType   = type;
			disconnected     = true;
		};

		auto addr = new InternetAddress("127.0.0.1", refusedPort);
		c.connect([AddressInfo(addr.addressFamily, SocketType.STREAM,
			ProtocolType.TCP, addr, "127.0.0.1")]);

		socketManager.loop();
		assert(disconnected, "handleDisconnect not called after refused connect");
		assert(disconnectType == DisconnectType.error,
			"expected error disconnect, got " ~ disconnectType.to!string);
	}
}

// ConnectEx cancel path: disconnect() while ConnectEx in flight must not leak
// the socket and must call handleDisconnect exactly once.
// Uses AddressInfo[] overload to bypass DNS and arm ConnectEx synchronously.
debug(ae_unittest) version (Windows) unittest
{
	static if (eventLoopMechanism == EventLoopMechanism.iocp)
	{
		import std.conv : to;
		import std.socket : InternetAddress;

		int disconnectCount;
		DisconnectType disconnectType;

		auto c = new TcpConnection;
		c.handleDisconnect = (string reason, DisconnectType type) {
			disconnectCount++;
			disconnectType = type;
		};

		// 192.0.2.1 is TEST-NET-1 (RFC 5737) — unreachable, but we cancel
		// immediately.  Use AddressInfo[] to skip DNS and arm ConnectEx now.
		auto addr = new InternetAddress("192.0.2.1", 1);
		c.connect([AddressInfo(addr.addressFamily, SocketType.STREAM,
			ProtocolType.TCP, addr, "192.0.2.1")]);

		// Cancel the in-flight ConnectEx on the next event-loop tick.
		onNextTick(socketManager, { c.disconnect(); });

		socketManager.loop();
		assert(disconnectCount == 1,
			"handleDisconnect called " ~ disconnectCount.to!string ~ " times (expected 1)");
		assert(disconnectType == DisconnectType.requested,
			"expected requested disconnect, got " ~ disconnectType.to!string);
	}
}

// https://issues.dlang.org/show_bug.cgi?id=7016
// `resolveHost` above imports `ae.net.sync` only inside the function body,
// which `rdmd` does not detect as a dependency, breaking rdmd-built projects
// with a link error. Force the dependency with a module-level import.
// This must come *after* the definitions above (not next to the
// `ae.utils.array` workaround at the top of the module): `ae.net.sync`
// imports `ae.net.asockets` back, so importing it before `GenericSocket` is
// defined triggers a forward-reference error in `mixin SocketMixin`.
static import ae.net.sync;
