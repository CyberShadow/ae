/**
 * ae.net.sync
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

module ae.net.sync;

import core.sync.semaphore;
import core.thread;

import std.exception;
import std.socket;
import std.typecons : Flag, Yes;

import ae.net.asockets;
import ae.utils.array;

/**
	An object which allows calling a function in a different thread.
	Create ThreadAnchor in the main thread (the thread in which the
	code will run in), and then call runWait or runAsync from a
	different thread.

	The main thread must be running an unblocked ae.net.asockets
	event loop.

	Example:
	---
	void onConnect(TcpConnection socket)
	{
		auto anchor = new ThreadAnchor;
		new Thread({
			string s = readln();
			anchor.runAsync({
				socket.send(s);
				socket.disconnect();
			});
		}).start();
	}
	---
**/

final class ThreadAnchor : TcpConnection
{
private:
	alias Dg = void delegate();

	static struct Command
	{
		Dg dg;
		Semaphore* semaphore;
	}

	final static class AnchorSocket : TcpConnection
	{
		Socket pinger;
		Command[] queue;

		this(bool daemon)
		{
			auto pair = socketPair();
			pair[0].blocking = false;
			super(pair[0]);
			pinger = pair[1];
			this.handleReadData = &onReadData;
			this.daemon = daemon;
		}

		void onReadData(Data data)
		{
			import ae.utils.array;

			foreach (idx; cast(bool[])data.contents)
			{
				Command command;
				synchronized(this) command = queue.queuePop;
				command.dg();
				if (command.semaphore)
					command.semaphore.notify();
			}
		}
	}

	AnchorSocket socket;

	void ping() nothrow @nogc
	{
		// https://github.com/dlang/phobos/pull/4273
		(cast(void delegate() nothrow @nogc)&pingImpl)();
	}

	void pingImpl()
	{
		ubyte[1] data;
		socket.pinger.send(data[]);
	}

public:
	this(Flag!"daemon" daemon = Yes.daemon)
	{
		socket = new AnchorSocket(daemon);
	}

	void runAsync(Dg dg)
	{
		synchronized(socket) socket.queue.queuePush(Command(dg));
		ping();
	}

	void runWait(Dg dg)
	{
		scope semaphore = new Semaphore();
		synchronized(socket) socket.queue.queuePush(Command(dg, &semaphore));
		ping();

		semaphore.wait();
	}

	void close()
	{
		socket.pinger.close();
	}
}

unittest
{
	// keep socketManager running -
	// ThreadAnchor sockets are daemon
	auto dummy = new TcpServer();
	dummy.listen(0, "localhost");

	import ae.sys.timing;

	int n = 0;
	Thread t;

	// Queue to run this as soon as event loop starts
	setTimeout({
		auto anchor = new ThreadAnchor;
		t = new Thread({
			anchor.runWait({
				assert(n==0); n++;
			});
			anchor.runAsync(&dummy.close);
			assert(n==1); n++;
		}).start();
	}, Duration.zero);

	socketManager.loop();
	t.join();
	assert(n==2);
}
