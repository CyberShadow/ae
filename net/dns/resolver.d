/**
 * DNS worker-thread resolver backing `ae.net.asockets.resolveHost`.
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

module ae.net.dns.resolver;

import std.conv : to;
import std.exception;
import std.socket;

debug(ASOCKETS) import std.stdio : stderr;

private import ae.net.sync : ThreadAnchor;
private import ae.net.shutdown : addShutdownHandler, removeShutdownHandler;
private import ae.sys.timing : setTimeout, TimerTask;
private import core.sync.condition : Condition;
private import core.sync.mutex : Mutex;
private import core.thread : Thread;
private import core.time : Duration, MonoTime, msecs, seconds;

private final class DnsResolver
{
private:
	alias LookupFn = Address[] delegate(string host, ushort port);
	enum string shutdownError = "Lookup error: DNS resolver shut down";

	final class Operation
	{
		string host;
		ushort port;
		void delegate(Address[]) onSuccess;
		void delegate(string) onError;
		TimerTask timeoutTask;
		bool completed;
	}

	final class Worker
	{
		Thread thread;
		bool inLookup;
		bool exited;
	}

	final class WorkerRunner
	{
		DnsResolver resolver;
		Worker worker;

		void run()
		{
			resolver.workerLoop(worker);
		}
	}

	final class Delivery
	{
		DnsResolver resolver;
		Operation op;
		Address[] addresses;
		string error;
		Worker worker;

		void deliverResult()
		{
			resolver.handleResult(op, addresses, error);
		}

		void deliverExit()
		{
			resolver.handleWorkerExit(worker);
		}
	}

	ThreadAnchor anchor;
	Mutex mutex;
	Condition cond;
	Operation[] jobs;
	Operation[] operations;
	Worker[] workers;
	size_t idleWorkers;
	size_t busyWorkers;
	size_t pendingOperations;
	LookupFn lookup;
	Duration operationTimeout;
	Duration idleTimeout;
	bool shutdownStarted;
	bool anchorClosed;
	bool shuttingDown;
	void delegate(scope const(char)[] reason) shutdownHandler;

	debug(ae_unittest)
	{
		size_t workerCreations;
		size_t anchorAllocations;
		void delegate(string host, ushort port) onWorkerDequeued;
		bool pauseDequeues;
	}

	void initialize(LookupFn lookup, Duration operationTimeout, Duration idleTimeout)
	{
		this.lookup = lookup;
		this.operationTimeout = operationTimeout;
		this.idleTimeout = idleTimeout;

		anchor = new ThreadAnchor();
		mutex = new Mutex(this);
		cond = new Condition(mutex);
		debug(ae_unittest) anchorAllocations++;

		shutdownHandler = (scope const(char)[] reason) {
			shutdown(reason);
		};
		addShutdownHandler(shutdownHandler);
	}

	void spawnWorkerLocked()
	{
		auto worker = new Worker();
		auto runner = new WorkerRunner();
		runner.resolver = this;
		runner.worker = worker;
		Thread thread = new Thread(&runner.run);
		thread.isDaemon = true;
		worker.thread = thread;
		workers ~= worker;
		debug(ae_unittest) workerCreations++;
		thread.start();
	}

	void joinAndRemoveExitedWorkers()
	{
		Worker[] exitedWorkers;
		synchronized (mutex)
		{
			for (size_t i = 0; i < workers.length; )
			{
				auto worker = workers[i];
				if (!worker.exited)
				{
					i++;
					continue;
				}

				exitedWorkers ~= worker;
				workers = workers[0 .. i] ~ workers[i + 1 .. $];
			}
		}

		foreach (worker; exitedWorkers)
			worker.thread.join(false);
	}

	void maybeCloseAnchor()
	{
		if (!shutdownStarted || anchorClosed)
			return;

		bool hasWorkers;
		synchronized (mutex)
			hasWorkers = workers.length > 0;

		if (hasWorkers)
			return;

		anchor.close();
		anchorClosed = true;
	}

	void workerLoop(Worker worker)
	{
		for (;;)
		{
			Operation op;
			bool retire;
			debug(ae_unittest) bool notifyDequeued;

			synchronized (mutex)
			{
				idleWorkers++;

				auto deadline = MonoTime.currTime + idleTimeout;
				while (jobs.length == 0)
				{
					if (shuttingDown)
					{
						retire = true;
						worker.exited = true;
						break;
					}

					auto remaining = deadline - MonoTime.currTime;
					if (remaining <= Duration.zero)
					{
						retire = true;
						worker.exited = true;
						break;
					}
					cond.wait(remaining);
				}

				if (!retire)
				{
					debug(ae_unittest)
						while (pauseDequeues && !shuttingDown)
							cond.wait();

					if (shuttingDown)
					{
						idleWorkers--;
						retire = true;
						worker.exited = true;
						break;
					}
				}

				idleWorkers--;

				if (!retire)
				{
					op = jobs[0];
					jobs = jobs[1 .. $];
					busyWorkers++;
					worker.inLookup = true;
					debug(ae_unittest) notifyDequeued = onWorkerDequeued !is null;
				}
			}

			if (retire)
				break;

			debug(ae_unittest) if (notifyDequeued) onWorkerDequeued(op.host, op.port);
			Address[] addresses;
			string error;
			try
			{
				addresses = lookup(op.host, op.port);
				enforce(addresses.length, "No addresses found");
			}
			catch (Exception e)
				error = "Lookup error: " ~ e.msg;

			synchronized (mutex)
			{
				busyWorkers--;
				worker.inLookup = false;
			}

			auto delivery = new Delivery();
			delivery.resolver = this;
			delivery.op = op;
			delivery.addresses = addresses;
			delivery.error = error;
			anchor.runAsync(&delivery.deliverResult);
		}

		auto exitNotice = new Delivery();
		exitNotice.resolver = this;
		exitNotice.worker = worker;
		anchor.runAsync(&exitNotice.deliverExit);
	}

	void handleResult(Operation op, Address[] addresses, string error)
	{
		completeOperation(op, true, addresses, error);
	}

	void handleWorkerExit(Worker worker)
	{
		joinAndRemoveExitedWorkers();
		maybeCloseAnchor();
	}

	void removeOperation(Operation op)
	{
		foreach (i, candidate; operations)
			if (candidate is op)
			{
				operations = operations[0 .. i] ~ operations[i + 1 .. $];
				return;
			}

		assert(false, "Operation not tracked");
	}

	void completeOperation(Operation op, bool cancelTimeout, Address[] addresses, string error)
	{
		if (op.completed)
			return;

		op.completed = true;
		removeOperation(op);
		if (cancelTimeout && op.timeoutTask && op.timeoutTask.isWaiting())
			op.timeoutTask.cancel();

		assert(pendingOperations > 0);
		pendingOperations--;
		if (pendingOperations == 0)
			anchor.disarmPending();

		if (error)
			op.onError(error);
		else
			op.onSuccess(addresses);
	}

public:
	this()
	{
		initialize((string host, ushort port) {
			return getAddress(host, port);
		}, 30.seconds, 30.seconds);
	}

	debug(ae_unittest)
	this(
		LookupFn lookup,
		Duration operationTimeout = 30.seconds,
		Duration idleTimeout = 30.seconds,
		void delegate(string host, ushort port) onWorkerDequeued = null,
	)
	{
		this.onWorkerDequeued = onWorkerDequeued;
		initialize(lookup, operationTimeout, idleTimeout);
	}

	void resolve(
		string host,
		ushort port,
		void delegate(Address[]) onSuccess,
		void delegate(string) onError,
	)
	{
		if (shutdownStarted)
		{
			onError(shutdownError);
			return;
		}

		joinAndRemoveExitedWorkers();

		auto op = new Operation();
		op.host = host;
		op.port = port;
		op.onSuccess = onSuccess;
		op.onError = onError;
		operations ~= op;

		if (pendingOperations == 0)
			anchor.armPending();
		pendingOperations++;

		op.timeoutTask = setTimeout({
			completeOperation(op, false, null, "Lookup error: DNS resolution timed out");
		}, operationTimeout);

		synchronized (mutex)
		{
			assert(!shuttingDown);
			jobs ~= op;

			auto requiredWorkers = busyWorkers + jobs.length;
			while (workers.length < requiredWorkers)
				spawnWorkerLocked();

			if (idleWorkers > 0)
				cond.notify();
		}
	}

	void shutdown(scope const(char)[] reason)
	{
		if (shutdownStarted)
			return;

		shutdownStarted = true;

		Operation[] operationsToCancel;
		synchronized (mutex)
		{
			shuttingDown = true;
			jobs = null;
			cond.notifyAll();
			operationsToCancel = operations.dup;
		}

		foreach (op; operationsToCancel)
			completeOperation(op, true, null, shutdownError);

		joinAndRemoveExitedWorkers();
		maybeCloseAnchor();
	}

	debug(ae_unittest) size_t debugWorkerCreationCount() const
	{
		return workerCreations;
	}

	debug(ae_unittest) size_t debugLiveWorkerCount()
	{
		synchronized (mutex)
			return workers.length;
	}

	debug(ae_unittest) size_t debugIdleWorkerCount()
	{
		synchronized (mutex)
			return idleWorkers;
	}

	debug(ae_unittest) size_t debugAnchorAllocationCount() const
	{
		return anchorAllocations;
	}

	debug(ae_unittest) bool debugAnchorClosed() const
	{
		return anchorClosed;
	}

	debug(ae_unittest) size_t debugOutstandingOperationCount() const
	{
		return operations.length;
	}

	debug(ae_unittest) size_t debugQueuedOperationCount()
	{
		synchronized (mutex)
			return jobs.length;
	}

	debug(ae_unittest) size_t debugWorkersInLookupCount()
	{
		size_t count;
		synchronized (mutex)
			foreach (worker; workers)
				if (worker.inLookup)
					count++;
		return count;
	}

	debug(ae_unittest) void debugSetPauseDequeues(bool pause)
	{
		synchronized (mutex)
		{
			pauseDequeues = pause;
			if (!pause)
				cond.notifyAll();
		}
	}

	debug(ae_unittest) void debugDispose()
	{
		shutdown("debug dispose");

		auto deadline = MonoTime.currTime + 5.seconds;
		while (debugLiveWorkerCount() > 0)
		{
			if (MonoTime.currTime >= deadline)
				break;

			joinAndRemoveExitedWorkers();
			Thread.sleep(10.msecs);
		}
		joinAndRemoveExitedWorkers();
		maybeCloseAnchor();
		assert(debugLiveWorkerCount() == 0);
		assert(anchorClosed);

		if (shutdownHandler !is null)
		{
			removeShutdownHandler(shutdownHandler);
			shutdownHandler = null;
		}
	}
}

private DnsResolver resolverForThread;

private DnsResolver resolverForThisThread()
{
	if (!resolverForThread)
	{
		debug(ae_unittest)
			resolverForThread = new DnsResolver((string host, ushort port) {
				return getAddress(host, port);
			}, 30.seconds, 100.msecs);
		else
			resolverForThread = new DnsResolver();
	}
	return resolverForThread;
}

debug(ae_unittest) private void resetResolverForThisThreadForTest()
{
	if (resolverForThread)
	{
		resolverForThread.debugDispose();
	}
	resolverForThread = null;
}

debug(ae_unittest) public size_t debugResolverWorkerCreationCount()
{
	return resolverForThread ? resolverForThread.debugWorkerCreationCount() : 0;
}

debug(ae_unittest) public size_t debugResolverLiveWorkerCount()
{
	return resolverForThread ? resolverForThread.debugLiveWorkerCount() : 0;
}

debug(ae_unittest) public size_t debugResolverIdleWorkerCount()
{
	return resolverForThread ? resolverForThread.debugIdleWorkerCount() : 0;
}

/// Perform DNS resolution in a worker thread, delivering the result back
/// to the event loop thread via a `ThreadAnchor`.
void resolveHost(string host, ushort port,
	void delegate(Address[]) onSuccess, void delegate(string) onError)
{
	debug (ASOCKETS) stderr.writefln("resolveHost: starting for %s:%d", host, port);
	resolverForThisThread().resolve(host, port, onSuccess, onError);
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import ae.sys.timing : TimerTask, setTimeout;
	import core.time : seconds;

	resetResolverForThisThreadForTest();

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	TimerTask timeoutTask;
	size_t completed;

	void runNext()
	{
		if (completed == 256)
		{
			timeoutTask.cancel();
			server.close();
			return;
		}

			resolveHost("127.0.0.1", 80, (Address[] addresses) {
				assert(addresses.length > 0);
				completed++;
				setTimeout({
					runNext();
				}, 1.msecs);
			}, (string error) {
				assert(false, error);
			});
		}

	timeoutTask = setTimeout({
		assert(false, "Timed out waiting for DNS resolution after " ~ completed.to!string ~ " sequential resolutions");
	}, 10.seconds);

	runNext();
	socketManager.loop();
	assert(completed == 256);
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;
	import core.thread : Thread;

	auto resolver = new DnsResolver((string host, ushort port) {
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 100.msecs);

	size_t remaining = 8;
	size_t successes;
	bool sequenceDone;
	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};
	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for worker reuse test");
	}, 10.seconds);

	void runNext()
	{
		if (remaining == 0)
		{
			sequenceDone = true;
			setTimeout({
				assert(resolver.debugLiveWorkerCount() == 0);
				timeoutTask.cancel();
				resolver.debugDispose();
				server.close();
			}, 300.msecs);
			return;
		}

		resolver.resolve("reuse.local", 80, (Address[] addresses) {
			assert(addresses.length == 1);
			successes++;
			remaining--;
			setTimeout({
				runNext();
			}, 1.msecs);
		}, (string error) {
			assert(false, error);
		});
	}

	runNext();
	socketManager.loop();

	assert(sequenceDone);
	assert(successes == 8);
	assert(resolver.debugWorkerCreationCount() == 1);
	assert(resolver.debugAnchorAllocationCount() == 1);
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;

	auto gateMutex = new Mutex();
	auto gateCond = new Condition(gateMutex);
	bool blockedStarted;
	bool releaseBlocked;
	bool blockedCompleted;
	bool fastCompleted;

	auto resolver = new DnsResolver((string host, ushort port) {
		if (host == "blocked.local")
		{
			synchronized (gateMutex)
			{
				blockedStarted = true;
				gateCond.notify();
				while (!releaseBlocked)
					gateCond.wait();
			}
		}
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 100.msecs);

	resolver.resolve("blocked.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		blockedCompleted = true;
	}, (string error) {
		assert(false, error);
	});

	auto blockedStartDeadline = MonoTime.currTime + 10.seconds;
	synchronized (gateMutex)
		while (!blockedStarted)
		{
			auto remaining = blockedStartDeadline - MonoTime.currTime;
			assert(remaining > Duration.zero, "Timed out waiting for blocked lookup to start");
			gateCond.wait(remaining);
		}

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	resolver.resolve("fast.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		assert(!blockedCompleted);
		fastCompleted = true;
		synchronized (gateMutex)
		{
			releaseBlocked = true;
			gateCond.notify();
		}
	}, (string error) {
		assert(false, error);
	});

	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for elastic resolver test");
	}, 10.seconds);

	auto completionTask = setTimeout({
		timeoutTask.cancel();
		assert(resolver.debugLiveWorkerCount() == 0);
		resolver.debugDispose();
		server.close();
	}, 500.msecs);

	socketManager.loop();

	assert(fastCompleted);
	assert(blockedCompleted);
	assert(resolver.debugWorkerCreationCount() >= 2);
	if (completionTask.isWaiting())
		completionTask.cancel();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;

	auto gateMutex = new Mutex();
	auto gateCond = new Condition(gateMutex);
	bool blockedStarted;
	bool releaseBlocked;
	bool fastCompleted;
	bool blockedCompleted;

	auto resolver = new DnsResolver((string host, ushort port) {
		if (host == "blocked.local")
		{
			synchronized (gateMutex)
			{
				blockedStarted = true;
				gateCond.notifyAll();
				while (!releaseBlocked)
					gateCond.wait();
			}
		}
		else if (host == "fast.local")
		{
			synchronized (gateMutex)
				while (!blockedStarted)
					gateCond.wait();
		}

		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 100.msecs);

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	resolver.resolve("blocked.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		blockedCompleted = true;
	}, (string error) {
		assert(false, error);
	});

	resolver.resolve("fast.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		assert(!blockedCompleted);
		fastCompleted = true;
		synchronized (gateMutex)
		{
			releaseBlocked = true;
			gateCond.notifyAll();
		}
	}, (string error) {
		assert(false, error);
	});

	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for back-to-back elastic resolver test");
	}, 10.seconds);

	auto completionTask = setTimeout({
		timeoutTask.cancel();
		assert(resolver.debugLiveWorkerCount() == 0);
		resolver.debugDispose();
		server.close();
	}, 500.msecs);

	socketManager.loop();

	assert(fastCompleted);
	assert(blockedCompleted);
	assert(resolver.debugWorkerCreationCount() >= 2);
	if (completionTask.isWaiting())
		completionTask.cancel();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	auto resolver = new DnsResolver((string host, ushort port) {
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 100.msecs);

	bool resolved;
	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	resolver.resolve("retire.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		resolved = true;
	}, (string error) {
		assert(false, error);
	});

	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for worker retirement");
	}, 10.seconds);

	setTimeout({
		assert(resolved);
		assert(resolver.debugLiveWorkerCount() == 0);
		timeoutTask.cancel();
		resolver.debugDispose();
		server.close();
	}, 400.msecs);

	socketManager.loop();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;

	auto gateMutex = new Mutex();
	auto gateCond = new Condition(gateMutex);
	bool releaseLookup;
	size_t successCount;
	size_t errorCount;
	string timeoutError;

	auto resolver = new DnsResolver((string host, ushort port) {
		synchronized (gateMutex)
			while (!releaseLookup)
				gateCond.wait();
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 80.msecs, 100.msecs);

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	resolver.resolve("timeout.local", 80, (Address[] addresses) {
		successCount++;
	}, (string error) {
		errorCount++;
		timeoutError = error;
	});

	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for timeout behavior test");
	}, 10.seconds);

	setTimeout({
		synchronized (gateMutex)
		{
			releaseLookup = true;
			gateCond.notify();
		}
	}, 200.msecs);

	setTimeout({
		timeoutTask.cancel();
		assert(resolver.debugLiveWorkerCount() == 0);
		resolver.debugDispose();
		server.close();
	}, 500.msecs);

	socketManager.loop();

	assert(successCount == 0);
	assert(errorCount == 1);
	assert(timeoutError == "Lookup error: DNS resolution timed out");
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	auto resolver = new DnsResolver((string host, ushort port) {
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 250.msecs, 100.msecs);

	bool succeeded;
	bool errored;
	TimerTask timeoutTask;
	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	resolver.resolve("success.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		succeeded = true;
	}, (string error) {
		errored = true;
		assert(false, error);
	});

	timeoutTask = setTimeout({
		assert(false, "Timed out waiting for success timeout-cancel test");
	}, 10.seconds);

	setTimeout({
		assert(succeeded);
		assert(resolver.debugLiveWorkerCount() == 0);
		timeoutTask.cancel();
		resolver.debugDispose();
		server.close();
	}, 500.msecs);

	socketManager.loop();
	if (timeoutTask.isWaiting())
		timeoutTask.cancel();

	assert(succeeded);
	assert(!errored);
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	auto resolver = new DnsResolver((string host, ushort port) {
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 10.seconds);

	bool resolved;
	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};
	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for idle resolver shutdown");
	}, 10.seconds);

	resolver.resolve("idle-shutdown.local", 80, (Address[] addresses) {
		assert(addresses.length == 1);
		resolved = true;
	}, (string error) {
		assert(false, error);
	});

	setTimeout({
		assert(resolved);
		assert(resolver.debugIdleWorkerCount() == 1);
		resolver.shutdown("unit test idle shutdown");
	}, 80.msecs);

	setTimeout({
		assert(resolver.debugLiveWorkerCount() == 0);
		assert(resolver.debugOutstandingOperationCount() == 0);
		assert(resolver.debugAnchorClosed());
		timeoutTask.cancel();
		resolver.debugDispose();
		server.close();
	}, 300.msecs);

	socketManager.loop();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	size_t successCount;
	size_t errorCount;
	string errorMessage;
	size_t lookupCalls;

	auto resolver = new DnsResolver((string host, ushort port) {
		lookupCalls++;
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 10.seconds);

	resolver.debugSetPauseDequeues(true);

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};
	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for queued shutdown behavior");
	}, 10.seconds);

	resolver.resolve("queued-shutdown.local", 80, (Address[] addresses) {
		successCount++;
	}, (string error) {
		errorCount++;
		errorMessage = error;
	});

	assert(resolver.debugQueuedOperationCount() == 1);
	resolver.shutdown("unit test queued shutdown");
	assert(successCount == 0);
	assert(errorCount == 1);
	assert(errorMessage == "Lookup error: DNS resolver shut down");
	assert(lookupCalls == 0);
	assert(resolver.debugOutstandingOperationCount() == 0);
	resolver.debugSetPauseDequeues(false);

	setTimeout({
		assert(resolver.debugLiveWorkerCount() == 0);
		assert(resolver.debugAnchorClosed());
		timeoutTask.cancel();
		resolver.debugDispose();
		server.close();
	}, 300.msecs);

	socketManager.loop();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;

	auto gateMutex = new Mutex();
	auto gateCond = new Condition(gateMutex);
	bool lookupStarted;
	bool releaseLookup;
	size_t successCount;
	size_t errorCount;
	string errorMessage;

	auto resolver = new DnsResolver((string host, ushort port) {
		synchronized (gateMutex)
		{
			lookupStarted = true;
			gateCond.notifyAll();
			while (!releaseLookup)
				gateCond.wait();
		}
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 10.seconds);

	resolver.resolve("in-flight-shutdown.local", 80, (Address[] addresses) {
		successCount++;
	}, (string error) {
		errorCount++;
		errorMessage = error;
	});

	auto lookupStartDeadline = MonoTime.currTime + 10.seconds;
	synchronized (gateMutex)
		while (!lookupStarted)
		{
			auto remaining = lookupStartDeadline - MonoTime.currTime;
			assert(remaining > Duration.zero, "Timed out waiting for in-flight lookup to start");
			gateCond.wait(remaining);
		}

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};
	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for in-flight shutdown behavior");
	}, 10.seconds);

	resolver.shutdown("unit test in-flight shutdown");
	assert(successCount == 0);
	assert(errorCount == 1);
	assert(errorMessage == "Lookup error: DNS resolver shut down");

	synchronized (gateMutex)
	{
		releaseLookup = true;
		gateCond.notifyAll();
	}

	setTimeout({
		assert(successCount == 0);
		assert(errorCount == 1);
		assert(resolver.debugLiveWorkerCount() == 0);
		assert(resolver.debugAnchorClosed());
		timeoutTask.cancel();
		resolver.debugDispose();
		server.close();
	}, 400.msecs);

	socketManager.loop();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import core.sync.condition : Condition;
	import core.sync.mutex : Mutex;

	auto gateMutex = new Mutex();
	auto gateCond = new Condition(gateMutex);
	bool lookupStarted;
	bool releaseLookup;
	size_t successCount;
	size_t errorCount;
	string errorMessage;

	auto resolver = new DnsResolver((string host, ushort port) {
		synchronized (gateMutex)
		{
			lookupStarted = true;
			gateCond.notifyAll();
			while (!releaseLookup)
				gateCond.wait();
		}
		Address[] result;
		result ~= new InternetAddress("127.0.0.1", port);
		return result;
	}, 2.seconds, 10.seconds);

	resolver.resolve("stuck-shutdown.local", 80, (Address[] addresses) {
		successCount++;
	}, (string error) {
		errorCount++;
		errorMessage = error;
	});

	auto lookupStartDeadline = MonoTime.currTime + 10.seconds;
	synchronized (gateMutex)
		while (!lookupStarted)
		{
			auto remaining = lookupStartDeadline - MonoTime.currTime;
			assert(remaining > Duration.zero, "Timed out waiting for stuck lookup to start");
			gateCond.wait(remaining);
		}

	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};
	auto timeoutTask = setTimeout({
		assert(false, "Timed out waiting for stuck shutdown behavior");
	}, 10.seconds);

	resolver.shutdown("unit test stuck shutdown");
	assert(successCount == 0);
	assert(errorCount == 1);
	assert(errorMessage == "Lookup error: DNS resolver shut down");
	assert(!resolver.debugAnchorClosed());
	assert(resolver.debugWorkersInLookupCount() == 1);

	setTimeout({
		assert(!resolver.debugAnchorClosed());
		assert(resolver.debugLiveWorkerCount() == 1);
		assert(resolver.debugWorkersInLookupCount() == 1);
	}, 150.msecs);

	setTimeout({
		synchronized (gateMutex)
		{
			releaseLookup = true;
			gateCond.notifyAll();
		}
	}, 250.msecs);

	setTimeout({
		assert(successCount == 0);
		assert(errorCount == 1);
		assert(resolver.debugLiveWorkerCount() == 0);
		assert(resolver.debugAnchorClosed());
		timeoutTask.cancel();
		resolver.debugDispose();
		server.close();
	}, 500.msecs);

	socketManager.loop();
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	resetResolverForThisThreadForTest();

	auto resolver = resolverForThisThread();
	resolver.shutdown("unit test post-shutdown resolve");

	bool successCalled;
	string errorMessage;
	resolveHost("127.0.0.1", 80, (Address[] addresses) {
		successCalled = true;
	}, (string error) {
		errorMessage = error;
	});

	assert(!successCalled);
	assert(errorMessage == "Lookup error: DNS resolver shut down");
	assert(resolverForThisThread() is resolver);
	assert(debugResolverWorkerCreationCount() == 0);

	resetResolverForThisThreadForTest();
}

// ***************************************************************************
