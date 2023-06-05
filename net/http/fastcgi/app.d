/**
 * Support for implementing FastCGI application servers.
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

module ae.net.http.fastcgi.app;

version (Windows)
{
	import core.sys.windows.winbase;
	import core.sys.windows.winsock2;
}
else
	import core.stdc.errno;

import std.algorithm.mutation : move;
import std.algorithm.searching;
import std.array;
import std.bitmanip;
import std.conv;
import std.exception;
import std.format;
import std.process : environment;
import std.socket;

import ae.net.asockets;
import ae.net.http.common;
import ae.net.http.cgi.common;
import ae.net.http.cgi.script;
import ae.net.http.fastcgi.common;
import ae.sys.dataset : DataVec;
import ae.sys.log;
import ae.utils.array;

private Socket getListenSocket()
{
	socket_t socket;
	version (Windows)
		socket = cast(socket_t)GetStdHandle(STD_INPUT_HANDLE);
	else
		socket = cast(socket_t)FCGI_LISTENSOCK_FILENO;

	return new Socket(socket, AddressFamily.UNSPEC);
}

/// Return true if the current process was
/// likely invoked as a FastCGI application.
bool inFastCGI()
{
	auto socket = getListenSocket();
	try
	{
		socket.remoteAddress();
		return false;
	}
	catch (SocketOSException e)
		return e.errorCode == ENOTCONN;
}

/// Base implementation of the low-level FastCGI protocol.
class FastCGIConnection
{
	private Data buffer;
	IConnection connection; /// Connection used to construct this object.
	Logger log;             /// Optional logger.

	/// Constructor.
	/// Params:
	///  connection = Abstract connection used for communication.
	this(IConnection connection)
	{
		this.connection = connection;
		connection.handleReadData = &onReadData;
	}

	protected void onReadData(Data data)
	{
		buffer ~= data;

		while (true)
		{
			if (buffer.length < FCGI_RecordHeader.sizeof)
				return;

			auto header = buffer[0 .. FCGI_RecordHeader.sizeof].asDataOf!FCGI_RecordHeader.front;
			auto totalLength = FCGI_RecordHeader.sizeof + header.contentLength + header.paddingLength;
			if (buffer.length < totalLength)
				return;

			auto contentData = buffer[FCGI_RecordHeader.sizeof .. FCGI_RecordHeader.sizeof + header.contentLength];

			try
				onRecord(header, contentData);
			catch (Exception e)
			{
				if (log) log("Error handling record: " ~ e.toString());
				connection.disconnect(e.msg);
				return;
			}

			buffer = buffer[totalLength .. $];
		}
	}

	protected abstract void onRecord(ref FCGI_RecordHeader header, Data contentData);
}

/// ditto
class FastCGIAppSocketServer
{
	/// Addresses to listen on.
	/// Populated from `FCGI_WEB_SERVER_ADDRS` by default.
	string[] serverAddrs;
	Logger log; /// Optional logger.

	///
	this()
	{
		serverAddrs = environment.get("FCGI_WEB_SERVER_ADDRS", null).split(",");
	}

	/// Begin listening.
	/// Params:
	///  socket = Listen on this socket instead of the default.
	final void listen(Socket socket = getListenSocket())
	{
		socket.blocking = false;
		auto listener = new TcpServer(socket);
		listener.handleAccept(&onAccept);
	}

	protected final void onAccept(TcpConnection connection)
	{
		if (log) log("Accepted connection from " ~ connection.remoteAddressStr);
		if (serverAddrs && !serverAddrs.canFind(connection.remoteAddressStr))
		{
			if (log) log("Address not in FCGI_WEB_SERVER_ADDRS, rejecting");
			connection.disconnect("Forbidden by FCGI_WEB_SERVER_ADDRS");
			return;
		}
		createConnection(connection);
	}

	protected abstract void createConnection(IConnection connection);
}

/// Higher-level FastCGI app server implementation,
/// handling the various FastCGI response types.
class FastCGIProtoConnection : FastCGIConnection
{
	// Some conservative limits that are unlikely to run afoul of any
	// default limits such as file descriptor ulimit.
	size_t maxConns = 512; /// Maximum number of concurrent connections to advertise.
	size_t maxReqs = 4096; /// Maximum number of concurrent requests to advertise.
	bool mpxsConns = true; /// Whether to advertise support for multiplexing.

	///
	this(IConnection connection) { super(connection); }

	/// Base class for an abstract ongoing FastCGI request.
	class Request
	{
		ushort id;      /// FastCGI request ID.
		FCGI_Role role; /// FastCGI role. (Responder, authorizer...)
		bool keepConn;  /// Keep connection alive after handling request.
		Data paramBuf;  /// Buffer used to hold the parameters.

		void begin() {} /// Handle the beginning of processing this request.
		void abort() {} /// Handle a request to abort processing this request.
		/// Handle an incoming request parameter.
		void param(const(char)[] name, const(char)[] value) {}
		void paramEnd() {} /// Handle the end of request parameters.
		void stdin(Data datum) {} /// Handle a chunk of input (i.e. request body) data.
		void stdinEnd() {} /// Handle the end of input data.
		void data(Data datum) {} /// Handle a chunk of additional data.
		void dataEnd() {} /// Handle the end of additional data.

	final:
		/// Send output (response) data.
		void stdout(Data datum) { assert(datum.length); sendRecord(FCGI_RecordType.stdout, id, datum); }
		/// Finish sending output data.
		void stdoutEnd() { sendRecord(FCGI_RecordType.stdout, id, Data.init); }
		/// Send error data.
		void stderr(Data datum) { assert(datum.length); sendRecord(FCGI_RecordType.stderr, id, datum); }
		/// Finish sending error data.
		void stderrEnd() { sendRecord(FCGI_RecordType.stderr, id, Data.init); }
		/// Finish processing this request, with the indicated status codes.
		void end(uint appStatus, FCGI_ProtocolStatus status)
		{
			FCGI_EndRequestBody data;
			data.appStatus = appStatus;
			data.protocolStatus = status;
			sendRecord(FCGI_RecordType.endRequest, id, Data(data.asBytes));
			killRequest(id);
			if (!keepConn)
				connection.disconnect("End of request without FCGI_KEEP_CONN");
		}
	}

	/// In-flight requests.
	Request[] requests;

	/// Override this method to provide a factory for your Request
	/// implementation.
	abstract Request createRequest();

	/// Return the request with the given ID.
	Request getRequest(ushort requestId)
	{
		enforce(requestId > 0, "Unexpected null request ID");
		return requests.getExpand(requestId - 1);
	}

	/// Create and return a request with the given ID.
	Request newRequest(ushort requestId)
	{
		enforce(requestId > 0, "Unexpected null request ID");
		auto request = createRequest();
		request.id = requestId;
		requests.putExpand(requestId - 1, request);
		return request;
	}

	/// Clear the given request ID.
	void killRequest(ushort requestId)
	{
		enforce(requestId > 0, "Unexpected null request ID");
		requests.putExpand(requestId - 1, null);
	}

	/// Write a raw FastCGI packet.
	final void sendRecord(ref FCGI_RecordHeader header, Data contentData)
	{
		connection.send(Data(header.asBytes));
		connection.send(contentData);
	}

	/// ditto
	final void sendRecord(FCGI_RecordType type, ushort requestId, Data contentData)
	{
		FCGI_RecordHeader header;
		header.version_ = FCGI_VERSION_1;
		header.type = type;
		header.requestId = requestId;
		header.contentLength = contentData.length.to!ushort;
		sendRecord(header, contentData);
	}

	protected override void onRecord(ref FCGI_RecordHeader header, Data contentData)
	{
		switch (header.type)
		{
			case FCGI_RecordType.beginRequest:
			{
				auto beginRequest = contentData.asStruct!FCGI_BeginRequestBody;
				auto request = newRequest(header.requestId);
				request.role = beginRequest.role;
				request.keepConn = !!(beginRequest.flags & FCGI_RequestFlags.keepConn);
				request.begin();
				break;
			}
			case FCGI_RecordType.abortRequest:
			{
				enforce(contentData.length == 0, "Expected no data after FCGI_ABORT_REQUEST");
				auto request = getRequest(header.requestId);
				if (!request)
					return;
				request.abort();
				break;
			}
			case FCGI_RecordType.params:
			{
				auto request = getRequest(header.requestId);
				if (!request)
					return;
				if (contentData.length)
				{
					request.paramBuf ~= contentData;
					auto buf = request.paramBuf;
					while (buf.readNameValue((scope name, scope value) {
						request.param(name, value);
						request.paramBuf = buf;
					})) {}
				}
				else
				{
					enforce(request.paramBuf.length == 0, "Slack data in FCGI_PARAMS");
					request.paramEnd();
				}
				break;
			}
			case FCGI_RecordType.stdin:
			{
				auto request = getRequest(header.requestId);
				if (!request)
					return;
				if (contentData.length)
					request.stdin(contentData);
				else
					request.stdinEnd();
				break;
			}
			case FCGI_RecordType.data:
			{
				auto request = getRequest(header.requestId);
				if (!request)
					return;
				if (contentData.length)
					request.data(contentData);
				else
					request.dataEnd();
				break;
			}
			case FCGI_RecordType.getValues:
			{
				FastAppender!ubyte result;
				while (contentData.length)
				{
					contentData.readNameValue((scope name, scope dummyValue) {
						enforce(dummyValue.length == 0,
							"Present value in FCGI_GET_VALUES");
						auto value = getValue(name);
						if (value)
							result.putNameValue(name, value);
					}).enforce("Incomplete FCGI_GET_VALUES");
				}
				sendRecord(
					FCGI_RecordType.getValuesResult,
					FCGI_NULL_REQUEST_ID,
					Data(result.get),
				);
				break;
			}
			default:
			{
				FCGI_UnknownTypeBody data;
				data.type = header.type;
				sendRecord(
					FCGI_RecordType.unknownType,
					FCGI_NULL_REQUEST_ID,
					Data(data.asBytes),
				);
				break;
			}
		}
	}

	private const(char)[] getValue(const(char)[] name)
	{
		switch (name)
		{
			case FCGI_MAX_CONNS:
				return maxConns.text;
			case FCGI_MAX_REQS:
				return maxReqs.text;
			case FCGI_MPXS_CONNS:
				return int(mpxsConns).text;
			default:
				return null;
		}
	}
}

private T asStruct(T)(Data data)
{
	enforce(data.length == T.sizeof,
		format!"Expected data for %s (%d bytes), but got %d bytes"(
			T.stringof, T.sizeof, data.length,
		));
	return data.asDataOf!T.front;
}

/// Parse a FastCGI-encoded name-value pair.
bool readNameValue(ref Data data, scope void delegate(scope const(char)[] name, scope const(char)[] value) fn)
{
	uint nameLen, valueLen;
	if (!data.readVLInt(nameLen))
		return false;
	if (!data.readVLInt(valueLen))
		return false;
	auto totalLen = nameLen + valueLen;
	if (data.length < totalLen)
		return false;
	data.asDataOf!char.enter((contents) {
		scope name  = contents[0 .. nameLen];
		scope value = contents[nameLen .. totalLen];
		fn(name, value);
	});
	data = data[totalLen .. $];
	return true;
}

/// Parse a FastCGI-encoded variable-length integer.
bool readVLInt(ref Data data, ref uint value)
{
	auto bytes = data.asDataOf!ubyte;
	if (!bytes.length)
		return false;
	if ((bytes[0] & 0x80) == 0)
	{
		value = bytes[0];
		data = data[1..$];
		return true;
	}
	if (bytes.length < 4)
		return false;
	value = ((bytes[0] & 0x7F) << 24) + (bytes[1] << 16) + (bytes[2] << 8) + bytes[3];
	data = data[4..$];
	return true;
}

/// Write a FastCGI-encoded name-value pair.
void putNameValue(W)(ref W writer, const(char)[] name, const(char)[] value)
{
	writer.putVLInt(name.length);
	writer.putVLInt(value.length);
	writer.put(cast(ubyte[])name);
	writer.put(cast(ubyte[])value);
}

/// Write a FastCGI-encoded variable-length integer.
void putVLInt(W)(ref W writer, size_t value)
{
	enforce(value <= 0x7FFFFFFF, "FastCGI integer value overflow");
	if (value < 0x80)
		writer.put(cast(ubyte)value);
	else
		writer.put(
			ubyte((value >> 24) & 0xFF | 0x80),
			ubyte((value >> 16) & 0xFF),
			ubyte((value >>  8) & 0xFF),
			ubyte((value      ) & 0xFF),
		);
}

/// FastCGI server for handling Responder requests.
class FastCGIResponderConnection : FastCGIProtoConnection
{
	///
	this(IConnection connection) { super(connection); }

	protected final class ResponderRequest : Request
	{
		string[string] params;
		DataVec inputData;

		override void begin()
		{
			if (role != FCGI_Role.responder)
				return end(1, FCGI_ProtocolStatus.unknownRole);
		}

		override void param(const(char)[] name, const(char)[] value)
		{
			params[name.idup] = value.idup;
		}

		override void stdin(Data datum)
		{
			inputData ~= datum;
		}

		override void stdinEnd()
		{
			auto request = CGIRequest.fromAA(params);
			request.data = move(inputData);

			try
				this.outer.handleRequest(request, &sendResponse);
			catch (Exception e)
			{
				stderr(Data(e.toString().asBytes));
				stderrEnd();
				end(0, FCGI_ProtocolStatus.requestComplete);
			}
		}

		void sendResponse(HttpResponse r)
		{
			FastAppender!char headers;
			if (this.outer.nph)
				writeNPHHeaders(r, headers);
			else
				writeCGIHeaders(r, headers);
			stdout(Data(headers.get().asBytes));

			foreach (datum; r.data)
				stdout(datum);
			stdoutEnd();
			end(0, FCGI_ProtocolStatus.requestComplete);
		}

		override void data(Data datum) { throw new Exception("Unexpected FCGI_DATA"); }
		override void dataEnd() { throw new Exception("Unexpected FCGI_DATA"); }
	}

	protected override Request createRequest() { return new ResponderRequest; }

	/// User-supplied callback for handling incoming requests.
	void delegate(ref CGIRequest, void delegate(HttpResponse)) handleRequest;

	/// Whether to operate in Non-Parsed Headers mode.
	bool nph;
}

/// ditto
class FastCGIResponderServer : FastCGIAppSocketServer
{
	/// Whether to operate in Non-Parsed Headers mode.
	bool nph;

	/// User-supplied callback for handling incoming requests.
	void delegate(ref CGIRequest, void delegate(HttpResponse)) handleRequest;

	protected override void createConnection(IConnection connection)
	{
		auto fconn = new FastCGIResponderConnection(connection);
		fconn.log = this.log;
		fconn.nph = this.nph;
		fconn.handleRequest = this.handleRequest;
	}
}

unittest
{
	new FastCGIResponderServer;
}
