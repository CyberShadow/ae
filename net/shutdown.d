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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.net.shutdown;

void addShutdownHandler(void delegate() fn)
{
	handlers ~= fn;
	if (handlers.length == 1) // first
		register();
}

/// Calls all registered handlers.
void shutdown()
{
	foreach (fn; handlers)
		fn();
}

private:

static import ae.sys.shutdown;
import std.socket : socketPair;
import ae.net.asockets;
import ae.sys.data;

// Per-thread
void delegate()[] handlers;

final class ShutdownSocket : ClientSocket
{
	Socket pinger;

	this()
	{
		auto pair = socketPair();
		super(pair[0]);
		pinger = pair[1];
		this.handleReadData = &onReadData;
		addShutdownHandler(&onShutdown); // for manual shutdown calls
		this.daemon = true;
	}

	void ping()
	{
		ubyte[] data = [42];
		pinger.send(data);
	}

	void onShutdown()
	{
		pinger.close();
	}

	void onReadData(ClientSocket socket, Data data)
	{
		shutdown();
	}
}

void register()
{
	auto socket = new ShutdownSocket();
	ae.sys.shutdown.addShutdownHandler(&socket.ping);
}
