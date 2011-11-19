/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Stéphan Kochen <stephan@kochen.nl>
 * Portions created by the Initial Developer are Copyright (C) 2006
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Asynchronous socket abstraction.
module ae.net.asockets;

import ae.sys.timing;
public import ae.sys.data;

import std.socket;
public import std.socket : Address, Socket;

debug import std.stdio;
private import std.conv : to;

version(Windows)
{
	import std.c.windows.windows : Sleep;
	enum USE_SLEEP = true; // avoid convoluted mix of static and runtime conditions
}
else
	enum USE_SLEEP = false;

/// Flags that determine socket wake-up events.
private struct PollFlags
{
	/// Wake up when socket is readable.
	bool read;
	/// Wake up when socket is writable.
	bool write;
	/// Wake up when an error occurs on the socket.
	bool error;
}

int eventCounter;

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
				break;
			}
	}

public:
	size_t size()
	{
		return sockets.length;
	}

	/// Loop continuously until no sockets are left.
	void loop()
	{
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
			debug (ASOCKETS) writefln("Populating sets");
			foreach (GenericSocket conn; sockets)
			{
				if (!conn.socket)
					continue;
				sockcount++;

				debug (ASOCKETS) writef("\t%s:", cast(void*)conn);
				PollFlags flags = conn.pollFlags();
				if (flags.read)
				{
					readset.add(conn.socket);
					debug (ASOCKETS) writef(" READ");
				}
				if (flags.write)
				{
					writeset.add(conn.socket);
					debug (ASOCKETS) writef(" WRITE");
				}
				if (flags.error)
				{
					errorset.add(conn.socket);
					debug (ASOCKETS) writef(" ERROR");
				}
				debug (ASOCKETS) writefln();
			}
			debug (ASOCKETS) { writefln("Waiting..."); fflush(stdout); }
			if (sockcount == 0 && !mainTimer.isWaiting())
				break;

			int events;
			if (USE_SLEEP && sockcount==0)
			{
				version(Windows)
				{
					Sleep(mainTimer.getRemainingTime().to!("msecs", int)());
					events = 0;
				}
				else
					static assert(0);
			}
			else
			if (mainTimer.isWaiting())
				events = Socket.select(readset, writeset, errorset, mainTimer.getRemainingTime().to!("usecs", int)());
			else
				events = Socket.select(readset, writeset, errorset);

			mainTimer.prod();

			if (events > 0)
			{
				foreach (GenericSocket conn; sockets)
				{
					if (!conn.socket)
						continue;
					if (readset.isSet(conn.socket))
					{
						debug (ASOCKETS) writefln("\t%s is readable", cast(void*)conn);
						conn.onReadable();
					}

					if (!conn.socket)
						continue;
					if (writeset.isSet(conn.socket))
					{
						debug (ASOCKETS) writefln("\t%s is writable", cast(void*)conn);
						conn.onWritable();
					}

					if (!conn.socket)
						continue;
					if (errorset.isSet(conn.socket))
					{
						debug (ASOCKETS) writefln("\t%s is errored", cast(void*)conn);
						conn.onError("select() error: " ~ conn.socket.getErrorText());
					}
				}
			}

			eventCounter++;
		}
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
protected:
	/// The socket this class wraps.
	Socket conn;

protected:
	/// Retrieve the socket class this class wraps.
	final Socket socket()
	{
		return conn;
	}

	/// Retrieve the poll flags for this socket.
	PollFlags pollFlags()
	{
		PollFlags flags;
		flags.read = flags.write = flags.error = false;
		return flags;
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
	private string cachedRemoteAddress = null;

	final string remoteAddress()
	{
		if (cachedRemoteAddress !is null)
			return cachedRemoteAddress;
		else
		if (conn is null)
			return "(null)";
		else
		try
			return cachedRemoteAddress = conn.remoteAddress().toString();
		catch (Exception e)
			return e.msg;
	}

	final void setKeepAlive(bool enabled=true, int time=10, int interval=5)
	{
		assert(conn);
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

protected:
	/// Constructor used by a ServerSocket for new connections
	this(Socket conn)
	{
		this();
		this.conn = conn;
		connected = !(conn is null);
		if (connected)
			socketManager.register(this);
	}

protected:
	/// Retrieve the poll flags for this socket.
	override PollFlags pollFlags()
	{
		PollFlags flags;

		flags.error = true;

		if (!connected)
			flags.write = true;
		else
			flags.write = writePending;

		if (connected && handleReadData)
			flags.read = true;

		return flags;
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
			onError(lastSocketError);
		else
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
					handleReadData(this, Data(inBuffer[0 .. received].dup));
				}
				else
				{
					// Copy to unmanaged memory
					handleReadData(this, Data(inBuffer[0 .. received], true));
				}
			}
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
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
						return onError(lastSocketError);
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

		conn = new Socket(cast(AddressFamily)AddressFamily.INET, SocketType.STREAM, ProtocolType.TCP);
		conn.blocking = false;

		try
			conn.connect(getAddress(host, port)[0]);
		catch (SocketException e)
			return onError("Connect error: " ~ e.msg);

		socketManager.register(this);
	}

	const DefaultDisconnectReason = "Software closed the connection";

	/// Close a connection. If there is queued data waiting to be sent, wait until it is sent before disconnecting.
	void disconnect(string reason = DefaultDisconnectReason, DisconnectType type = DisconnectType.Requested)
	{
		assert(conn);

		if (writePending && type==DisconnectType.Requested)
		{
			// queue disconnect after all data is sent
			//debug writefln("[%s] Queueing disconnect: ", remoteAddress, reason);
			disconnecting = true;
			setIdleTimeout(TickDuration.from!"seconds"(30));
			if (handleDisconnect)
				handleDisconnect(this, reason, type);
			return;
		}

		//debug writefln("[%s] Disconnecting: %s", remoteAddress, reason);
		socketManager.unregister(this);
		conn.close();
		conn = null;
		outQueue[] = null;
		connected = false;
		if (idleTask !is null && idleTask.isWaiting())
			mainTimer.remove(idleTask);
		if (handleDisconnect && !disconnecting)
			handleDisconnect(this, reason, type);
	}

	/// Append data to the send buffer.
	final void send(const(void)[] data, int priority = DEFAULT_PRIORITY)
	{
		send(Data(data), priority);
	}

	/// ditto
	final void send(Data data, int priority = DEFAULT_PRIORITY)
	{
		assert(connected && !disconnecting);
		outQueue[priority] ~= data;
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
		mainTimer.remove(idleTask);
	}

	void resumeIdleTimeout()
	{
		assert(connected);
		assert(idleTask !is null);
		assert(!idleTask.isWaiting());
		mainTimer.add(idleTask);
	}

	final void setIdleTimeout(TickDuration duration)
	{
		assert(duration.length > 0);
		if (idleTask is null)
		{
			idleTask = new TimerTask(duration);
			idleTask.handleTask = &onTask_Idle;
		}
		else
		{
			if (idleTask.isWaiting())
				mainTimer.remove(idleTask);
			idleTask.delay = duration;
		}
		if (connected)
			mainTimer.add(idleTask);
	}

	void markNonIdle()
	{
		assert(idleTask !is null);
		if (idleTask.isWaiting())
			mainTimer.restart(idleTask);
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
	/// Callback for incoming data.
	void delegate(ClientSocket sender, Data data) handleReadData;
	/// Callback for when the send buffer has been flushed.
	void delegate(ClientSocket sender) handleBufferFlushed;
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

		/// Retrieve the poll flags for this socket.
		override PollFlags pollFlags()
		{
			PollFlags flags;

			flags.error = true;
			flags.read = handleAccept !is null;

			return flags;
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
				handleAccept(connection);
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

public:
	/// Debugging aids
	ushort port;
	string addr;

	/// Start listening on this socket.
	ushort listen(ushort port, string addr = null)
	{
		//debug writefln("Listening on %s:%d", addr, port);
		assert(!listening);

		auto addressInfos = getAddressInfo(addr, to!string(port), AddressInfoFlags.PASSIVE, SocketType.STREAM, ProtocolType.TCP);

		foreach (ref addressInfo; addressInfos)
		{
			if (addressInfo.family != AddressFamily.INET && port == 0)
				continue;  // listen on random ports only on IPv4 for now

			version (Windows) enum { IPV6_V6ONLY = 27 }

			int one = 1;
			int flags;
			Socket conn;

			try
			{
				conn = new Socket(addressInfo);
				conn.blocking = false;
				if (addressInfo.family == AddressFamily.INET6)
					conn.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

				conn.bind(addressInfo.address);
				conn.listen(8);

				if (addressInfo.family == AddressFamily.INET)
					port = to!ushort(conn.localAddress.toPortString);

				listeners ~= new Listener(conn);
			}
			catch (SocketException e)
			{
				debug writefln("Unable to listen node \"%s\" service \"%s\"", addressInfo.address.toAddrString(), addressInfo.address.toPortString());
				debug writeln(e.msg);
			}
		}

		if (listeners.length==0)
			throw new Exception("Unable to bind service");

		this.port = port;
		this.addr = addr;

		return port;
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
	/// Callback for an incoming connection.
	void delegate(T incoming) handleAccept;
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
		inBuffer ~= data;

		sizediff_t index;
		bool gotLines;
		while ((index=indexOf(cast(string)inBuffer.contents, delimiter)) >= 0)
		{
			gotLines = true;
			if (handleReadLine)
			{
				string line = cast(string)inBuffer.contents[0..index];
				handleReadLine(this, line.idup);
			}
			inBuffer = inBuffer[index+delimiter.length..inBuffer.length];
		}

		if (gotLines)
			markNonIdle();
	}

public:
	override void cancelIdleTimeout() { assert(false); }
	override void resumeIdleTimeout() { assert(false); }
	//override void setIdleTimeout(d_time duration) { assert(false); }
	//override void markNonIdle() { assert(false); }

	this(TickDuration idleTimeout)
	{
		handleReadData = &onReadData;
		super.setIdleTimeout(idleTimeout);
	}

	this(Socket conn)
	{
		handleReadData = &onReadData;
		super.setIdleTimeout(TickDuration.from!"seconds"(60));
		super(conn);
	}

	/// Cancel a connection.
	override final void disconnect(string reason = DefaultDisconnectReason, DisconnectType type = DisconnectType.Requested)
	{
		super.disconnect(reason, type);
		inBuffer.clear();
	}

	/// Append a line to the send buffer.
	final void send(string line)
	{
		super.send(line ~ delimiter);
	}

public:
	/// Callback for an incoming line.
	void delegate(LineBufferedSocket sender, string line) handleReadLine;
}

/// The default socket manager.
SocketManager socketManager;
