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

import core.atomic;
import core.sync.semaphore;
import core.thread;

import std.exception;
import std.socket;
import std.typecons : Flag, Yes;

import ae.net.asockets;

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

	enum queueSize = 1024;

	final static class AnchorSocket : TcpConnection
	{
		Socket pinger;

		// Ensure the GC can reach delegates
		// Must be preallocated - can't allocate in signal handlers
		Command[queueSize] queue;
		shared size_t writeIndex;

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
			foreach (index; cast(size_t[])data.contents)
			{
				auto command = queue[index];
				queue[index] = Command.init;
				command.dg();
				if (command.semaphore)
					command.semaphore.notify();
			}
		}
	}

	AnchorSocket socket;

	void sendCommand(size_t index) nothrow @nogc
	{
		// https://github.com/dlang/phobos/pull/4273
		(cast(void delegate(size_t index) nothrow @nogc)&sendCommandImpl)(index);
	}

	void sendCommandImpl(size_t index)
	{
		size_t[1] data;
		data[0] = index;
		socket.pinger.send(data[]);
	}

	void runCommand(Command command) nothrow @nogc
	{
		assert(command.dg);
		auto index = (socket.writeIndex.atomicOp!"+="(1)-1) % queueSize;
		if (socket.queue[index].dg !is null)
			assert(false, "ThreadAnchor queue overrun");
		socket.queue[index] = command;
		sendCommand(index);
	}

public:
	this(Flag!"daemon" daemon = Yes.daemon)
	{
		socket = new AnchorSocket(daemon);
	}

	void runAsync(Dg dg) nothrow @nogc
	{
		runCommand(Command(dg));
	}

	void runWait(Dg dg)
	{
		scope semaphore = new Semaphore();
		runCommand(Command(dg, &semaphore));
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
