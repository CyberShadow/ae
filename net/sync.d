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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.net.sync;

import core.atomic;
import core.sync.semaphore;
import core.thread;
import core.stdc.stdlib : abort;

import std.exception;
import std.socket;
import std.typecons : Flag, No, Yes;

import ae.net.asockets;

/**
	An object which allows calling a function in a different thread.
	Create ThreadAnchor in the main thread (the thread in which the
	code will run in), and then call runWait or runAsync from a
	different thread.

	The main thread must be running an unblocked ae.net.asockets
	event loop.

	The anchor and its target thread's manager must outlive submission.
	Another liveness owner or `armPending` must keep the target loop alive
	until a sender has completed the pinger send. Submitted callbacks must
	return normally; callback exceptions leave the current dispatch terminal.
	Close only after a successful submission.

	Example:
	---
	void onConnect(TcpConnection socket)
	{
		auto mainThread = thisThread;
		new Thread({
			string s = readln();
			mainThread.runAsync({
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
		debug (ae_unittest)
		{
			__gshared static void delegate(AnchorSocket, size_t) nothrow @nogc beforeSend;
			__gshared static void delegate(AnchorSocket, size_t) afterPendingDecrement;
			__gshared static void delegate(AnchorSocket, size_t) afterDaemonRestoration;
		}

		Socket pinger;

		// Ensure the GC can reach delegates
		// Must be preallocated - can't allocate in signal handlers
		Command[queueSize] queue;
		shared size_t writeIndex;

		// Tracks this anchor's pending commands for daemon-state restoration.
		shared size_t numPending;
		// Tracks submitted commands for the target loop after publication.
		// Another owner or armPending covers the pre-publication interval.
		shared(size_t)* targetSubmittedCommands;
		bool daemon;

		this(bool daemon)
		{
			targetSubmittedCommands = currentSubmittedCommandCount();
			auto pair = tcpSocketPair();
			pair[0].blocking = false;
			super(pair[0]);
			pinger = pair[1];
			this.handleReadData = &onReadData;
			this.daemon = daemon;
			this.daemonRead = daemon;
		}

		void onReadData(Data data)
		{
			data.asDataOf!size_t.enter((scope indices) {
				foreach (index; indices)
				{
					auto command = queue[index];
					queue[index] = Command.init;
					command.dg();
					if (command.semaphore)
						command.semaphore.notify();
				}
				auto remaining = numPending.atomicOp!"-="(indices.length);
				debug (ae_unittest)
					if (afterPendingDecrement)
						afterPendingDecrement(this, remaining);
				this.daemonRead = daemon && remaining == 0;
				debug (ae_unittest)
					if (afterDaemonRestoration)
						afterDaemonRestoration(this, remaining);
				decrementSubmittedCommands(targetSubmittedCommands, indices.length);
			});
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
		auto sent = socket.pinger.send(data[]);
		if (sent != size_t.sizeof)
			abort();
	}

	void runCommand(Command command) nothrow @nogc
	{
		assert(command.dg);
		auto index = (socket.writeIndex.atomicOp!"+="(1)-1) % queueSize;
		if (socket.queue[index].dg !is null)
			assert(false, "ThreadAnchor queue overrun");
		socket.queue[index] = command;
		atomicOp!"+="(socket.numPending, 1);
		incrementSubmittedCommands(socket.targetSubmittedCommands);
		debug (ae_unittest)
			if (socket.beforeSend)
				socket.beforeSend(socket, index);
		sendCommand(index);
	}

public:
	/// Constructor.
	/// Params:
	///  daemon  = If `Yes.daemon` (the default), don't block the event
	///            loop from exiting until `close` is called.
	this(Flag!"daemon" daemon = Yes.daemon)
	{
		socket = new AnchorSocket(daemon);
	}

	/// Pre-signal that a pending operation will be submitted later
	/// via `runAsync`. Keeps the event loop alive (by temporarily
	/// making this a non-daemon socket) until the callback completes.
	/// Must be called from the event loop thread.
	void armPending() nothrow @nogc
	{
		socket.daemonRead = false;
	}

	/// Cancel a previous `armPending` call. Restores the daemon state
	/// so this socket no longer prevents the event loop from exiting.
	/// Must be called from the event loop thread.
	void disarmPending() nothrow @nogc
	{
		socket.daemonRead = socket.daemon;
	}

	/// Run the specified normally returning delegate in the origin thread,
	/// without waiting for its callback to finish.
	/// Must be called from a different thread while the target loop remains live.
	void runAsync(Dg dg) nothrow @nogc
	{
		runCommand(Command(dg));
	}

	/// Run the specified normally returning delegate in the origin thread,
	/// and wait until its callback has run.
	/// Must be called from a different thread while the target loop remains live.
	void runWait(Dg dg)
	{
		scope semaphore = new Semaphore();
		runCommand(Command(dg, &semaphore));
		semaphore.wait();
	}

	/// Close the connection to the main thread.
	void close()
	{
		socket.pinger.close();
	}
}

debug (ae_unittest)
private final class ThreadAnchorCleanupState
{
	TcpServer owner;
	size_t expectedDisconnects;
	size_t disconnects;
	bool started;
}

/// Exercise submitted-command publication, acknowledgement, and cleanup from
/// either the module unittest runner or a package-scoped disposable runner.
debug (ae_unittest)
package(ae) void testThreadAnchorSubmittedCommandLiveness()
{
	// A default ThreadAnchor watcher remains natively referenced on LIBEV until
	// daemon socket directions are implemented. The separate LIBEV helper in
	// asockets.d isolates the S4 recovery path with an unreferenced watcher.
	static if (isLibevEventLoop)
		return;
	else
	{
		import ae.sys.timing;
		import std.conv : to;

		size_t iocpRetentionCount()
		{
			static if (isIocpEventLoop)
				return socketManager.testIocpRetentionCount();
			else
				return 0;
		}

		void waitFor(ref shared size_t value, size_t expected)
		{
			while (atomicLoad(value) != expected)
				Thread.yield();
		}

		void assertAnchorSettled(ThreadAnchor anchor, bool daemon, string stage)
		{
			assert(anchor.socket.targetSubmittedCommands !is null,
				stage ~ ": anchor did not capture a target counter");
			assert(atomicLoad(anchor.socket.numPending) == 0,
				stage ~ ": anchor retained pending commands");
			assert(atomicLoad(*anchor.socket.targetSubmittedCommands) == 0,
				stage ~ ": target counter remained nonzero");
			foreach (command; anchor.socket.queue)
			{
				assert(command.dg is null,
					stage ~ ": command ring retained a delegate");
				assert(command.semaphore is null,
					stage ~ ": command ring retained a semaphore");
			}
			assert(anchor.socket.daemonRead == daemon,
				stage ~ ": daemon state was not restored");
		}

		void assertCleanup(
			ThreadAnchorCleanupState cleanup,
			size_t managerBaseline,
			size_t retentionBaseline,
			string stage)
		{
			assert(cleanup.started,
				stage ~ ": cleanup owner was not created by the tested callback");
			assert(cleanup.disconnects == cleanup.expectedDisconnects,
				stage ~ ": anchor EOF cleanup did not complete");
			assert(socketManager.size() == managerBaseline,
				stage ~ ": socket-manager registration baseline was not restored");
			static if (isIocpEventLoop)
				assert(iocpRetentionCount() == retentionBaseline,
					stage ~ ": IOCP retention baseline was not restored");
			assert(!mainTimer.hasNonDaemonTasks(),
				stage ~ ": cleanup left non-daemon timer work");
		}

		void beginCleanup(ThreadAnchor[] anchors, ThreadAnchorCleanupState cleanup)
		{
			assert(!cleanup.started, "ThreadAnchor cleanup started more than once");
			cleanup.started = true;
			cleanup.expectedDisconnects = anchors.length;
			cleanup.owner = new TcpServer();
			cleanup.owner.listen(0, "localhost");
			cleanup.owner.handleAccept = (TcpConnection incoming) {};

			foreach (anchor; anchors)
			{
				anchor.socket.handleDisconnect = (string, DisconnectType) {
					assert(cleanup.disconnects < cleanup.expectedDisconnects,
						"ThreadAnchor cleanup disconnected an anchor twice");
					cleanup.disconnects++;
					if (cleanup.disconnects == cleanup.expectedDisconnects)
						cleanup.owner.close();
				};
			}

			foreach (anchor; anchors)
				anchor.close();
		}

		assert(!mainTimer.hasNonDaemonTasks(),
			"ThreadAnchor submitted-command tests require no pending non-daemon timer");

		// Preserve the established runWait/runAsync contract: runWait returns
		// after its callback, both callbacks execute on the target thread, and
		// cleanup begins only from the final asynchronous callback.
		{
			auto managerBaseline = socketManager.size();
			auto retentionBaseline = iocpRetentionCount();
			auto targetThread = Thread.getThis();
			auto anchor = new ThreadAnchor;
			auto cleanup = new ThreadAnchorCleanupState;
			auto owner = new TcpServer();
			owner.listen(0, "localhost");
			owner.handleAccept = (TcpConnection incoming) {};
			shared size_t waitMarker;
			shared size_t waitReturned;
			shared size_t asyncCallbacks;
			shared size_t asyncReturned;
			Thread worker;

			assert(anchor.socket.targetSubmittedCommands !is null,
				"runWait anchor did not capture a target counter");
			assert(atomicLoad(*anchor.socket.targetSubmittedCommands) == 0,
				"runWait anchor started with a nonzero target counter");

			setTimeout({
				worker = new Thread({
					anchor.runWait({
						assert(Thread.getThis() is targetThread,
							"runWait callback ran on the sender thread");
						atomicStore(waitMarker, 1);
					});
					assert(atomicLoad(waitMarker) == 1,
						"runWait returned before its callback marker was set");
					atomicStore(waitReturned, 1);
					anchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"runAsync callback ran on the sender thread");
						assert(atomicLoad(waitReturned) == 1,
							"runAsync callback preceded runWait completion");
						atomicOp!"+="(asyncCallbacks, 1);
						beginCleanup([anchor], cleanup);
						owner.close();
					});
					atomicStore(asyncReturned, 1);
				}).start();
			}, Duration.zero);

			socketManager.loop();
			worker.join();
			assert(atomicLoad(waitMarker) == 1 && atomicLoad(waitReturned) == 1,
				"runWait callback or return marker was not observed");
			assert(atomicLoad(asyncCallbacks) == 1 && atomicLoad(asyncReturned) == 1,
				"runAsync callback or sender return was not observed");
			assertAnchorSettled(anchor, true, "runWait/runAsync");
			assertCleanup(cleanup, managerBaseline, retentionBaseline, "runWait/runAsync");
		}

		// Let a zero-delay timer be the last pre-publication owner. Once the
		// sender has returned, the counter must keep an otherwise-idle loop alive
		// through the callback.
		{
			auto managerBaseline = socketManager.size();
			auto retentionBaseline = iocpRetentionCount();
			auto targetThread = Thread.getThis();
			auto anchor = new ThreadAnchor;
			auto cleanup = new ThreadAnchorCleanupState;
			shared size_t senderReturned;
			shared size_t boundaryObserved;
			shared size_t callbacks;
			Thread sender;

			setTimeout({
				sender = new Thread({
					anchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"otherwise-idle callback ran off the target thread");
						assert(atomicLoad(boundaryObserved) == 1,
							"otherwise-idle callback ran before the last owner disappeared");
						atomicOp!"+="(callbacks, 1);
						beginCleanup([anchor], cleanup);
					});
					atomicStore(senderReturned, 1);
				}).start();
				waitFor(senderReturned, 1);
				assert(atomicLoad(callbacks) == 0,
					"otherwise-idle callback ran before the timer owner ended");
				assert(atomicLoad(*anchor.socket.targetSubmittedCommands) == 1,
					"otherwise-idle handoff did not retain the submitted command");
				atomicStore(boundaryObserved, 1);
			}, Duration.zero);

			socketManager.loop();
			sender.join();
			assert(atomicLoad(senderReturned) == 1 && atomicLoad(boundaryObserved) == 1,
				"otherwise-idle sender did not return before owner removal");
			assert(atomicLoad(callbacks) == 1,
				"otherwise-idle callback did not execute exactly once");
			assertAnchorSettled(anchor, true, "otherwise-idle handoff");
			assertCleanup(cleanup, managerBaseline, retentionBaseline, "otherwise-idle handoff");
		}

		// Force the stale-restoration window. The first command remains in the
		// aggregate until after daemon restoration, so the follow-on command is
		// still visible when the old batch acknowledges completion.
		{
			auto managerBaseline = socketManager.size();
			auto retentionBaseline = iocpRetentionCount();
			auto targetThread = Thread.getThis();
			auto anchor = new ThreadAnchor;
			auto cleanup = new ThreadAnchorCleanupState;
			shared size_t initialReturned;
			shared size_t followOnReturned;
			shared size_t initialCallbacks;
			shared size_t followOnCallbacks;
			size_t pendingHookCalls;
			size_t restorationHookCalls;
			size_t aggregateBeforeInitialDecrement;
			size_t aggregateBeforeFollowOnDecrement;
			Thread initialWorker;
			Thread followOnWorker;

			ThreadAnchor.AnchorSocket.afterPendingDecrement = (socket, remaining) {
				assert(socket is anchor.socket,
					"restoration-race hook observed an unrelated anchor");
				pendingHookCalls++;
				if (pendingHookCalls == 1)
				{
					assert(remaining == 0,
						"initial restoration-race batch did not empty its local count");
					followOnWorker = new Thread({
						anchor.runAsync({
							assert(Thread.getThis() is targetThread,
								"follow-on callback ran off the target thread");
							atomicOp!"+="(followOnCallbacks, 1);
							beginCleanup([anchor], cleanup);
						});
						atomicStore(followOnReturned, 1);
					}).start();
					waitFor(followOnReturned, 1);
					assert(atomicLoad(socket.numPending) == 1,
						"follow-on submission did not repopulate the local count");
				}
				else
				{
					assert(pendingHookCalls == 2 && remaining == 0,
						"restoration-race hook ran outside the two intended batches");
				}
			};
			ThreadAnchor.AnchorSocket.afterDaemonRestoration = (socket, remaining) {
				assert(socket is anchor.socket,
					"restoration-state hook observed an unrelated anchor");
				restorationHookCalls++;
				assert(remaining == 0 && socket.daemonRead == socket.daemon,
					"daemon restoration did not use the completed batch state");
				if (restorationHookCalls == 1)
				{
					assert(atomicLoad(socket.numPending) == 1,
						"follow-on submission was not locally pending through restoration");
					aggregateBeforeInitialDecrement = atomicLoad(*socket.targetSubmittedCommands);
					assert(aggregateBeforeInitialDecrement == 2,
						"target aggregate did not retain both restoration-race commands");
				}
				else
				{
					assert(restorationHookCalls == 2,
						"restoration-state hook ran outside the two intended batches");
					aggregateBeforeFollowOnDecrement = atomicLoad(*socket.targetSubmittedCommands);
					assert(aggregateBeforeFollowOnDecrement == 1,
						"follow-on acknowledgement saw the wrong target aggregate");
				}
			};
			scope (exit)
			{
				ThreadAnchor.AnchorSocket.afterPendingDecrement = null;
				ThreadAnchor.AnchorSocket.afterDaemonRestoration = null;
			}

			setTimeout({
				initialWorker = new Thread({
					anchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"initial restoration-race callback ran off the target thread");
						atomicOp!"+="(initialCallbacks, 1);
					});
					atomicStore(initialReturned, 1);
				}).start();
				waitFor(initialReturned, 1);
				assert(atomicLoad(initialCallbacks) == 0,
					"initial restoration-race callback ran before owner removal");
				assert(atomicLoad(*anchor.socket.targetSubmittedCommands) == 1,
					"initial restoration-race submission was not counted");
			}, Duration.zero);

			socketManager.loop();
			initialWorker.join();
			followOnWorker.join();
			assert(atomicLoad(initialReturned) == 1 && atomicLoad(followOnReturned) == 1,
				"restoration-race workers did not return from submission");
			assert(atomicLoad(initialCallbacks) == 1 && atomicLoad(followOnCallbacks) == 1,
				"restoration-race callbacks did not execute exactly once");
			assert(pendingHookCalls == 2 && restorationHookCalls == 2,
				"restoration-race hooks did not observe exactly two batches");
			assert(aggregateBeforeInitialDecrement == 2 && aggregateBeforeFollowOnDecrement == 1,
				"restoration-race aggregate ordering was not preserved");
			assertAnchorSettled(anchor, true, "restoration race");
			assertCleanup(cleanup, managerBaseline, retentionBaseline, "restoration race");
		}

		// Several commands submitted in one worker's call order, plus a second
		// anchor, must share one target aggregate without assuming cross-worker
		// callback ordering.
		{
			auto managerBaseline = socketManager.size();
			auto retentionBaseline = iocpRetentionCount();
			auto targetThread = Thread.getThis();
			auto firstAnchor = new ThreadAnchor;
			auto secondAnchor = new ThreadAnchor;
			auto cleanup = new ThreadAnchorCleanupState;
			auto targetCounter = firstAnchor.socket.targetSubmittedCommands;
			shared size_t beforeSendCalls;
			shared size_t firstWorkerReturned;
			shared size_t secondWorkerReturned;
			shared size_t callbacks;
			shared size_t secondCallbacks;
			int[] firstOrder;
			auto anchors = [firstAnchor, secondAnchor];
			Thread firstWorker;
			Thread secondWorker;

			assert(targetCounter !is null,
				"first multi-command anchor did not capture a target counter");
			assert(secondAnchor.socket.targetSubmittedCommands is targetCounter,
				"anchors on one target thread captured different counters");
			assert(atomicLoad(*targetCounter) == 0,
				"shared multi-command target counter did not start at zero");

			ThreadAnchor.AnchorSocket.beforeSend = (socket, index) nothrow @nogc {
				assert(socket is firstAnchor.socket || socket is secondAnchor.socket,
					"pre-send hook observed an unrelated anchor");
				assert(socket.queue[index].dg !is null,
					"pre-send hook observed an empty command slot");
				assert(atomicLoad(socket.numPending) != 0,
					"pre-send hook observed a zero local command count");
				assert(socket.targetSubmittedCommands is targetCounter,
					"pre-send hook observed the wrong target counter");
				assert(atomicLoad(*socket.targetSubmittedCommands) != 0,
					"pre-send hook observed an unincremented target count");
				atomicOp!"+="(beforeSendCalls, 1);
			};
			scope (exit) ThreadAnchor.AnchorSocket.beforeSend = null;

			void callbackCompleted()
			{
				auto completed = atomicOp!"+="(callbacks, 1);
				if (completed == 4)
					beginCleanup(anchors, cleanup);
			}

			setTimeout({
				firstWorker = new Thread({
					firstAnchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"first multi-command callback ran off the target thread");
						firstOrder ~= 1;
						callbackCompleted();
					});
					firstAnchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"second multi-command callback ran off the target thread");
						firstOrder ~= 2;
						callbackCompleted();
					});
					firstAnchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"third multi-command callback ran off the target thread");
						firstOrder ~= 3;
						callbackCompleted();
					});
					atomicStore(firstWorkerReturned, 1);
				}).start();
				secondWorker = new Thread({
					secondAnchor.runAsync({
						assert(Thread.getThis() is targetThread,
							"second-anchor callback ran off the target thread");
						atomicOp!"+="(secondCallbacks, 1);
						callbackCompleted();
					});
					atomicStore(secondWorkerReturned, 1);
				}).start();
				waitFor(firstWorkerReturned, 1);
				waitFor(secondWorkerReturned, 1);
				assert(atomicLoad(beforeSendCalls) == 4,
					"pre-send hook observed " ~ atomicLoad(beforeSendCalls).to!string
					~ " published commands (expected 4)");
				assert(atomicLoad(callbacks) == 0,
					"multi-command callbacks ran before the timer owner ended");
				assert(atomicLoad(firstAnchor.socket.numPending) == 3,
					"first anchor did not retain all sequential commands");
				assert(atomicLoad(secondAnchor.socket.numPending) == 1,
					"second anchor did not retain its command");
				assert(atomicLoad(*targetCounter) == 4,
					"shared target counter did not equal all published commands");
			}, Duration.zero);

			socketManager.loop();
			firstWorker.join();
			secondWorker.join();
			assert(atomicLoad(firstWorkerReturned) == 1 && atomicLoad(secondWorkerReturned) == 1,
				"multi-command workers did not return from submission");
			assert(atomicLoad(callbacks) == 4 && atomicLoad(secondCallbacks) == 1,
				"multi-command callbacks did not execute exactly once");
			assert(firstOrder == [1, 2, 3],
				"one worker's sequential command order was not preserved");
			assertAnchorSettled(firstAnchor, true, "first multi-command anchor");
			assertAnchorSettled(secondAnchor, true, "second multi-command anchor");
			assertCleanup(cleanup, managerBaseline, retentionBaseline, "multiple anchors");
		}

		// `armPending` remains a one-shot pre-publication reservation. Re-arm on
		// the target's next tick before a later runWait, then verify an unused arm
		// can still be cancelled without affecting the aggregate.
		{
			auto managerBaseline = socketManager.size();
			auto retentionBaseline = iocpRetentionCount();
			auto targetThread = Thread.getThis();
			auto anchor = new ThreadAnchor;
			auto cleanup = new ThreadAnchorCleanupState;
			shared size_t firstCallbacks;
			shared size_t rearmed;
			shared size_t secondCallbacks;
			shared size_t workerDone;

			anchor.armPending();
			assert(!anchor.socket.daemonRead,
				"armPending did not make the default anchor live");
			anchor.disarmPending();
			assert(anchor.socket.daemonRead,
				"disarmPending did not restore the default anchor state");
			assert(atomicLoad(*anchor.socket.targetSubmittedCommands) == 0,
				"unused arm changed the target command aggregate");
			anchor.armPending();

			auto worker = new Thread({
				anchor.runAsync({
					assert(Thread.getThis() is targetThread,
						"separately armed callback ran off the target thread");
					atomicOp!"+="(firstCallbacks, 1);
					onNextTick(socketManager, {
						assert(Thread.getThis() is targetThread,
							"re-arm next tick ran off the target thread");
						anchor.armPending();
						atomicStore(rearmed, 1);
					});
				});
				waitFor(rearmed, 1);
				anchor.runWait({
					assert(Thread.getThis() is targetThread,
						"re-armed runWait callback ran off the target thread");
					atomicOp!"+="(secondCallbacks, 1);
					beginCleanup([anchor], cleanup);
				});
				atomicStore(workerDone, 1);
			}).start();

			socketManager.loop();
			worker.join();
			assert(atomicLoad(firstCallbacks) == 1 && atomicLoad(rearmed) == 1,
				"separately armed runAsync did not complete and re-arm");
			assert(atomicLoad(secondCallbacks) == 1 && atomicLoad(workerDone) == 1,
				"re-armed runWait did not complete");
			assertAnchorSettled(anchor, true, "armPending compatibility");
			assertCleanup(cleanup, managerBaseline, retentionBaseline, "armPending compatibility");
		}

		// A non-daemon anchor remains an ordinary loop owner while preserving the
		// same runWait completion and cleanup protocol.
		{
			auto managerBaseline = socketManager.size();
			auto retentionBaseline = iocpRetentionCount();
			auto targetThread = Thread.getThis();
			auto anchor = new ThreadAnchor(No.daemon);
			auto cleanup = new ThreadAnchorCleanupState;
			shared size_t callbackMarker;
			shared size_t workerReturned;

			assert(!anchor.socket.daemon && !anchor.socket.daemonRead,
				"No.daemon anchor did not remain a live owner");
			auto worker = new Thread({
				anchor.runWait({
					assert(Thread.getThis() is targetThread,
						"No.daemon callback ran off the target thread");
					atomicStore(callbackMarker, 1);
					beginCleanup([anchor], cleanup);
				});
				assert(atomicLoad(callbackMarker) == 1,
					"No.daemon runWait returned before its callback");
				atomicStore(workerReturned, 1);
			}).start();

			socketManager.loop();
			worker.join();
			assert(atomicLoad(callbackMarker) == 1 && atomicLoad(workerReturned) == 1,
				"No.daemon runWait did not complete");
			assertAnchorSettled(anchor, false, "No.daemon compatibility");
			assertCleanup(cleanup, managerBaseline, retentionBaseline, "No.daemon compatibility");
		}
	}
}

debug (ae_unittest) unittest
{
	testThreadAnchorSubmittedCommandLiveness();
}

/// Return a `ThreadAnchor` for the current thread.
/// One instance is created and reused per thread.
@property ThreadAnchor thisThread()
{
	static ThreadAnchor instance;
	if (!instance)
		instance = new ThreadAnchor();
	return instance;
}

/// A version of `std.socket.socketPair` which always creates TCP sockets, like on Windows.
/// Used to work around https://stackoverflow.com/q/10899814/21501,
/// i.e. AF_UNIX socket pairs' limit of not being able
/// to enqueue more than 278 packets without blocking.
private Socket[2] tcpSocketPair() @trusted
{
	Socket[2] result;

	auto listener = new TcpSocket();
	listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
	listener.bind(new InternetAddress(INADDR_LOOPBACK, InternetAddress.PORT_ANY));
	auto addr = listener.localAddress;
	listener.listen(1);

	result[0] = new TcpSocket(addr);
	result[1] = listener.accept();

	listener.close();
	return result;
}
