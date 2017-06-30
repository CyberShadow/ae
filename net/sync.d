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
	enum Command : ubyte
	{
		none,
		runWait,
		runAsync,
		runWaitDone,
	}

	alias Dg = void delegate();

	enum queueSize = 1024;

	final static class AnchorSocket : TcpConnection
	{
		Socket pinger;
		Dg[queueSize] queue;
		shared size_t readIndex, writeIndex;

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

			foreach (cmd; cast(Command[])data.contents)
			{
				Dg dg = queue[readIndex.atomicOp!"+="(1)-1 % $];
				switch (cmd)
				{
					case Command.runAsync:
						dg();
						break;
					case Command.runWait:
					{
						dg();
						Command[] reply = [Command.runWaitDone];
						this.send(Data(reply));
						break;
					}
					default:
						assert(false);
				}
			}
		}
	}

	AnchorSocket socket;

	void sendCommand(Command command) nothrow @nogc
	{
		// https://github.com/dlang/phobos/pull/4273
		(cast(void delegate(Command) nothrow @nogc)&sendCommandImpl)(command);
	}

	void sendCommandImpl(Command command)
	{
		Command[1] data;
		data[0] = command;
		socket.pinger.send(data[]);
	}

public:
	this(Flag!"daemon" = Yes.daemon)
	{
		socket = new AnchorSocket(daemon);
	}

	void runAsync(Dg dg) nothrow @nogc
	{
		socket.queue[socket.writeIndex.atomicOp!"+="(1)-1 % $] = dg;
		sendCommand(Command.runAsync);
	}

	void runWait(Dg dg)
	{
		socket.queue[socket.writeIndex.atomicOp!"+="(1)-1 % $] = dg;
		sendCommand(Command.runWait);

		Command[] data = [Command.none];
		data = data[0..socket.pinger.receive(data)];
		enforce(data.length && data[0] == Command.runWaitDone, "runWait error");
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
