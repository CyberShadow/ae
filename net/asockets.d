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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.asockets;

import ae.sys.timing;
import ae.utils.math;
public import ae.sys.data;

import std.socket;
public import std.socket : Address, Socket;

debug(ASOCKETS) import std.stdio;
debug(PRINTDATA) import ae.utils.text : hexDump;
private import std.conv : to;

import std.random : randomShuffle;

version(LIBEV)
{
	import deimos.ev;
	pragma(lib, "ev");
}

version(Windows)
{
	import std.c.windows.windows : Sleep;
	enum USE_SLEEP = true; // avoid convoluted mix of static and runtime conditions
}
else
	enum USE_SLEEP = false;

/// Flags that determine socket wake-up events.
int eventCounter;

version(LIBEV)
{
	// Watchers are a GenericSocket field (as declared in SocketMixin).
	// Use one watcher per read and write event.
	// Start/stop those as higher-level code declares interest in those events.
	// Use the "data" ev_io field to store the parent GenericSocket address.
	// Also use the "data" field as a flag to indicate whether the watcher is active
	// (data is null when the watcher is stopped).

	struct SocketManager
	{
	private:
		size_t count;

		extern(C)
		static void ioCallback(ev_loop_t* l, ev_io* w, int revents)
		{
			eventCounter++;
			auto socket = cast(GenericSocket)w.data;
			assert(socket, "libev event fired on stopped watcher");
			debug (ASOCKETS) writefln("ioCallback(%s, 0x%X)", cast(void*)socket, revents);

			if (revents & EV_READ)
				socket.onReadable();
			else
			if (revents & EV_WRITE)
				socket.onWritable();
			else
				assert(false, "Unknown event fired from libev");

			// TODO? Need to get proper SocketManager instance to call updateTimer on
			socketManager.updateTimer(false);
		}

		ev_timer evTimer;
		MonoTime lastNextEvent = MonoTime.max;

		extern(C)
		static void timerCallback(ev_loop_t* l, ev_timer* w, int revents)
		{
			eventCounter++;
			debug (ASOCKETS) writefln("Timer callback called.");
			mainTimer.prod();

			socketManager.updateTimer(true);
			debug (ASOCKETS) writefln("Timer callback exiting.");
		}

		void updateTimer(bool force)
		{
			auto nextEvent = mainTimer.getNextEvent();
			if (force || lastNextEvent != nextEvent)
			{
				debug (ASOCKETS) writefln("Rescheduling timer. Was at %s, now at %s", lastNextEvent, nextEvent);
				if (nextEvent == MonoTime.max) // Stopping
				{
					if (lastNextEvent != MonoTime.max)
						ev_timer_stop(ev_default_loop(0), &evTimer);
				}
				else
				{
					auto remaining = mainTimer.getRemainingTime();
					while (remaining.length <= 0)
					{
						debug (ASOCKETS) writefln("remaining=%s, prodding timer.", remaining);
						mainTimer.prod();
						remaining = mainTimer.getRemainingTime();
					}
					ev_tstamp tstamp = remaining.to!("seconds", ev_tstamp)();
					debug (ASOCKETS) writefln("remaining=%s, ev_tstamp=%s", remaining, tstamp);
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

		/// Register a socket with the manager.
		void register(GenericSocket socket)
		{
			debug (ASOCKETS) writefln("Registering %s", cast(void*)socket);
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
			debug (ASOCKETS) writefln("Unregistering %s", cast(void*)socket);
			socket.notifyRead  = false;
			socket.notifyWrite = false;
			count--;
		}

	public:
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
			debug (ASOCKETS) writeln("ev_run");
			ev_run(ev_default_loop(0), 0);
		}
	}

	private mixin template SocketMixin()
	{
		private ev_io evRead, evWrite;

		private void setWatcherState(ref ev_io ev, bool newValue, int event)
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

		/// Interested in read notifications (onReadable)?
		@property final void notifyRead (bool value) { setWatcherState(evRead , value, EV_READ ); }
		/// Interested in write notifications (onWritable)?
		@property final void notifyWrite(bool value) { setWatcherState(evWrite, value, EV_WRITE); }

		debug ~this()
		{
			// The LIBEV SocketManager holds no references to registered sockets.
			// TODO: Add a doubly-linked list?
			assert(evRead.data is null && evWrite.data is null, "Destroying a registered socket");
		}
	}
}
else // Use select
{
	struct SocketManager
	{
	private:
		enum FD_SETSIZE = 1024;

		/// List of all sockets to poll.
		GenericSocket[] sockets;

		/// Register a socket with the manager.
		void register(GenericSocket conn)
		{
			sockets ~= conn;
		}

		/// Unregister a socket with the manager.
		void unregister(GenericSocket conn)
		{
			foreach (size_t i, GenericSocket j; sockets)
				if (j is conn)
				{
					sockets = sockets[0 .. i] ~ sockets[i + 1 .. sockets.length];
					return;
				}
			assert(false, "Socket not registered");
		}

	public:
		size_t size()
		{
			return sockets.length;
		}

		/// Loop continuously until no sockets are left.
		void loop()
		{
			debug (ASOCKETS) writeln("Starting event loop.");

			SocketSet readset, writeset, errorset;
			size_t sockcount;
			readset  = new SocketSet(FD_SETSIZE);
			writeset = new SocketSet(FD_SETSIZE);
			errorset = new SocketSet(FD_SETSIZE);
			while (true)
			{
				// SocketSet.add() doesn't have an overflow check, so we need to do it manually
				// this is just a debug check, the actual check is done when registering sockets
				// TODO: this is inaccurate on POSIX, "max" means maximum fd value
				if (sockets.length > readset.max || sockets.length > writeset.max || sockets.length > errorset.max)
				{
					readset  = new SocketSet(to!uint(sockets.length*2));
					writeset = new SocketSet(to!uint(sockets.length*2));
					errorset = new SocketSet(to!uint(sockets.length*2));
				}
				else
				{
					readset.reset();
					writeset.reset();
					errorset.reset();
				}

				sockcount = 0;
				bool haveActive;
				debug (ASOCKETS) writeln("Populating sets");
				foreach (GenericSocket conn; sockets)
				{
					if (!conn.socket)
						continue;
					sockcount++;
					if (!conn.daemon)
						haveActive = true;

					debug (ASOCKETS) writef("\t%s:", cast(void*)conn);
					if (conn.notifyRead)
					{
						readset.add(conn.socket);
						debug (ASOCKETS) write(" READ");
					}
					if (conn.notifyWrite)
					{
						writeset.add(conn.socket);
						debug (ASOCKETS) write(" WRITE");
					}
					errorset.add(conn.socket);
					debug (ASOCKETS) writeln();
				}
				debug (ASOCKETS) writefln("Waiting (%d sockets, %s timer events)...", sockcount, mainTimer.isWaiting() ? "with" : "no");
				if (!haveActive && !mainTimer.isWaiting())
				{
					debug (ASOCKETS) writeln("No more sockets or timer events, exiting loop.");
					break;
				}

				int events;
				if (USE_SLEEP && sockcount==0)
				{
					version(Windows)
					{
						auto duration = mainTimer.getRemainingTime().total!"msecs"();
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
					events = Socket.select(readset, writeset, errorset, mainTimer.getRemainingTime());
				else
					events = Socket.select(readset, writeset, errorset);

				debug (ASOCKETS) writefln("%d events fired.", events);

				if (events > 0)
				{
					foreach (GenericSocket conn; sockets)
					{
						if (!conn.socket)
						{
							debug (ASOCKETS) writefln("\t%s is unset", cast(void*)conn);
							continue;
						}
						if (readset.isSet(conn.socket))
						{
							debug (ASOCKETS) writefln("\t%s is readable", cast(void*)conn);
							conn.onReadable();
						}

						if (!conn.socket)
						{
							debug (ASOCKETS) writefln("\t%s is unset", cast(void*)conn);
							continue;
						}
						if (writeset.isSet(conn.socket))
						{
							debug (ASOCKETS) writefln("\t%s is writable", cast(void*)conn);
							conn.onWritable();
						}

						if (!conn.socket)
						{
							debug (ASOCKETS) writefln("\t%s is unset", cast(void*)conn);
							continue;
						}
						if (errorset.isSet(conn.socket))
						{
							debug (ASOCKETS) writefln("\t%s is errored", cast(void*)conn);
							conn.onError("select() error: " ~ conn.socket.getErrorText());
						}
					}
				}

				// Timers may invalidate our select results, so fire them after processing the latter
				mainTimer.prod();

				eventCounter++;
			}
		}
	}

	private mixin template SocketMixin()
	{
		/// Interested in read notifications (onReadable)?
		bool notifyRead;
		/// Interested in write notifications (onWritable)?
		bool notifyWrite;
	}
}

enum DisconnectType
{
	Requested, // initiated by the application
	Graceful,  // peer gracefully closed the connection
	Error      // abnormal network condition
}

/// General methods for an asynchronous socket
private abstract class GenericSocket
{
	/// Declares notifyRead and notifyWrite.
	mixin SocketMixin;

protected:
	/// The socket this class wraps.
	Socket conn;

protected:
	/// Retrieve the socket class this class wraps.
	@property final Socket socket()
	{
		return conn;
	}

	void onReadable()
	{
	}

	void onWritable()
	{
	}

	void onError(string reason)
	{
	}

public:
	/// allow getting the address of connections that are already disconnected
	private Address cachedLocalAddress, cachedRemoteAddress;

	/// Don't block the process from exiting.
	/// TODO: Not implemented with libev
	bool daemon;

	final @property Address localAddress()
	{
		if (cachedLocalAddress !is null)
			return cachedLocalAddress;
		else
		if (conn is null)
			return null;
		else
			return cachedLocalAddress = conn.localAddress();
	}

	final @property Address remoteAddress()
	{
		if (cachedRemoteAddress !is null)
			return cachedRemoteAddress;
		else
		if (conn is null)
			return null;
		else
			return cachedRemoteAddress = conn.remoteAddress();
	}

	final void setKeepAlive(bool enabled=true, int time=10, int interval=5)
	{
		assert(conn, "Attempting to set keep-alive on an uninitialized socket");
		if (enabled)
			conn.setKeepAlive(time, interval);
		else
			conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, false);
	}
}


/// An asynchronous client socket.
class ClientSocket : GenericSocket
{
private:
	TimerTask idleTask;

	/// Blocks of data larger than this value are passed as unmanaged memory
	/// (in Data objects). Blocks smaller than this value will be reallocated
	/// on the managed heap. The disadvantage of placing large objects on the
	/// managed heap is false pointers; the disadvantage of using Data for
	/// small objects is wasted slack space due to the page size alignment
	/// requirement.
	enum UNMANAGED_THRESHOLD = 256;

	/// Queue of addresses to try connecting to.
	Address[] addressQueue;

public:
	/// Whether the socket is connected.
	bool connected;

	enum MAX_PRIORITY = 4;
	enum DEFAULT_PRIORITY = 2;

protected:
	/// The send buffers.
	Data[][MAX_PRIORITY+1] outQueue;
	/// Whether the first item from each queue has been partially sent (and thus can't be cancelled).
	bool[MAX_PRIORITY+1] partiallySent;
	/// Whether a disconnect is pending after all data is sent
	bool disconnecting;

	/// Constructor used by a ServerSocket for new connections
	this(Socket conn)
	{
		this();
		this.conn = conn;
		connected = !(conn is null);
		if (connected)
			socketManager.register(this);
		updateFlags();
	}

	final void updateFlags()
	{
		if (!connected)
			notifyWrite = true;
		else
			notifyWrite = writePending;

		notifyRead = connected && handleReadData;
	}

	/// Called when a socket is readable.
	override void onReadable()
	{
		// TODO: use FIONREAD when Phobos gets ioctl support (issue 6649)
		static ubyte[0x10000] inBuffer;
		auto received = conn.receive(inBuffer);

		if (received == 0)
			return disconnect("Connection closed", DisconnectType.Graceful);

		if (received == Socket.ERROR)
			onError("recv() error: " ~ lastSocketError);
		else
		{
			debug (PRINTDATA)
			{
				std.stdio.writefln("== %s <- %s ==", localAddress, remoteAddress);
				std.stdio.write(hexDump(inBuffer[0 .. received]));
				std.stdio.stdout.flush();
			}

			if (!disconnecting && handleReadData)
			{
				// Currently, unlike the D1 version of this module,
				// we will always reallocate read network data.
				// This disfavours code which doesn't need to store
				// read data after processing it, but otherwise
				// makes things simpler and safer all around.

				if (received < UNMANAGED_THRESHOLD)
				{
					// Copy to the managed heap
					_handleReadData(this, Data(inBuffer[0 .. received].dup));
				}
				else
				{
					// Copy to unmanaged memory
					_handleReadData(this, Data(inBuffer[0 .. received], true));
				}
			}
		}
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		scope(success) updateFlags();

		if (!connected)
		{
			connected = true;
			//debug writefln("[%s] Connected", remoteAddress);
			try
				setKeepAlive();
			catch (Exception e)
				return disconnect(e.msg, DisconnectType.Error);
			if (idleTask !is null)
				mainTimer.add(idleTask);
			if (handleConnect)
				handleConnect(this);
			return;
		}
		//debug writefln(remoteAddress(), ": Writable - handler ", handleBufferFlushed?"OK":"not set", ", outBuffer.length=", outBuffer.length);

		foreach (priority, ref queue; outQueue)
			while (queue.length)
			{
				auto data = queue.ptr; // pointer to first data
				auto sent = conn.send(data.contents);
				debug (ASOCKETS) writefln("\t\t%s: sent %d/%d bytes", cast(void*)this, sent, data.length);

				if (sent == Socket.ERROR)
				{
					if (wouldHaveBlocked())
						return;
					else
						return onError("send() error: " ~ lastSocketError);
				}
				else
				if (sent == 0)
					return;
				else
				if (sent < data.length)
				{
					*data = (*data)[sent..data.length];
					partiallySent[priority] = true;
					return;
				}
				else
				{
					assert(sent == data.length);
					//debug writefln("[%s] Sent data:", remoteAddress);
					//debug writefln("%s", hexDump(data.contents[0..sent]));
					queue = queue[1..$];
					partiallySent[priority] = false;
					if (queue.length == 0)
						queue = null;
				}
			}

		// outQueue is now empty
		if (handleBufferFlushed)
			handleBufferFlushed(this);
		if (disconnecting)
			disconnect("Delayed disconnect - buffer flushed", DisconnectType.Requested);
	}

	/// Called when an error occurs on the socket.
	override void onError(string reason)
	{
		if (!connected && addressQueue.length)
			return tryNextAddress();
		disconnect("Socket error: " ~ reason, DisconnectType.Error);
	}

	final void onTask_Idle(Timer timer, TimerTask task)
	{
		if (!connected)
			return;

		if (disconnecting)
			return disconnect("Delayed disconnect - time-out", DisconnectType.Error);

		if (handleIdleTimeout)
		{
			handleIdleTimeout(this);
			if (connected && !disconnecting)
			{
				assert(!idleTask.isWaiting());
				mainTimer.add(idleTask);
			}
		}
		else
			disconnect("Time-out", DisconnectType.Error);
	}

	final void tryNextAddress()
	{
		auto address = addressQueue[0];
		addressQueue = addressQueue[1..$];

		try
		{
			conn = new Socket(address.addressFamily(), SocketType.STREAM, ProtocolType.TCP);
			conn.blocking = false;

			socketManager.register(this);
			updateFlags();
			conn.connect(address);
		}
		catch (SocketException e)
			return onError("Connect error: " ~ e.msg);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) writefln("New ClientSocket @ %s", cast(void*)this);
	}

	/// Start establishing a connection.
	final void connect(string host, ushort port)
	{
		if (conn || connected)
			throw new Exception("Socket object is already connected");

		try
		{
			addressQueue = getAddress(host, port);
			enforce(addressQueue.length, "No addresses found");
			if (addressQueue.length > 1)
				randomShuffle(addressQueue);
		}
		catch (SocketException e)
			return onError("Lookup error: " ~ e.msg);

		tryNextAddress();
	}

	static const DefaultDisconnectReason = "Software closed the connection";

	/// Close a connection. If there is queued data waiting to be sent, wait until it is sent before disconnecting.
	void disconnect(string reason = DefaultDisconnectReason, DisconnectType type = DisconnectType.Requested)
	{
		scope(success) updateFlags();

		if (writePending)
		{
			if (type==DisconnectType.Requested)
			{
				assert(conn, "Attempting to disconnect on an uninitialized socket");
				// queue disconnect after all data is sent
				//debug writefln("[%s] Queueing disconnect: ", remoteAddress, reason);
				assert(!disconnecting, "Attempting to disconnect on a disconnecting socket");
				disconnecting = true;
				setIdleTimeout(30.seconds);
				return;
			}
			else
				discardQueues();
		}

		//debug writefln("[%s] Disconnecting: %s", remoteAddress, reason);
		if (conn)
		{
			socketManager.unregister(this);
			conn.close();
			conn = null;
			outQueue[] = null;
			connected = disconnecting = false;
		}
		else
		{
			assert(!connected);
		}
		if (idleTask && idleTask.isWaiting())
			idleTask.cancel();
		if (handleDisconnect)
			handleDisconnect(this, reason, type);
	}

	/// Append data to the send buffer.
	final void send(Data data, int priority = DEFAULT_PRIORITY)
	{
		assert(connected, "Attempting to send on a disconnected socket");
		assert(!disconnecting, "Attempting to send on a disconnecting socket");
		outQueue[priority] ~= data;
		notifyWrite = true; // Fast updateFlags()

		debug (PRINTDATA)
		{
			std.stdio.writefln("== %s -> %s ==", localAddress, remoteAddress);
			std.stdio.write(hexDump(data.contents));
			std.stdio.stdout.flush();
		}
	}

	/// ditto
	final void send(Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(connected, "Attempting to send on a disconnected socket");
		assert(!disconnecting, "Attempting to send on a disconnecting socket");
		outQueue[priority] ~= data;
		notifyWrite = true; // Fast updateFlags()

		debug (PRINTDATA)
		{
			std.stdio.writefln("== %s -> %s ==", localAddress, remoteAddress);
			foreach (datum; data)
				std.stdio.write(hexDump(datum.contents));
			std.stdio.stdout.flush();
		}
	}

	final void clearQueue(int priority)
	{
		if (partiallySent[priority])
		{
			assert(outQueue[priority].length > 0);
			outQueue[priority] = outQueue[priority][0..1];
		}
		else
			outQueue[priority] = null;
		updateFlags();
	}

	/// Clears all queues, even partially sent content.
	private final void discardQueues()
	{
		foreach (priority; 0..MAX_PRIORITY+1)
		{
			outQueue[priority] = null;
			partiallySent[priority] = false;
		}
		updateFlags();
	}

	@property
	final bool writePending()
	{
		foreach (queue; outQueue)
			if (queue.length)
				return true;
		return false;
	}

	final bool queuePresent(int priority)
	{
		if (partiallySent[priority])
		{
			assert(outQueue[priority].length > 0);
			return outQueue[priority].length > 1;
		}
		else
			return outQueue[priority].length > 0;
	}

	void cancelIdleTimeout()
	{
		assert(idleTask !is null);
		assert(idleTask.isWaiting());
		idleTask.cancel();
	}

	void resumeIdleTimeout()
	{
		assert(connected);
		assert(idleTask !is null);
		assert(!idleTask.isWaiting());
		mainTimer.add(idleTask);
	}

	final void setIdleTimeout(Duration duration)
	{
		assert(duration > Duration.zero);
		if (idleTask is null)
		{
			idleTask = new TimerTask(duration);
			idleTask.handleTask = &onTask_Idle;
		}
		else
		{
			if (idleTask.isWaiting())
				idleTask.cancel();
			idleTask.delay = duration;
		}
		if (connected)
			mainTimer.add(idleTask);
	}

	void markNonIdle()
	{
		assert(idleTask !is null);
		if (idleTask.isWaiting())
			idleTask.restart();
	}

	final bool isConnected()
	{
		return connected;
	}

public:
	/// Callback for when a connection has been established.
	void delegate(ClientSocket sender) handleConnect;
	/// Callback for when a connection was closed.
	void delegate(ClientSocket sender, string reason, DisconnectType type) handleDisconnect;
	/// Callback for when a connection has stopped responding.
	void delegate(ClientSocket sender) handleIdleTimeout;
	/// Callback for when the send buffer has been flushed.
	void delegate(ClientSocket sender) handleBufferFlushed;

	private void delegate(ClientSocket sender, Data data) _handleReadData;
	/// Callback for incoming data.
	/// Data will not be received unless this handler is set.
	@property final void delegate(ClientSocket sender, Data data) handleReadData() { return _handleReadData; }
	/// ditto
	@property final void handleReadData(void delegate(ClientSocket sender, Data data) value) { _handleReadData = value; updateFlags(); }
}

/// An asynchronous server socket.
final class GenericServerSocket(T : ClientSocket)
{
private:
	/// Class that actually performs listening on a certain address family
	final class Listener : GenericSocket
	{
		this(Socket conn)
		{
			debug (ASOCKETS) writefln("New Listener @ %s", cast(void*)this);
			this.conn = conn;
			socketManager.register(this);
		}

		/// Called when a socket is readable.
		override void onReadable()
		{
			Socket acceptSocket = conn.accept();
			acceptSocket.blocking = false;
			if (handleAccept)
			{
				T connection = new T(acceptSocket);
				connection.setKeepAlive();
				//assert(connection.connected);
				//connection.connected = true;
				_handleAccept(connection);
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

	/// Whether the socket is listening.
	bool listening;
	/// Listener instances
	Listener[] listeners;

	final void updateFlags()
	{
		foreach (listener; listeners)
			listener.notifyRead = handleAccept !is null;
	}

public:
	/// Debugging aids
	ushort port;
	string addr;

	/// Start listening on this socket.
	ushort listen(ushort port, string addr = null)
	{
		//debug writefln("Listening on %s:%d", addr, port);
		assert(!listening, "Attempting to listen on a listening socket");

		auto addressInfos = getAddressInfo(addr, to!string(port), AddressInfoFlags.PASSIVE, SocketType.STREAM, ProtocolType.TCP);

		foreach (ref addressInfo; addressInfos)
		{
			if (addressInfo.family != AddressFamily.INET && port == 0)
				continue;  // listen on random ports only on IPv4 for now

			try
			{
				Socket conn = new Socket(addressInfo);
				conn.blocking = false;
				if (addressInfo.family == AddressFamily.INET6)
					conn.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

				conn.bind(addressInfo.address);
				conn.listen(8);

				if (addressInfo.family == AddressFamily.INET)
					port = to!ushort(conn.localAddress().toPortString());

				listeners ~= new Listener(conn);
			}
			catch (SocketException e)
			{
				debug(ASOCKETS) writefln("Unable to listen node \"%s\" service \"%s\"", addressInfo.address.toAddrString(), addressInfo.address.toPortString());
				debug(ASOCKETS) writeln(e.msg);
			}
		}

		if (listeners.length==0)
			throw new Exception("Unable to bind service");

		this.port = port;
		this.addr = addr;

		updateFlags();

		return port;
	}

	@property Address[] localAddresses()
	{
		Address[] result;
		foreach (listener; listeners)
			result ~= listener.localAddress;
		return result;
	}

	/// Stop listening on this socket.
	void close()
	{
		foreach (listener;listeners)
			listener.closeListener();
		listeners = null;
		listening = false;
		if (handleClose)
			handleClose();
	}

public:
	/// Callback for when the socket was closed.
	void delegate() handleClose;

	private void delegate(T incoming) _handleAccept;
	/// Callback for an incoming connection.
	/// Connections will not be accepted unless this handler is set.
	@property final void delegate(T incoming) handleAccept() { return _handleAccept; }
	/// ditto
	@property final void handleAccept(void delegate(T incoming) value) { _handleAccept = value; updateFlags(); }
}

/// Server socket type for ordinary sockets.
alias GenericServerSocket!(ClientSocket) ServerSocket;

/// Asynchronous class for client sockets with a line-based protocol.
class LineBufferedSocket : ClientSocket
{
private:
	/// The receive buffer.
	Data inBuffer;

public:
	/// The protocol's line delimiter.
	string delimiter = "\r\n";

private:
	/// Called when data has been received.
	final void onReadData(ClientSocket sender, Data data)
	{
		import std.string;
		auto oldBufferLength = inBuffer.length;
		if (oldBufferLength)
			inBuffer ~= data;
		else
			inBuffer = data;

		bool gotLines;

		if (delimiter.length == 1)
		{
			import std.c.string; // memchr

			char c = delimiter[0];
			auto p = memchr(inBuffer.ptr + oldBufferLength, c, data.length);
			while (p)
			{
				sizediff_t index = p - inBuffer.ptr;
				processLine(index);
				gotLines = true;

				p = memchr(inBuffer.ptr, c, inBuffer.length);
			}
		}
		else
		{
			sizediff_t index;
			// TODO: we can start the search at oldBufferLength-delimiter.length+1
			while ((index=indexOf(cast(string)inBuffer.contents, delimiter)) >= 0)
			{
				processLine(index);
				gotLines = true;
			}
		}

		if (gotLines)
			markNonIdle();
	}

	final void processLine(size_t index)
	{
		string line = cast(string)inBuffer.contents[0..index];
		inBuffer = inBuffer[index+delimiter.length..inBuffer.length];

		if (handleReadLine)
			handleReadLine(this, line.idup);
	}

public:
	override void cancelIdleTimeout() { assert(false); }
	override void resumeIdleTimeout() { assert(false); }
	//override void setIdleTimeout(d_time duration) { assert(false); }
	//override void markNonIdle() { assert(false); }

	this(Duration idleTimeout)
	{
		handleReadData = &onReadData;
		super.setIdleTimeout(idleTimeout);
	}

	this(Socket conn)
	{
		handleReadData = &onReadData;
		super.setIdleTimeout(60.seconds);
		super(conn);
	}

	/// Cancel a connection.
	override final void disconnect(string reason = DefaultDisconnectReason, DisconnectType type = DisconnectType.Requested)
	{
		super.disconnect(reason, type);
		inBuffer.clear();
	}

	/// Append a line to the send buffer.
	void send(string line)
	{
		super.send(Data(line ~ delimiter));
	}

public:
	/// Callback for an incoming line.
	void delegate(LineBufferedSocket sender, string line) handleReadLine;
}

/// The default socket manager.
// __gshared for ae.sys.shutdown
__gshared SocketManager socketManager;

// ***************************************************************************

unittest
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
