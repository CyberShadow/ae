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
 *   Vladimir Panteleev <ae@cy.md>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.sockets;

// import ae.sys.dataset : DataVec;
import ae.sys.event.common;
import ae.sys.event.system;
import ae.sys.timing;
// import ae.utils.array : asSlice, asBytes;
// import ae.utils.math;
import ae.utils.stream;
// public import ae.sys.data;

// import core.stdc.stdint : int32_t;

// import std.exception;
// import std.parallelism : totalCPUs;
import std.socket;
// import std.string : format;
// public import std.socket : Address, AddressInfo, Socket;

// version (Windows)
// 	private import c_socks = core.sys.windows.winsock2;
// else version (Posix)
// 	private import c_socks = core.sys.posix.sys.socket;

// debug(ASOCKETS) import std.stdio : stderr;
// debug(PRINTDATA) import std.stdio : stderr;
// debug(PRINTDATA) import ae.utils.text : hexDump;
// private import std.conv : to;


// // https://issues.dlang.org/show_bug.cgi?id=7016
// static import ae.utils.array;

// ***************************************************************************

/// General methods for an asynchronous socket.
/// Base class for both listen and connection sockets.
abstract class GenericSocket
{
	/// Declares notifyRead and notifyWrite.
	mixin SocketMixin;

protected:
	/// The socket this class wraps.
	Socket conn;

// protected:
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

	void onError(string /*reason*/)
	{
	}

public:
	/// allow getting the address of connections that are already disconnected
	private Address[2] cachedAddress;

	/*private*/ final @property Address _address(bool local)()
	{
		if (cachedAddress[local] !is null)
			return cachedAddress[local];
		else
		if (conn is null)
			return null;
		else
		{
			Address a;
			if (conn.addressFamily == AddressFamily.UNSPEC)
			{
				// Socket will attempt to construct an UnknownAddress,
				// which will almost certainly not match the real address length.
				static if (local)
					alias getname = c_socks.getsockname;
				else
					alias getname = c_socks.getpeername;

				c_socks.socklen_t nameLen = 0;
				if (getname(conn.handle, null, &nameLen) < 0)
					throw new SocketOSException("Unable to obtain socket address");

				auto buf = new ubyte[nameLen];
				auto sa = cast(c_socks.sockaddr*)buf.ptr;
				if (getname(conn.handle, sa, &nameLen) < 0)
					throw new SocketOSException("Unable to obtain socket address");
				a = new UnknownAddressReference(sa, nameLen);
			}
			else
				a = local ? conn.localAddress() : conn.remoteAddress();
			return cachedAddress[local] = a;
		}
	}

	alias localAddress = _address!true; /// Retrieve this socket's local address.
	alias remoteAddress = _address!false; /// Retrieve this socket's remote address.

	/*private*/ final @property string _addressStr(bool local)() nothrow
	{
		try
		{
			auto a = _address!local;
			if (a is null)
				return "[null address]";
			string host = a.toAddrString();
			import std.string : indexOf;
			if (host.indexOf(':') >= 0)
				host = "[" ~ host ~ "]";
			try
			{
				string port = a.toPortString();
				return host ~ ":" ~ port;
			}
			catch (Exception e)
				return host;
		}
		catch (Exception e)
			return "[error: " ~ e.msg ~ "]";
	}

	alias localAddressStr = _addressStr!true; /// Retrieve this socket's local address, as a string.
	alias remoteAddressStr = _addressStr!false; /// Retrieve this socket's remote address, as a string.

	/// Don't block the process from exiting, even if the socket is ready to receive data.
	/// TODO: Not implemented with libev
	bool daemonRead;

	/// Don't block the process from exiting, even if the socket is ready to send data.
	/// TODO: Not implemented with libev
	bool daemonWrite;

	deprecated alias daemon = daemonRead;

	/// Enable TCP keep-alive on the socket with the given settings.
	final void setKeepAlive(bool enabled=true, int time=10, int interval=5)
	{
		assert(conn, "Attempting to set keep-alive on an uninitialized socket");
		if (enabled)
		{
			try
				conn.setKeepAlive(time, interval);
			catch (SocketException)
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, true);
		}
		else
			conn.setOption(SocketOptionLevel.SOCKET, SocketOption.KEEPALIVE, false);
	}

	/// Returns a string containing the class name, address, and file descriptor.
	override string toString() const
	{
		import std.string : format, split;
		return "%s {this=%s, fd=%s}".format(this.classinfo.name.split(".")[$-1], cast(void*)this, conn ? conn.handle : -1);
	}
}

// ***************************************************************************

/// `IStreamBase` implementation for a socket connection.
class SocketStream : IStreamBase
{
	
}

/// `IReadStream` implementation for a socket connection.
class SocketReadStream : IDataReadStream
{
private:
	Connection conn;
}

/// `IWriteStream` implementation for a socket connection.
class SocketWriteStream : IDataWriteStream
{
private:
	Connection conn;
}

unittest
{
	if (false)
		new SocketReadStream;
}

/// Wraps a `std.socket.Socket` instance, providing read and write streams.
/// On POSIX, the `Socket` may represent any file descriptor, including files,
/// sockets, or pipes.
class Connection : GenericSocket
{
private:
	StreamState _state;
	final @property ConnectionState state(ConnectionState value) { return _state = value; }

public:
	/// Get connection state.
	override @property ConnectionState state() { return _state; }

protected:
	abstract sizediff_t doSend(scope const(void)[] buffer);
	abstract sizediff_t doReceive(scope void[] buffer);

	/// The send buffers.
	DataVec[MAX_PRIORITY+1] outQueue;
	/// Whether the first item from this queue (if any) has been partially sent (and thus can't be canceled).
	int partiallySent = -1;

	/// Constructor used by a ServerSocket for new connections
	this(Socket conn)
	{
		this();
		this.conn = conn;
		state = conn is null ? ConnectionState.disconnected : ConnectionState.connected;
		if (conn)
			eventLoop.register(this);
		updateFlags();
	}

	final void updateFlags()
	{
		if (state == ConnectionState.connecting)
			notifyWrite = true;
		else
			notifyWrite = writePending;

		notifyRead = state == ConnectionState.connected && readDataHandler;
		debug(ASOCKETS) stderr.writefln("[%s] updateFlags: %s %s", conn ? conn.handle : -1, notifyRead, notifyWrite);
	}

	// We reuse the same buffer across read calls.
	// It is allocated on the first read, and also
	// if the user code decides to keep a reference to it.
	static Data inBuffer;

	/// Called when a socket is readable.
	override void onReadable()
	{
		// TODO: use FIONREAD when Phobos gets ioctl support (issue 6649)
		if (!inBuffer)
			inBuffer = Data(0x10000);
		else
			inBuffer = inBuffer.ensureUnique();
		sizediff_t received;
		inBuffer.enter((scope contents) {
			received = doReceive(contents);
		});

		if (received == 0)
			return disconnect("Connection closed", DisconnectType.graceful);

		if (received == Socket.ERROR)
		{
		//	if (wouldHaveBlocked)
		//	{
		//		debug (ASOCKETS) writefln("\t\t%s: wouldHaveBlocked or recv()", this);
		//		return;
		//	}
		//	else
				onError("recv() error: " ~ lastSocketError);
		}
		else
		{
			debug (PRINTDATA)
			{
				stderr.writefln("== %s <- %s ==", localAddressStr, remoteAddressStr);
				stderr.write(hexDump(inBuffer.unsafeContents[0 .. received]));
				stderr.flush();
			}

			if (state == ConnectionState.disconnecting)
			{
				debug (ASOCKETS) stderr.writefln("\t\t%s: Discarding received data because we are disconnecting", this);
			}
			else
			if (!readDataHandler)
			{
				debug (ASOCKETS) stderr.writefln("\t\t%s: Discarding received data because there is no data handler", this);
			}
			else
			{
				auto data = inBuffer[0 .. received];
				readDataHandler(data);
			}
		}
	}

	/// Called when an error occurs on the socket.
	override void onError(string reason)
	{
		if (state == ConnectionState.disconnecting)
		{
			debug (ASOCKETS) stderr.writefln("Socket error while disconnecting @ %s: %s".format(cast(void*)this, reason));
			return close();
		}

		assert(state == ConnectionState.resolving || state == ConnectionState.connecting || state == ConnectionState.connected);
		disconnect("Socket error: " ~ reason, DisconnectType.error);
	}

	this()
	{
	}

public:
	/// Close a connection. If there is queued data waiting to be sent, wait until it is sent before disconnecting.
	/// The disconnect handler will be called immediately, even when not all data has been flushed yet.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		//scope(success) updateFlags(); // Work around scope(success) breaking debugger stack traces
		assert(state.disconnectable, "Attempting to disconnect on a %s socket".format(state));

		if (writePending)
		{
			if (type==DisconnectType.requested)
			{
				assert(conn, "Attempting to disconnect on an uninitialized socket");
				// queue disconnect after all data is sent
				debug (ASOCKETS) stderr.writefln("[%s] Queueing disconnect: %s", remoteAddressStr, reason);
				state = ConnectionState.disconnecting;
				//setIdleTimeout(30.seconds);
				if (disconnectHandler)
					disconnectHandler(reason, type);
				updateFlags();
				return;
			}
			else
				discardQueues();
		}

		debug (ASOCKETS) stderr.writefln("Disconnecting @ %s: %s", cast(void*)this, reason);

		if ((state == ConnectionState.connecting && conn) || state == ConnectionState.connected)
			close();
		else
		{
			assert(conn is null, "Registered but %s socket".format(state));
			if (state == ConnectionState.resolving)
				state = ConnectionState.disconnected;
		}

		if (disconnectHandler)
			disconnectHandler(reason, type);
		updateFlags();
	}

	private final void close()
	{
		assert(conn, "Attempting to close an unregistered socket");
		eventLoop.unregister(this);
		conn.close();
		conn = null;
		outQueue[] = DataVec.init;
		state = ConnectionState.disconnected;
	}

	/// Append data to the send buffer.
	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(state == ConnectionState.connected, "Attempting to send on a %s socket".format(state));
		outQueue[priority] ~= data;
		notifyWrite = true; // Fast updateFlags()

		debug (PRINTDATA)
		{
			stderr.writefln("== %s -> %s ==", localAddressStr, remoteAddressStr);
			foreach (datum; data)
				if (datum.length)
					stderr.write(hexDump(datum.unsafeContents));
				else
					stderr.writeln("(empty Data)");
			stderr.flush();
		}
	}

	/// ditto
	alias send = IConnection.send;

	/// Cancel all queued `Data` packets with the given priority.
	/// Does not cancel any partially-sent `Data`.
	final void clearQueue(int priority)
	{
		if (priority == partiallySent)
		{
			assert(outQueue[priority].length > 0);
			outQueue[priority].length = 1;
		}
		else
			outQueue[priority] = null;
		updateFlags();
	}

	/// Clears all queues, even partially sent content.
	private final void discardQueues()
	{
		foreach (priority; 0..MAX_PRIORITY+1)
			outQueue[priority] = null;
		partiallySent = -1;
		updateFlags();
	}

	/// Returns true if any queues have pending data.
	@property
	final bool writePending()
	{
		foreach (ref queue; outQueue)
			if (queue.length)
				return true;
		return false;
	}

	/// Returns true if there are any queued `Data` which have not yet
	/// begun to be sent.
	final bool queuePresent(int priority = DEFAULT_PRIORITY)
	{
		if (priority == partiallySent)
		{
			assert(outQueue[priority].length > 0);
			return outQueue[priority].length > 1;
		}
		else
			return outQueue[priority].length > 0;
	}

	/// Returns the number of queued `Data` at the given priority.
	final size_t packetsQueued(int priority = DEFAULT_PRIORITY)
	{
		return outQueue[priority].length;
	}

	/// Returns the number of queued bytes at the given priority.
	final size_t bytesQueued(int priority = DEFAULT_PRIORITY)
	{
		size_t bytes;
		foreach (datum; outQueue[priority])
			bytes += datum.length;
		return bytes;
	}

// public:
	private ConnectHandler connectHandler;
	/// Callback for when a connection has been established.
	@property final void handleConnect(ConnectHandler value) { connectHandler = value; updateFlags(); }

	private ReadDataHandler readDataHandler;
	/// Callback for incoming data.
	/// Data will not be received unless this handler is set.
	@property final void handleReadData(ReadDataHandler value) { readDataHandler = value; updateFlags(); }

	private DisconnectHandler disconnectHandler;
	/// Callback for when a connection was closed.
	@property final void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; updateFlags(); }

	private BufferFlushedHandler bufferFlushedHandler;
	/// Callback setter for when all queued data has been sent.
	@property final void handleBufferFlushed(BufferFlushedHandler value) { bufferFlushedHandler = value; updateFlags(); }
}

/// Implements a stream connection.
/// Queued `Data` is allowed to be fragmented.
/// (Note: "Stream" here is as in `SOCK_STREAM` and not `ae.utils.stream`.)
class StreamConnection : Connection
{
protected:
	this()
	{
		super();
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		//scope(success) updateFlags();
		onWritableImpl();
		updateFlags();
	}

	// Work around scope(success) breaking debugger stack traces
	final private void onWritableImpl()
	{
		debug(ASOCKETS) stderr.writefln("[%s] onWritableImpl (we are %s)", conn ? conn.handle : -1, state);
		if (state == ConnectionState.connecting)
		{
			int32_t error;
			conn.getOption(SocketOptionLevel.SOCKET, SocketOption.ERROR, error);
			if (error)
				return disconnect(formatSocketError(error), DisconnectType.error);

			state = ConnectionState.connected;

			//debug writefln("[%s] Connected", remoteAddressStr);
			try
				setKeepAlive();
			catch (Exception e)
				return disconnect(e.msg, DisconnectType.error);
			if (connectHandler)
				connectHandler();
			return;
		}
		//debug writefln(remoteAddressStr, ": Writable - handler ", handleBufferFlushed?"OK":"not set", ", outBuffer.length=", outBuffer.length);

		foreach (sendPartial; [true, false])
			foreach (int priority, ref queue; outQueue)
				while (queue.length && (!sendPartial || priority == partiallySent))
				{
					assert(partiallySent == -1 || partiallySent == priority);

					ptrdiff_t sent = 0;
					if (!queue.front.empty)
					{
						queue.front.enter((scope contents) {
							sent = doSend(contents);
						});
						debug (ASOCKETS) stderr.writefln("\t\t%s: sent %d/%d bytes", this, sent, queue.front.length);
					}
					else
					{
						debug (ASOCKETS) stderr.writefln("\t\t%s: empty Data object", this);
					}

					if (sent == Socket.ERROR)
					{
						if (wouldHaveBlocked())
							return;
						else
							return onError("send() error: " ~ lastSocketError);
					}
					else
					if (sent < queue.front.length)
					{
						if (sent > 0)
						{
							queue.front = queue.front[sent..queue.front.length];
							partiallySent = priority;
						}
						return;
					}
					else
					{
						assert(sent == queue.front.length);
						//debug writefln("[%s] Sent data:", remoteAddressStr);
						//debug writefln("%s", hexDump(queue.front.contents[0..sent]));
						queue.front.clear();
						queue.popFront();
						partiallySent = -1;
						if (queue.length == 0)
							queue = null;
					}
				}

		// outQueue is now empty
		if (bufferFlushedHandler)
			bufferFlushedHandler();
		if (state == ConnectionState.disconnecting)
		{
			debug (ASOCKETS) stderr.writefln("Closing @ %s (Delayed disconnect - buffer flushed)", cast(void*)this);
			close();
		}
	}

public:
	this(Socket conn)
	{
		super(conn);
	} ///
}

// ***************************************************************************

/// A POSIX file stream.
/// Allows adding a file (e.g. stdin/stdout) to the socket manager.
/// Does not dup the given file descriptor, so "disconnecting" this connection
/// will close it.
version (Posix)
class FileConnection : StreamConnection
{
	this(int fileno)
	{
		auto conn = new Socket(cast(socket_t)fileno, AddressFamily.UNSPEC);
		conn.blocking = false;
		super(conn);
	} ///

protected:
	import core.sys.posix.unistd : read, write;

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		return write(socket.handle, buffer.ptr, buffer.length);
	}

	override sizediff_t doReceive(scope void[] buffer)
	{
		return read(socket.handle, buffer.ptr, buffer.length);
	}
}

/// Separates reading and writing, e.g. for stdin/stdout.
class Duplex : IConnection
{
	///
	IConnection reader, writer;

	this(IConnection reader, IConnection writer)
	{
		this.reader = reader;
		this.writer = writer;
		reader.handleConnect = &onConnect;
		writer.handleConnect = &onConnect;
		reader.handleDisconnect = &onDisconnect;
		writer.handleDisconnect = &onDisconnect;
	} ///

	@property ConnectionState state()
	{
		if (reader.state == ConnectionState.disconnecting || writer.state == ConnectionState.disconnecting)
			return ConnectionState.disconnecting;
		else
			return reader.state < writer.state ? reader.state : writer.state;
	} ///

	/// Queue Data for sending.
	void send(scope Data[] data, int priority)
	{
		writer.send(data, priority);
	}

	alias send = IConnection.send; /// ditto

	/// Terminate the connection.
	/// Note: this isn't quite fleshed out - applications may want to
	/// wait and send some more data even after stdin is closed, but
	/// such an interface can't be fitted into an IConnection
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		if (reader.state > ConnectionState.disconnected && reader.state < ConnectionState.disconnecting)
			reader.disconnect(reason, type);
		if (writer.state > ConnectionState.disconnected && writer.state < ConnectionState.disconnecting)
			writer.disconnect(reason, type);
		debug(ASOCKETS) stderr.writefln("Duplex.disconnect(%(%s%), %s), states are %s / %s", [reason], type, reader.state, writer.state);
	}

	protected void onConnect()
	{
		if (connectHandler && reader.state == ConnectionState.connected && writer.state == ConnectionState.connected)
			connectHandler();
	}

	protected void onDisconnect(string reason, DisconnectType type)
	{
		debug(ASOCKETS) stderr.writefln("Duplex.onDisconnect(%(%s%), %s), states are %s / %s", [reason], type, reader.state, writer.state);
		if (disconnectHandler)
		{
			disconnectHandler(reason, type);
			disconnectHandler = null; // don't call it twice for the other connection
		}
		// It is our responsibility to disconnect the other connection
		// Use DisconnectType.requested to ensure that any written data is flushed
		disconnect("Other side of Duplex connection closed (" ~ reason ~ ")", DisconnectType.requested);
	}

	/// Callback for when a connection has been established.
	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	private ConnectHandler connectHandler;

	/// Callback setter for when new data is read.
	@property void handleReadData(ReadDataHandler value) { reader.handleReadData = value; }

	/// Callback setter for when a connection was closed.
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	private DisconnectHandler disconnectHandler;

	/// Callback setter for when all queued data has been written.
	@property void handleBufferFlushed(BufferFlushedHandler value) { writer.handleBufferFlushed = value; }
}

unittest { if (false) new Duplex(null, null); }

// ***************************************************************************

/// An asynchronous socket-based connection.
/// Used for file descriptors which use the
/// `send`/`receive` POSIX / Berkeley socket APIs.
class SocketConnection : StreamConnection
{
protected:
	AddressInfo[] addressQueue;

	this(Socket conn)
	{
		super(conn);
	}

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		return conn.send(buffer);
	}

	override sizediff_t doReceive(scope void[] buffer)
	{
		return conn.receive(buffer);
	}

	final void tryNextAddress()
	{
		assert(state == ConnectionState.connecting);
		auto addressInfo = addressQueue[0];
		addressQueue = addressQueue[1..$];

		try
		{
			conn = new Socket(addressInfo.family, addressInfo.type, addressInfo.protocol);
			conn.blocking = false;

			eventLoop.register(this);
			updateFlags();
			debug (ASOCKETS) stderr.writefln("Attempting connection to %s", addressInfo.address.toString());
			conn.connect(addressInfo.address);
		}
		catch (SocketException e)
			return onError("Connect error: " ~ e.msg);
	}

	/// Called when an error occurs on the socket.
	override void onError(string reason)
	{
		if (state == ConnectionState.connecting && addressQueue.length)
		{
			eventLoop.unregister(this);
			conn.close();
			conn = null;

			return tryNextAddress();
		}

		super.onError(reason);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New SocketConnection @ %s", cast(void*)this);
	}

	/// Start establishing a connection.
	final void connect(AddressInfo[] addresses)
	{
		assert(addresses.length, "No addresses specified");

		assert(state == ConnectionState.disconnected, "Attempting to connect on a %s socket".format(state));
		assert(!conn);

		addressQueue = addresses;
		state = ConnectionState.connecting;
		tryNextAddress();
	}
}

/// An asynchronous TCP connection.
class TcpConnection : SocketConnection
{
protected:
	this(Socket conn)
	{
		super(conn);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New TcpConnection @ %s", cast(void*)this);
	}

	///
	alias connect = SocketConnection.connect; // raise overload

	/// Start establishing a connection.
	final void connect(string host, ushort port)
	{
		assert(host.length, "Empty host");
		assert(port, "No port specified");

		debug (ASOCKETS) stderr.writefln("Connecting to %s:%s", host, port);
		assert(state == ConnectionState.disconnected, "Attempting to connect on a %s socket".format(state));

		state = ConnectionState.resolving;

		AddressInfo[] addressInfos;
		try
		{
			auto addresses = getAddress(host, port);
			enforce(addresses.length, "No addresses found");
			debug (ASOCKETS)
			{
				stderr.writefln("Resolved to %s addresses:", addresses.length);
				foreach (address; addresses)
					stderr.writefln("- %s", address.toString());
			}

			if (addresses.length > 1)
			{
				import std.random : randomShuffle;
				randomShuffle(addresses);
			}

			foreach (address; addresses)
				addressInfos ~= AddressInfo(address.addressFamily, SocketType.STREAM, ProtocolType.TCP, address, host);
		}
		catch (SocketException e)
			return onError("Lookup error: " ~ e.msg);

		state = ConnectionState.disconnected;
		connect(addressInfos);
	}
}

// ***************************************************************************

/// An asynchronous connection server for socket-based connections.
class SocketServer
{
protected:
	/// Class that actually performs listening on a certain address family
	final class Listener : GenericSocket
	{
		this(Socket conn)
		{
			debug (ASOCKETS) stderr.writefln("New Listener @ %s", cast(void*)this);
			this.conn = conn;
			eventLoop.register(this);
		}

		/// Called when a socket is readable.
		override void onReadable()
		{
			debug (ASOCKETS) stderr.writefln("Accepting connection from listener @ %s", cast(void*)this);
			Socket acceptSocket = conn.accept();
			acceptSocket.blocking = false;
			if (handleAccept)
			{
				auto connection = createConnection(acceptSocket);
				debug (ASOCKETS) stderr.writefln("\tAccepted connection %s from %s", connection, connection.remoteAddressStr);
				connection.setKeepAlive();
				//assert(connection.connected);
				//connection.connected = true;
				acceptHandler(connection);
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
			eventLoop.unregister(this);
			conn.close();
			conn = null;
		}
	}

	SocketConnection createConnection(Socket socket)
	{
		return new SocketConnection(socket);
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
	/// Start listening on this socket.
	final void listen(AddressInfo[] addressInfos)
	{
		foreach (ref addressInfo; addressInfos)
		{
			try
			{
				Socket conn = new Socket(addressInfo);
				conn.blocking = false;
				if (addressInfo.family == AddressFamily.INET6)
					conn.setOption(SocketOptionLevel.IPV6, SocketOption.IPV6_V6ONLY, true);
				conn.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);

				conn.bind(addressInfo.address);
				conn.listen(totalCPUs * 2);

				listeners ~= new Listener(conn);
			}
			catch (SocketException e)
			{
				debug(ASOCKETS) stderr.writefln("Unable to listen node \"%s\" service \"%s\"", addressInfo.address.toAddrString(), addressInfo.address.toPortString());
				debug(ASOCKETS) stderr.writeln(e.msg);
			}
		}

		if (listeners.length==0)
			throw new Exception("Unable to bind service");

		listening = true;

		updateFlags();
	}

	this()
	{
	} ///

	/// Creates a Server with the given sockets.
	/// The sockets must have already had `bind` and `listen` called on them.
	this(Socket[] sockets...)
	{
		foreach (socket; sockets)
			listeners ~= new Listener(socket);
	}

	/// Returns all listening addresses.
	final @property Address[] localAddresses()
	{
		Address[] result;
		foreach (listener; listeners)
			result ~= listener.localAddress;
		return result;
	}

	/// Returns `true` if the server is listening for incoming connections.
	final @property bool isListening()
	{
		return listening;
	}

	/// Stop listening on this socket.
	final void close()
	{
		foreach (listener;listeners)
			listener.closeListener();
		listeners = null;
		listening = false;
		if (handleClose)
			handleClose();
	}

	/// Create a SocketServer using the handle passed on standard input,
	/// for which `listen` had already been called. Used by
	/// e.g. FastCGI and systemd sockets with "Listen = yes".
	static SocketServer fromStdin()
	{
		socket_t socket;
		version (Windows)
		{
			import core.sys.windows.winbase : GetStdHandle, STD_INPUT_HANDLE;
			socket = cast(socket_t)GetStdHandle(STD_INPUT_HANDLE);
		}
		else
			socket = cast(socket_t)0;

		auto s = new Socket(socket, AddressFamily.UNSPEC);
		s.blocking = false;
		return new SocketServer(s);
	}

	/// Callback for when the socket was closed.
	void delegate() handleClose;

	private void delegate(SocketConnection incoming) acceptHandler;
	/// Callback for an incoming connection.
	/// Connections will not be accepted unless this handler is set.
	@property final void delegate(SocketConnection incoming) handleAccept() { return acceptHandler; }
	/// ditto
	@property final void handleAccept(void delegate(SocketConnection incoming) value) { acceptHandler = value; updateFlags(); }
}

/// An asynchronous TCP connection server.
class TcpServer : SocketServer
{
protected:
	override SocketConnection createConnection(Socket socket)
	{
		return new TcpConnection(socket);
	}

public:
	this()
	{
	} ///

	this(Socket[] sockets...)
	{
		super(sockets);
	} /// Construct from the given sockets.

	///
	alias listen = SocketServer.listen; // raise overload

	/// Start listening on this socket.
	final ushort listen(ushort port, string addr = null)
	{
		debug(ASOCKETS) stderr.writefln("Attempting to listen on %s:%d", addr, port);
		//assert(!listening, "Attempting to listen on a listening socket");

		auto addressInfos = getAddressInfo(addr, to!string(port), AddressInfoFlags.PASSIVE, SocketType.STREAM, ProtocolType.TCP);

		debug (ASOCKETS)
		{
			stderr.writefln("Resolved to %s addresses:", addressInfos.length);
			foreach (ref addressInfo; addressInfos)
				stderr.writefln("- %s", addressInfo);
		}

		// listen on random ports only on IPv4 for now
		if (port == 0)
		{
			foreach_reverse (i, ref addressInfo; addressInfos)
				if (addressInfo.family != AddressFamily.INET)
					addressInfos = addressInfos[0..i] ~ addressInfos[i+1..$];
		}

		listen(addressInfos);

		foreach (listener; listeners)
		{
			auto address = listener.conn.localAddress();
			if (address.addressFamily == AddressFamily.INET)
				port = to!ushort(address.toPortString());
		}

		return port;
	}

	deprecated("Use SocketServer.fromStdin")
	static TcpServer fromStdin() { return cast(TcpServer) cast(void*) SocketServer.fromStdin; }

	/// Delegate to be called when a connection is accepted.
	@property final void handleAccept(void delegate(TcpConnection incoming) value) { super.handleAccept((SocketConnection c) => value(cast(TcpConnection)c)); }
}

// ***************************************************************************

/// Base class for connection-less socket protocols, i.e. those for
/// which we must use sendto instead of connect/send.
/// These generally correspond to stateless / datagram-based
/// protocols, like UDP.
/// This module's class hierarchy is mostly oriented towards
/// stateful, stream-based protocols; to represent connectionless
/// protocols, this class encapsulates a socket with a fixed
/// destination (sendto) address, and optionally bound to a local
/// address.
/// Currently received packets' address is not exposed.
class ConnectionlessSocketConnection : Connection
{
protected:
	this(Socket conn)
	{
		super(conn);
	}

	/// Called when a socket is writable.
	override void onWritable()
	{
		//scope(success) updateFlags();
		onWritableImpl();
		updateFlags();
	}

	// Work around scope(success) breaking debugger stack traces
	final private void onWritableImpl()
	{
		foreach (priority, ref queue; outQueue)
			while (queue.length)
			{
				ptrdiff_t sent;
				queue.front.enter((scope contents) {
					sent = conn.sendTo(contents, remoteAddress);
				});

				if (sent == Socket.ERROR)
				{
					if (wouldHaveBlocked())
						return;
					else
						return onError("send() error: " ~ lastSocketError);
				}
				else
				if (sent < queue.front.length)
				{
					return onError("Sent only %d/%d bytes of the datagram!".format(sent, queue.front.length));
				}
				else
				{
					assert(sent == queue.front.length);
					//debug writefln("[%s] Sent data:", remoteAddressStr);
					//debug writefln("%s", hexDump(pdata.contents[0..sent]));
					queue.front.clear();
					queue.popFront();
					if (queue.length == 0)
						queue = null;
				}
			}

		// outQueue is now empty
		if (bufferFlushedHandler)
			bufferFlushedHandler();
		if (state == ConnectionState.disconnecting)
		{
			debug (ASOCKETS) stderr.writefln("Closing @ %s (Delayed disconnect - buffer flushed)", cast(void*)this);
			close();
		}
	}

	override sizediff_t doSend(scope const(void)[] buffer)
	{
		assert(false); // never called (called only from overridden methods)
	}

	override sizediff_t doReceive(scope void[] buffer)
	{
		return conn.receive(buffer);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New ConnectionlessSocketConnection @ %s", cast(void*)this);
	}

	/// Initialize with the given `AddressFamily`, without binding to an address.
	final void initialize(AddressFamily family, SocketType type, ProtocolType protocol)
	{
		initializeImpl(family, type, protocol);
		if (connectHandler)
			connectHandler();
	}

	private final void initializeImpl(AddressFamily family, SocketType type, ProtocolType protocol)
	{
		assert(state == ConnectionState.disconnected, "Attempting to initialize a %s socket".format(state));
		assert(!conn);

		conn = new Socket(family, type, protocol);
		conn.blocking = false;
		eventLoop.register(this);
		state = ConnectionState.connected;
		updateFlags();
	}

	/// Bind to a local address in order to receive packets sent there.
	final ushort bind(AddressInfo addressInfo)
	{
		initialize(addressInfo.family, addressInfo.type, addressInfo.protocol);
		conn.bind(addressInfo.address);

		auto address = conn.localAddress();
		auto port = to!ushort(address.toPortString());

		if (connectHandler)
			connectHandler();

		return port;
	}

// public:
	/// Where to send packets to.
	Address remoteAddress;
}

/// An asynchronous UDP stream.
/// UDP does not have connections, so this class encapsulates a socket
/// with a fixed destination (sendto) address, and optionally bound to
/// a local address.
/// Currently received packets' address is not exposed.
class UdpConnection : ConnectionlessSocketConnection
{
protected:
	this(Socket conn)
	{
		super(conn);
	}

public:
	/// Default constructor
	this()
	{
		debug (ASOCKETS) stderr.writefln("New UdpConnection @ %s", cast(void*)this);
	}

	/// Initialize with the given `AddressFamily`, without binding to an address.
	final void initialize(AddressFamily family, SocketType type = SocketType.DGRAM)
	{
		super.initialize(family, type, ProtocolType.UDP);
	}

	/// Bind to a local address in order to receive packets sent there.
	final ushort bind(string host, ushort port)
	{
		assert(host.length, "Empty host");

		debug (ASOCKETS) stderr.writefln("Connecting to %s:%s", host, port);

		state = ConnectionState.resolving;

		AddressInfo addressInfo;
		try
		{
			auto addresses = getAddress(host, port);
			enforce(addresses.length, "No addresses found");
			debug (ASOCKETS)
			{
				stderr.writefln("Resolved to %s addresses:", addresses.length);
				foreach (address; addresses)
					stderr.writefln("- %s", address.toString());
			}

			Address address;
			if (addresses.length > 1)
			{
				import std.random : uniform;
				address = addresses[uniform(0, $)];
			}
			else
				address = addresses[0];
			addressInfo = AddressInfo(address.addressFamily, SocketType.DGRAM, ProtocolType.UDP, address, host);
		}
		catch (SocketException e)
		{
			onError("Lookup error: " ~ e.msg);
			return 0;
		}

		state = ConnectionState.disconnected;
		return super.bind(addressInfo);
	}
}

///
unittest
{
	auto server = new UdpConnection();
	server.bind("127.0.0.1", 0);

	auto client = new UdpConnection();
	client.initialize(server.localAddress.addressFamily);

	string[] packets = ["Hello", "there"];
	client.remoteAddress = server.localAddress;
	client.send({
		DataVec data;
		foreach (packet; packets)
			data ~= Data(packet.asBytes);
		return data;
	}()[]);

	server.handleReadData = (Data data)
	{
		assert(data.unsafeContents == packets[0]);
		packets = packets[1..$];
		if (!packets.length)
		{
			server.close();
			client.close();
		}
	};
	eventLoop.loop();
	assert(!packets.length);
}

// ***************************************************************************

/// Base class for a connection adapter.
/// By itself, does nothing.
class ConnectionAdapter : IConnection
{
	/// The next connection in the chain (towards the raw transport).
	IConnection next;

	this(IConnection next)
	{
		this.next = next;
		next.handleConnect = &onConnect;
		next.handleDisconnect = &onDisconnect;
		next.handleBufferFlushed = &onBufferFlushed;
	} ///

	@property ConnectionState state() { return next.state; } ///

	/// Queue Data for sending.
	void send(scope Data[] data, int priority)
	{
		next.send(data, priority);
	}

	alias send = IConnection.send; /// ditto

	/// Terminate the connection.
	void disconnect(string reason = defaultDisconnectReason, DisconnectType type = DisconnectType.requested)
	{
		next.disconnect(reason, type);
	}

	protected void onConnect()
	{
		if (connectHandler)
			connectHandler();
	}

	protected void onReadData(Data data)
	{
		// onReadData should be fired only if readDataHandler is set
		assert(readDataHandler, "onReadData caled with null readDataHandler");
		readDataHandler(data);
	}

	protected void onDisconnect(string reason, DisconnectType type)
	{
		if (disconnectHandler)
			disconnectHandler(reason, type);
	}

	protected void onBufferFlushed()
	{
		if (bufferFlushedHandler)
			bufferFlushedHandler();
	}

	/// Callback for when a connection has been established.
	@property void handleConnect(ConnectHandler value) { connectHandler = value; }
	protected ConnectHandler connectHandler;

	/// Callback setter for when new data is read.
	@property void handleReadData(ReadDataHandler value)
	{
		readDataHandler = value;
		next.handleReadData = value ? &onReadData : null ;
	}
	protected ReadDataHandler readDataHandler;

	/// Callback setter for when a connection was closed.
	@property void handleDisconnect(DisconnectHandler value) { disconnectHandler = value; }
	protected DisconnectHandler disconnectHandler;

	/// Callback setter for when all queued data has been written.
	@property void handleBufferFlushed(BufferFlushedHandler value) { bufferFlushedHandler = value; }
	protected BufferFlushedHandler bufferFlushedHandler;
}

// ***************************************************************************

/// Adapter for connections with a line-based protocol.
/// Splits data stream into delimiter-separated lines.
class LineBufferedAdapter : ConnectionAdapter
{
	/// The protocol's line delimiter.
	string delimiter = "\r\n";

	/// Maximum line length (0 means unlimited).
	size_t maxLength = 0;

	this(IConnection next)
	{
		super(next);
	} ///

	/// Append a line to the send buffer.
	void send(string line)
	{
		//super.send(Data(line ~ delimiter));
		// https://issues.dlang.org/show_bug.cgi?id=13985
		ConnectionAdapter ca = this;
		ca.send(Data(line.asBytes ~ delimiter.asBytes));
	}

protected:
	/// The receive buffer.
	Data inBuffer;

	/// Called when data has been received.
	final override void onReadData(Data data)
	{
		import std.string : indexOf;
		auto startIndex = inBuffer.length;
		if (inBuffer.length)
			inBuffer ~= data;
		else
			inBuffer = data;

		assert(delimiter.length >= 1);
		if (startIndex >= delimiter.length)
			startIndex -= delimiter.length - 1;
		else
			startIndex = 0;

		auto index = inBuffer[startIndex .. $].indexOf(delimiter.asBytes);
		while (index >= 0)
		{
			if (!processLine(startIndex + index))
				break;

			startIndex = 0;
			index = inBuffer.indexOf(delimiter.asBytes);
		}

		if (maxLength && inBuffer.length > maxLength)
			disconnect("Line too long", DisconnectType.error);
	}

	// `index` is the index of the delimiter's first character.
	final bool processLine(size_t index)
	{
		if (maxLength && index > maxLength)
		{
			disconnect("Line too long", DisconnectType.error);
			return false;
		}
		auto line = inBuffer[0..index];
		inBuffer = inBuffer[index+delimiter.length..inBuffer.length];
		super.onReadData(line);
		return true;
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		super.onDisconnect(reason, type);
		inBuffer.clear();
	}
}

// ***************************************************************************

/// Fires an event handler or disconnects connections
/// after a period of inactivity.
class TimeoutAdapter : ConnectionAdapter
{
	this(IConnection next)
	{
		debug (ASOCKETS) stderr.writefln("New TimeoutAdapter @ %s", cast(void*)this);
		super(next);
	} ///

	/// Set the `Duration` indicating the period of inactivity after which to take action.
	final void setIdleTimeout(Duration timeout)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.setIdleTimeout @ %s", cast(void*)this);
		assert(timeout > Duration.zero);
		this.timeout = timeout;

		// Configure idleTask
		if (idleTask is null)
		{
			idleTask = new TimerTask();
			idleTask.handleTask = &onTask_Idle;
		}
		else if (idleTask.isWaiting())
			idleTask.cancel();

		mainTimer.add(idleTask, now + timeout);
	}

	/// Manually mark this connection as non-idle, restarting the idle timer.
	/// `handleNonIdle` will be called, if set.
	void markNonIdle()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.markNonIdle @ %s", cast(void*)this);
		if (handleNonIdle)
			handleNonIdle();
		if (idleTask && idleTask.isWaiting())
			idleTask.restart(now + timeout);
	}

	/// Stop the idle timer.
	void cancelIdleTimeout()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.cancelIdleTimeout @ %s", cast(void*)this);
		assert(idleTask !is null);
		assert(idleTask.isWaiting());
		idleTask.cancel();
	}

	/// Restart the idle timer.
	void resumeIdleTimeout()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.resumeIdleTimeout @ %s", cast(void*)this);
		assert(idleTask !is null);
		assert(!idleTask.isWaiting());
		mainTimer.add(idleTask, now + timeout);
	}

	/// Callback for when a connection has stopped responding.
	/// If unset, the connection will be disconnected.
	void delegate() handleIdleTimeout;

	/// Callback for when a connection is marked as non-idle
	/// (when data is received).
	void delegate() handleNonIdle;

protected:
	override void onConnect()
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onConnect @ %s", cast(void*)this);
		markNonIdle();
		super.onConnect();
	}

	override void onReadData(Data data)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onReadData @ %s", cast(void*)this);
		markNonIdle();
		super.onReadData(data);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onDisconnect @ %s", cast(void*)this);
		if (idleTask && idleTask.isWaiting())
			idleTask.cancel();
		super.onDisconnect(reason, type);
	}

private:
	TimerTask idleTask; // non-null if an idle timeout has been set
	Duration timeout;

	final void onTask_Idle(Timer /*timer*/, TimerTask /*task*/)
	{
		debug (ASOCKETS) stderr.writefln("TimeoutAdapter.onTask_Idle @ %s", cast(void*)this);
		if (state == ConnectionState.disconnecting)
			return disconnect("Delayed disconnect - time-out", DisconnectType.error);

		if (state == ConnectionState.disconnected)
			return;

		if (handleIdleTimeout)
		{
			resumeIdleTimeout(); // reschedule (by default)
			handleIdleTimeout();
		}
		else
			disconnect("Time-out", DisconnectType.error);
	}
}

// ***************************************************************************

unittest
{
	void testTimer()
	{
		bool fired;
		setTimeout({fired = true;}, 10.msecs);
		eventLoop.loop();
		assert(fired);
	}

	testTimer();
}
