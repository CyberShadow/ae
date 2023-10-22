/**
 * libev-based event loop.
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

module ae.sys.event.libev;

//version (LIBEV):

import deimos.ev;
pragma(lib, "ev");

// Watchers are a GenericSocket field (as declared in SocketMixin).
// Use one watcher per read and write event.
// Start/stop those as higher-level code declares interest in those events.
// Use the "data" ev_io field to store the parent GenericSocket address.
// Also use the "data" field as a flag to indicate whether the watcher is active
// (data is null when the watcher is stopped).

/// `libev`-based event loop implementation.
struct EventLoop
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

		// TODO? Need to get proper EventLoop instance to call updateTimer on
		eventLoop.preEvent();

		if (revents & EV_READ)
			socket.onReadable();
		else
		if (revents & EV_WRITE)
			socket.onWritable();
		else
			assert(false, "Unknown event fired from libev");

		eventLoop.postEvent(false);
	}

	ev_timer evTimer;
	MonoTime lastNextEvent = MonoTime.max;

	extern(C)
	static void timerCallback(ev_loop_t* l, ev_timer* w, int /*revents*/)
	{
		debug (ASOCKETS) stderr.writefln("Timer callback called.");

		eventLoop.preEvent(); // This also updates eventLoop.now
		mainTimer.prod(eventLoop.now);

		eventLoop.postEvent(true);
		debug (ASOCKETS) stderr.writefln("Timer callback exiting.");
	}

	/// Called upon waking up, before calling any users' event handlers.
	void preEvent()
	{
		eventLoop.now = MonoTime.currTime();
	}

	/// Called before going back to sleep, after calling any users' event handlers.
	void postEvent(bool wokeDueToTimeout)
	{
		while (nextTickHandlers.length)
		{
			auto thisTickHandlers = nextTickHandlers;
			nextTickHandlers = null;

			foreach (handler; thisTickHandlers)
				handler();
		}

		eventLoop.updateTimer(wokeDueToTimeout);
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
				auto remaining = mainTimer.getRemainingTime(eventLoop.now);
				while (remaining <= Duration.zero)
				{
					debug (ASOCKETS) stderr.writefln("remaining=%s, prodding timer.", remaining);
					mainTimer.prod(eventLoop.now);
					remaining = mainTimer.getRemainingTime(eventLoop.now);
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
		auto evLoop = ev_default_loop(0);
		enforce(evLoop, "libev initialization failure");

		updateTimer(true);
		debug (ASOCKETS) stderr.writeln("ev_run");
		ev_run(ev_default_loop(0), 0);
	}
}

/// Mixed in `GenericSocket`.
mixin template SocketMixin()
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
		// The LIBEV EventLoop holds no references to registered sockets.
		// TODO: Add a doubly-linked list?
		assert(evRead.data is null && evWrite.data is null, "Destroying a registered socket");
	}
}
