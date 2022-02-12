/**
 * Integration with and wrapper around ae.sys.shutdown
 * for networked (ae.net.asockets-based) applications.
 *
 * Unlike ae.sys.shutdown, the handlers are called from
 * within the same thread they were registered from -
 * provided that socketManager.loop() is running in that
 * thread.
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

// TODO: Unify addShutdownHandler under a common API.
// The host program should decide which shutdown
// driver to use.

// TODO: Add shuttingDown property

module ae.net.shutdown;

/// Register a handler to be called when a shutdown is requested.
/// The handler should close network connections and cancel timers,
/// thus removing all owned resources from the event loop which would
/// block it from exiting cleanly.
void addShutdownHandler(void delegate(scope const(char)[] reason) fn)
{
	handlers ~= fn;
	if (!registered)
		register();
}

deprecated void addShutdownHandler(void delegate() fn)
{
	addShutdownHandler((scope const(char)[] /*reason*/) { fn(); });
} /// ditto

/// Remove a previously-registered handler.
void removeShutdownHandler(void delegate(scope const(char)[] reason) fn)
{
	foreach (i, handler; handlers)
		if (fn is handler)
		{
			handlers = handlers[0 .. i] ~ handlers[i+1 .. $];
			return;
		}
	assert(false, "No such shutdown handler registered");
}

/// Calls all registered handlers.
void shutdown(scope const(char)[] reason)
{
	foreach_reverse (fn; handlers)
		fn(reason);
}

deprecated void shutdown()
{
	shutdown(null);
}

private:

static import ae.sys.shutdown;
import std.socket : socketPair;
import ae.net.asockets;
import ae.sys.data;

// Per-thread
void delegate(scope const(char)[] reason)[] handlers;
bool registered;

final class ShutdownConnection : TcpConnection
{
	Socket pinger;

	this()
	{
		auto pair = socketPair();
		pair[0].blocking = false;
		super(pair[0]);
		pinger = pair[1];
		this.handleReadData = &onReadData;
		addShutdownHandler(&onShutdown); // for manual shutdown calls
		this.daemonRead = true;
	}

	void ping(scope const(char)[] reason) //@nogc
	{
		static immutable ubyte[1] nullReason = [0];
		pinger.send(reason.length ? cast(ubyte[])reason : nullReason[]);
	}

	void onShutdown(scope const(char)[] reason)
	{
		pinger.close();
	}

	void onReadData(Data data)
	{
		auto dataBytes = cast(char[])data.contents;
		auto reason = dataBytes.length == 1 && dataBytes[0] == 0 ? null : dataBytes;
		shutdown(reason);
	}
}

void register()
{
	registered = true;
	auto socket = new ShutdownConnection();
	ae.sys.shutdown.addShutdownHandler(&socket.ping);
}
