/**
 * PostgreSQL protocol implementation.
 * !!! UNFINISHED !!!
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

module ae.net.db.psql;

import std.array;
import std.exception;
import std.string;

import std.bitmanip : nativeToBigEndian, bigEndianToNative;

import ae.net.asockets;
import ae.utils.array;
import ae.utils.exception;

class PgSqlConnection
{
public:
	this(IConnection conn, string user, string database)
	{
		this.conn = conn;
		this.user = user;
		this.database = database;

		conn.handleConnect = &onConnect;
		conn.handleReadData = &onReadData;
	}

	struct ErrorResponse
	{
		struct Field
		{
			char type;
			char[] str;

			string toString() { return "%s=%s".format(type, str); }
		}
		Field[] fields;

		string toString()
		{
			return "%-(%s;%)".format(fields);
		}
	}

	enum TransactionStatus : char
	{
		idle = 'I',
		inTransaction = 'T',
		failed = 'E',
	}

	struct FieldDescription
	{
		char[] name;
		uint tableID;
		uint type;
		short size;
		uint modifier;
		ushort formatCode;
	}

	void delegate(ErrorResponse response) handleError;
	void delegate() handleAuthenticated;
	void delegate(char[] name, char[] value) handleParameterStatus;
	void delegate(TransactionStatus transactionStatus) handleReadyForQuery;

	string applicationName = "ae.net.db.psql";

private:
	IConnection conn;

	string user;
	string database;

	enum ushort protocolVersionMajor = 3;
	enum ushort protocolVersionMinor = 0;

	enum PacketType : char
	{
		authenticationRequest = 'R',
		backendKeyData = 'K',
		errorResponse = 'E',
		parameterStatus = 'S',
		readyForQuery = 'Z',
		rowDescription = 'T',
	}

	static T readInt(T)(ref Data data)
	{
		enforce!PgSqlException(data.length >= T.sizeof, "Not enough data in packet");
		T result = bigEndianToNative!T(cast(ubyte[T.sizeof])data.contents[0..T.sizeof]);
		data = data[T.sizeof..$];
		return result;
	}

	static char readChar(ref Data data)
	{
		return cast(char)readInt!ubyte(data);
	}

	static char[] readString(ref Data data)
	{
		char[] s = cast(char[])data.contents;
		auto p = s.indexOf('\0');
		enforce!PgSqlException(p >= 0, "Unterminated string in packet packet");
		char[] result = s[0..p];
		data = data[p+1..$];
		return result;
	}

	void onConnect()
	{
		sendStartupMessage();
	}

	Data packetBuf;

	void onReadData(Data data)
	{
		packetBuf ~= data;
		while (packetBuf.length >= 5)
		{
			auto length = { Data temp = packetBuf[1..5]; return readInt!uint(temp); }();
			if (packetBuf.length >= 1 + length)
			{
				auto packetData = packetBuf[0 .. 1 + length];
				packetBuf = packetBuf[1 + length .. $];
				if (!packetBuf.length)
					packetBuf = Data.init;

				auto packetType = cast(PacketType)readChar(packetData);
				packetData = packetData[4..$]; // Skip length
				processPacket(packetType, packetData);
			}
		}
	}

	void processPacket(PacketType type, Data data)
	{
		switch (type)
		{
			case PacketType.authenticationRequest:
			{
				auto result = readInt!uint(data);
				enforce!PgSqlException(result == 0, "Authentication failed");
				if (handleAuthenticated)
					handleAuthenticated();
				break;
			}
			case PacketType.backendKeyData:
			{
				// TODO?
				break;
			}
			case PacketType.errorResponse:
			{
				ErrorResponse response;
				while (data.length)
				{
					auto fieldType = readChar(data);
					if (!fieldType)
						break;
					response.fields ~= ErrorResponse.Field(fieldType, readString(data));
				}
				if (handleError)
					handleError(response);
				else
					throw new PgSqlException(response.toString());
				break;
			}
			case PacketType.parameterStatus:
				if (handleParameterStatus)
				{
					char[] name = readString(data);
					char[] value = readString(data);
					handleParameterStatus(name, value);
				}
				break;
			case PacketType.readyForQuery:
				if (handleReadyForQuery)
					handleReadyForQuery(cast(TransactionStatus)readChar(data));
				break;
			case PacketType.rowDescription:
			{
				auto fieldCount = readInt!ushort(data);
				auto fields = new FieldDescription[fieldCount];
				foreach (n; 0..fieldCount)
				{
				}
				break;
			}
			default:
				throw new Exception("Unknown packet type '%s'".format(char(type)));
		}
	}

	static void write(T)(ref Appender!(ubyte[]) buf, T value)
	{
		static if (is(T : long))
		{
			buf.put(nativeToBigEndian(value)[]);
		}
		else
		static if (is(T : const(char)[]))
		{
			buf.put(cast(const(ubyte)[])value);
			buf.put(ubyte(0));
		}
		else
			static assert(false, "Can't write " ~ T.stringof);
	}

	void sendStartupMessage()
	{
		auto buf = appender!(ubyte[]);

		write(buf, protocolVersionMajor);
		write(buf, protocolVersionMinor);

		write(buf, "user");
		write(buf, user);

		write(buf, "database");
		write(buf, database);

		write(buf, "application_name");
		write(buf, applicationName);

		write(buf, "client_encoding");
		write(buf, "UTF8");

		write(buf, "");

		conn.send(Data(nativeToBigEndian(cast(uint)(buf.data.length + uint.sizeof))[]));
		conn.send(Data(buf.data));
	}

	void sendPacket(char type, const(void)[] data)
	{
		conn.send(Data(type.toArray));
		conn.send(Data(nativeToBigEndian(cast(uint)(data.length + uint.sizeof))[]));
		conn.send(Data(data));
	}
	
	void sendQuery(const(char)[] query)
	{
		auto buf = appender!(ubyte[]);
		write(buf, query);
		sendPacket('Q', buf.data);
	}
}

mixin DeclareException!q{PgSqlException};

version (HAVE_PSQL_SERVER)
unittest
{
	import std.process : environment;

	auto conn = new TcpConnection();
	auto pg = new PgSqlConnection(conn, environment["USER"], environment["USER"]);
	conn.connect("localhost", 5432);
	pg.handleReadyForQuery = (PgSqlConnection.TransactionStatus ts) {
		pg.handleReadyForQuery = null;
		pg.sendQuery("SELECT 2+2;");
	};
	socketManager.loop();
}
