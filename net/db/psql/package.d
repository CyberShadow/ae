/**
 * PostgreSQL protocol implementation.
 *
 * Implements the PostgreSQL wire protocol (version 3.0) for asynchronous
 * database access integrated with the ae event loop.
 *
 * ---
 * auto pg = connect("postgresql://user:password@localhost/mydb").await;
 * scope(exit) pg.close();
 * foreach (row; pg.query("SELECT id, name FROM users WHERE id = $1", 42))
 *     writeln(row.column!string("name"));
 * ---
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

module ae.net.db.psql;

import std.array;
import std.conv;
import std.exception;
import std.process : environment;
import std.string;
import std.typecons : Nullable;

import std.bitmanip : nativeToBigEndian, bigEndianToNative;
import std.digest.md : md5Of, toHexString, LetterCase;

import ae.net.asockets;
import ae.net.ssl : ssl, sslAvailable, SSLContext, SSLAdapter;
import ae.utils.auth.scram : ScramSHA256Client;
import ae.utils.promise;

public import ae.net.db.common : DbException, Param, toParams;
static import ae.net.db.common;

// https://issues.dlang.org/show_bug.cgi?id=7016
// `await`/`async` are imported only inside method bodies below, which `rdmd`
// does not detect as a dependency, breaking rdmd-built projects with a link
// error. Force the dependency with a module-level import.
static import ae.utils.promise.await;

// TODO: Direct SSL negotiation (PostgreSQL 17+ `sslnegotiation=direct`; needs ALPN)
// TODO: COPY protocol for bulk data import/export
// TODO: LISTEN/NOTIFY for async notifications
// TODO: Large Object support
// TODO: Connection pooling
// TODO: Unix socket support (currently only TCP; PGHOST must be a hostname, not a socket path)

/// TLS negotiation mode.
enum SSLMode
{
	/// Never use TLS.
	disable,
	/// Use TLS if the server supports it, otherwise fall back to an
	/// unencrypted connection. Offers no protection against an
	/// active attacker.
	/// If no SSL provider (such as `ae.net.ssl.openssl`) is linked
	/// in, TLS is not attempted (like libpq built without SSL).
	prefer,
	/// Require TLS; fail if the server does not support it, or if
	/// no SSL provider is linked in.
	/// Whether the server certificate is verified is determined
	/// by the `SSLContext` (see `SSLContext.setPeerVerify`).
	require,
}

/// Connect to the PostgreSQL server at `host`:`port`, as `user`, to
/// `database`; the promise is fulfilled with the connection once it is
/// ready for queries.
/// Params:
///   host = server host name; also used for SNI and certificate
///     host name verification when using TLS
///   port = server port
///   user = PostgreSQL user name
///   database = database name to connect to
///   password = optional password for authentication
///   sslMode = whether to negotiate TLS (via SSLRequest);
///     defaults to `prefer`, like libpq
///   sslContext = client SSL context to use for TLS; if `null`,
///     a default context is created with the global `ssl` provider
///     (which does not verify the server certificate)
Promise!PgSqlConnection connect(string host, ushort port, string user, string database, string password = null,
	SSLMode sslMode = SSLMode.prefer, SSLContext sslContext = null)
{
	auto tcp = new TcpConnection;
	auto pg = new PgSqlConnection(tcp, user, database, password, sslMode, sslContext, host);
	tcp.connect(host, port);
	return pg.readyPromise;
}

/// ditto, of the URI `uri`
/// (`postgresql://user:password@host:port/database?sslmode=...&sslrootcert=...`,
/// all but the host optional; the user and database default as for
/// `connect()`, and the `sslmode` and `sslrootcert` parameters as the
/// PGSSLMODE and PGSSLROOTCERT environment variables do; other parameters
/// are not supported).
Promise!PgSqlConnection connect(string uri)
{
	import ae.net.db.common : DbUri;
	try
	{
		auto u = DbUri.parse(uri, ["postgresql", "postgres"]);
		foreach (name, value; u.parameters)
			enforce!PgSqlException(name == "sslmode" || name == "sslrootcert",
				"Unsupported connection URI parameter: " ~ name);
		auto sslSettings = SSLSettings.parse(u.parameters.get("sslmode", "prefer"), u.parameters.get("sslrootcert", null));
		auto user = u.user.length ? u.user : defaultUser;
		return connect(u.host.length ? u.host : "localhost", u.port.isNull ? 5432 : u.port.get,
			user, u.database.length ? u.database : user, u.password, sslSettings.mode, sslSettings.context);
	}
	catch (Exception e)
		return rejected!PgSqlConnection(e);
}

/// ditto, of the standard PostgreSQL environment variables:
///   PGHOST - server hostname (default: localhost)
///   PGPORT - server port (default: 5432)
///   PGUSER - username (default: the current OS user)
///   PGDATABASE - database name (default: the user's)
///   PGPASSWORD - password (default: none)
///   PGSSLMODE - `disable`, `prefer` (default), `require` or `verify-full`
///     (see `SSLMode`; `verify-full` uses `SSLMode.require` with a
///     context which verifies the server certificate and host name)
///   PGSSLROOTCERT - with `verify-full`, the root certificate file to
///     verify the server certificate against (default: system store)
Promise!PgSqlConnection connect()
{
	try
	{
		auto sslSettings = SSLSettings.parse(environment.get("PGSSLMODE", "prefer"), environment.get("PGSSLROOTCERT"));
		return connect(
			environment.get("PGHOST", "localhost"),
			environment.get("PGPORT", "5432").to!ushort,
			defaultUser,
			environment.get("PGDATABASE", defaultUser),
			environment.get("PGPASSWORD"),
			sslSettings.mode,
			sslSettings.context);
	}
	catch (Exception e)
		return rejected!PgSqlConnection(e);
}

/// ditto, over the transport `transport`, which the caller then connects:
/// the connection sends its startup message (or SSLRequest) when the
/// transport connects.
/// Params:
///   sslMode = whether to negotiate TLS (via SSLRequest) over `transport`;
///     defaults to `disable`, as the transport may not need it
///     (e.g. a Unix domain socket)
///   sslContext = client SSL context (see above)
///   sslHostName = host name to indicate via SNI and to verify the
///     server certificate against
Promise!PgSqlConnection connect(IConnection transport, string user, string database, string password = null,
	SSLMode sslMode = SSLMode.disable, SSLContext sslContext = null, string sslHostName = null)
{
	return new PgSqlConnection(transport, user, database, password, sslMode, sslContext, sslHostName).readyPromise;
}

/// The TLS settings of a libpq `sslmode` (`disable`, `prefer`, `require`
/// or `verify-full`, see `connect()`) and `sslrootcert`.
private struct SSLSettings
{
	SSLMode mode;
	SSLContext context;

	static SSLSettings parse(string mode, string rootCert)
	{
		SSLSettings result;
		switch (mode)
		{
			case "disable":
				result.mode = SSLMode.disable;
				break;
			case "prefer":
				result.mode = SSLMode.prefer;
				break;
			case "require":
				result.mode = SSLMode.require;
				break;
			case "verify-full":
				result.mode = SSLMode.require;
				enforce!PgSqlException(sslAvailable, "sslmode=verify-full: " ~ noSSLProviderMessage);
				result.context = ssl.createContext(SSLContext.Kind.client);
				result.context.setPeerVerify(SSLContext.Verify.require);
				if (rootCert)
					result.context.setPeerRootCertificate(rootCert);
				break;
			default:
				throw new PgSqlException("Unsupported sslmode: " ~ mode);
		}
		return result;
	}
}

private enum noSSLProviderMessage = "TLS requires an SSL provider, but none is linked in (import e.g. ae.net.ssl.openssl)";

private @property string defaultUser()
{
	return environment.get("PGUSER", environment.get("USER", "postgres"));
}

private Promise!T rejected(T)(Exception e)
{
	auto p = new Promise!T;
	p.reject(e);
	return p;
}

/// The fields of an error or notice message of the server.
struct PgSqlMessage
{
	struct Field
	{
		char type;
		const(char)[] str;

		string toString() const { return "%s=%s".format(type, str); }
	}
	Field[] fields;

	string toString() const
	{
		return "%-(%s;%)".format(fields);
	}

	/// Get a specific field by type code.
	/// Common codes: 'S'=severity, 'C'=SQLSTATE, 'M'=message, 'D'=detail, 'H'=hint
	const(char)[] getField(char type) const
	{
		foreach (field; fields)
			if (field.type == type)
				return field.str;
		return null;
	}

	@property const(char)[] severity() const { return getField('S'); }
	@property const(char)[] sqlState() const { return getField('C'); }
	@property const(char)[] message() const { return getField('M'); }
	@property const(char)[] detail() const { return getField('D'); }
	@property const(char)[] hint() const { return getField('H'); }
}

/// Transaction status indicator from ReadyForQuery.
enum TransactionStatus : char
{
	idle = 'I',
	inTransaction = 'T',
	failed = 'E',
}

/// Common PostgreSQL type OIDs.
enum PgOid : uint
{
	unknown = 0,  /// (a parameter's: inferred by the server from its context)
	boolean = 16,
	bytea = 17,
	char_ = 18,
	int8 = 20,
	int2 = 21,
	int4 = 23,
	text = 25,
	oid = 26,
	float4 = 700,
	float8 = 701,
	varchar = 1043,
	date = 1082,
	time = 1083,
	timestamp = 1114,
	timestamptz = 1184,
	numeric = 1700,
	uuid = 2950,
	json = 114,
	jsonb = 3802,
}

/// A row of a result (its values as PostgreSQL's text format has them;
/// `bytea` values as byte arrays, see `decodeBytea`).
alias Row = ae.net.db.common.Row!decodeBytea;

/// The lazy result of a query (see `ae.net.db.common.Result`). Its
/// `affectedRows` is the count of the command tag of the (last)
/// statement.
alias Result = ae.net.db.common.Result!Row;

/// A statement prepared on the server (see `PgSqlConnection.prepare`),
/// executed with parameters (sent in text format, of the types the server
/// inferred for them when it prepared the statement).
final class PreparedStatement
{
	/// Execute the statement with the parameters `args` (see `Param.of`),
	/// or `params`.
	Result query(Args...)(Args args)
	{
		return query(toParams(args));
	}

	/// ditto
	Result query(const(Param)[] params)
	{
		enforce!PgSqlException(!closed, "PreparedStatement has been closed");
		return new Result((Result result) => pg.startQuery(result, null, params, false, this));
	}

	/// Close the statement, freeing its server resources.
	Promise!void close()
	{
		enforce!PgSqlException(!closed, "PreparedStatement already closed");
		closed = true;
		return pg.closeStatement(this);
	}

private:
	PgSqlConnection pg;
	const(char)[] name;
	const(string)[] columnNames;
	bool closed;

	this(PgSqlConnection pg, const(char)[] name)
	{
		this.pg = pg;
		this.name = name;
	}
}

/// A connection to a PostgreSQL server (see `connect`). Its queries are
/// pipelined: each is sent when its result is consumed, and their results
/// arrive in the order they were sent.
final class PgSqlConnection
{
public:
	/// A query of the SQL `sql` (several statements, separated by
	/// semicolons, are allowed; their rows are concatenated), sent with
	/// the Simple Query protocol.
	Result query(const(char)[] sql)
	{
		return new Result((Result result) => startQuery(result, sql, null, true, null));
	}

	/// A query of the statement `sql` with the parameters `args` (see
	/// `Param.of`), or `params`: sent with the Extended Query protocol
	/// (Parse, Bind, Describe, Execute and Sync in one round trip, of the
	/// unnamed statement), the parameters typed in the Parse message:
	///   a boolean as `boolean`; an integer as `integer` (or `bigint`
	///   beyond its range); a floating-point number as `double precision`;
	///   an exact number as `numeric`; a byte array as `bytea`; a string,
	///   NULL and an array as `unknown`, which the server infers from the
	///   parameter's context (as it does for a string literal, e.g. a date
	///   or an enum label).
	Result query(Args...)(const(char)[] sql, Args args)
	{
		return query(sql, toParams(args));
	}

	/// ditto
	Result query(const(char)[] sql, const(Param)[] params)
	{
		return new Result((Result result) => startQuery(result, sql, params, false, null));
	}

	/// Prepare the statement `sql` on the server (as a named statement),
	/// for executing it several times (see `PreparedStatement`).
	Promise!PreparedStatement prepare(const(char)[] sql)
	{
		auto promise = new Promise!PreparedStatement;
		auto stmt = new PreparedStatement(this, "_ps" ~ (statementCounter++).to!string);
		PendingOp op;
		op.type = PendingOpType.prepare;
		op.stmt = stmt;
		op.preparePromise = promise;
		pendingOps ~= op;
		sendParse(stmt.name, sql, null);
		sendDescribe('S', stmt.name);
		sendSync();
		return promise;
	}

	/// Close the connection (the queries sent are answered first); the
	/// promise is fulfilled once it is closed.
	Promise!void close()
	{
		if (closePromise is null)
		{
			closePromise = new Promise!void;
			if (conn.state == ConnectionState.connected)
			{
				sendPacket('X', null);  // Terminate
				conn.disconnect("Client close");
			}
			else if (conn.state == ConnectionState.disconnected)
				closePromise.fulfill();
			else
				conn.disconnect("Client close");
		}
		return closePromise;
	}

	/// The transaction status of the connection (as of the last completed
	/// query).
	@property TransactionStatus transactionStatus() const { return currentTransactionStatus; }

	/// Called with the notices (e.g. warnings) the server sends.
	void delegate(PgSqlMessage notice) handleNotice;

	/// Whether the connection is encrypted with TLS.
	/// Becomes `true` once the TLS handshake has completed.
	@property bool encrypted() { return sslAdapter !is null && sslAdapter.state == ConnectionState.connected; }

	/// The TLS adapter, once TLS has been negotiated (e.g. to inspect
	/// the server certificate). `null` otherwise.
	@property SSLAdapter sslConnection() { return sslAdapter; }

private:
	IConnection conn;

	/// TLS state
	SSLMode sslMode;
	SSLContext sslContext;
	string sslHostName;
	SSLAdapter sslAdapter;
	bool awaitingSSLResponse;

	string user;
	string database;
	string password;

	enum applicationName = "ae.net.db.psql";

	/// SCRAM authentication state (only used during auth handshake)
	ScramSHA256Client scramClient;

	/// Fulfilled with the connection when it is first ready for queries
	Promise!PgSqlConnection readyPromise;
	bool isReady;
	TransactionStatus currentTransactionStatus;

	Promise!void closePromise;

	/// Pending operation types
	enum PendingOpType { query, prepare, close }

	/// A pending operation waiting for server response
	struct PendingOp
	{
		PendingOpType type;
		// For query
		Result result;
		// For prepare
		PreparedStatement stmt;
		Promise!PreparedStatement preparePromise;
		// For close
		Promise!void closePromise;
		// Set when ErrorResponse received, prevents double completion
		bool hadError;
	}

	/// Queue of pending operations (FIFO - PostgreSQL processes in order)
	PendingOp[] pendingOps;

	/// Counter for generating unique statement names
	uint statementCounter;

	this(IConnection conn, string user, string database, string password,
		SSLMode sslMode, SSLContext sslContext, string sslHostName)
	{
		this.conn = conn;
		this.user = user;
		this.database = database;
		this.password = password;
		this.sslMode = sslMode;
		this.sslContext = sslContext;
		this.sslHostName = sslHostName;
		this.readyPromise = new Promise!PgSqlConnection;

		conn.handleConnect = &onConnect;
		conn.handleReadData = &onReadData;
		conn.handleDisconnect = &onDisconnect;
	}

	/// Get the current operation being processed (head of queue)
	@property PendingOp* currentOp()
	{
		return pendingOps.length > 0 ? &pendingOps[0] : null;
	}

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
		dataRow = 'D',
		commandComplete = 'C',
		emptyQueryResponse = 'I',
		noticeResponse = 'N',
		// Extended query protocol
		parseComplete = '1',
		bindComplete = '2',
		closeComplete = '3',
		noData = 'n',
		parameterDescription = 't',
		portalSuspended = 's',
	}

	static T readInt(T)(ref Data data)
	{
		enforce!PgSqlException(data.length >= T.sizeof, "Not enough data in packet");
		return data.pop!(ubyte[T.sizeof]).bigEndianToNative!T();
	}

	static char readChar(ref Data data)
	{
		return cast(char)readInt!ubyte(data);
	}

	static const(char)[] readString(ref Data data)
	{
		const(char)[] result;
		data.asDataOf!char.enter((scope s) {
			auto p = s.indexOf('\0');
			enforce!PgSqlException(p >= 0, "Unterminated string in packet");
			result = s[0..p].dup;
			data = data[p+1..$];
		});
		return result;
	}

	static const(char)[] readBytes(ref Data data, int length)
	{
		enforce!PgSqlException(data.length >= length, "Not enough data in packet");
		const(char)[] result;
		data.asDataOf!char.enter((scope s) {
			result = s[0..length].dup;
		});
		data = data[length..$];
		return result;
	}

	void onConnect()
	{
		final switch (sslMode)
		{
			case SSLMode.disable:
				return sendStartupMessage();
			case SSLMode.prefer:
				if (!sslAvailable)
					return sendStartupMessage();
				return sendSSLRequest();
			case SSLMode.require:
				if (!sslAvailable)
					return conn.disconnect(noSSLProviderMessage, DisconnectType.error);
				return sendSSLRequest();
		}
	}

	enum uint sslRequestCode = 80877103; // (1234 << 16) | 5679

	void sendSSLRequest()
	{
		ubyte[8] packet;
		packet[0 .. 4] = nativeToBigEndian(cast(uint)packet.length);
		packet[4 .. 8] = nativeToBigEndian(sslRequestCode);
		awaitingSSLResponse = true;
		conn.send(Data(packet[]));
	}

	/// Handle the server's single-byte response to SSLRequest.
	void onSSLResponse(Data data)
	{
		if (!data.length)
			return;
		awaitingSSLResponse = false;

		auto response = readChar(data);
		switch (response)
		{
			case 'S':
				// Any data following the 'S' was sent before the TLS
				// handshake, so it is not protected by it, and may have
				// been injected by an attacker (CVE-2021-23222).
				if (data.length)
					return conn.disconnect("Received unencrypted data after SSL response", DisconnectType.error);

				auto transport = conn;
				try
				{
					if (!sslContext)
						sslContext = ssl.createContext(SSLContext.Kind.client);
					ssl.startTLS(sslContext, transport, sslHostName, (SSLAdapter adapter) {
						sslAdapter = adapter;
						conn = adapter;
						adapter.handleConnect = &sendStartupMessage;
						adapter.handleReadData = &onReadData;
						adapter.handleDisconnect = &onDisconnect;
					});
				}
				catch (Exception e)
				{
					if (conn is transport)
						transport.handleDisconnect = &onDisconnect; // reclaim from any partially constructed adapter chain
					if (conn.state.disconnectable)
						conn.disconnect("TLS setup failed: " ~ e.msg, DisconnectType.error);
				}
				return;

			case 'N':
				if (sslMode == SSLMode.require)
					return conn.disconnect("Server does not support SSL, but SSL was required", DisconnectType.error);
				sendStartupMessage();
				if (data.length)
					onReadData(data);
				return;

			default:
				// Servers which predate SSL support respond with an ErrorResponse.
				return conn.disconnect("Unexpected response to SSL request: " ~ format("%(%s%)", [response]),
					DisconnectType.error);
		}
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		// Fail all pending operations
		auto err = new PgSqlException("Connection lost: " ~ reason);

		if (!isReady)
		{
			isReady = true;  // (no longer pending)
			readyPromise.reject(err);
		}

		foreach (ref op; pendingOps)
		{
			final switch (op.type)
			{
				case PendingOpType.query:
					op.result.onError(err);
					break;
				case PendingOpType.prepare:
					op.preparePromise.reject(err);
					break;
				case PendingOpType.close:
					op.closePromise.reject(err);
					break;
			}
		}
		pendingOps = null;

		if (closePromise is null)
			closePromise = new Promise!void;
		closePromise.fulfill();
	}

	Data packetBuf;

	void onReadData(Data data)
	{
		if (awaitingSSLResponse)
			return onSSLResponse(data);

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
				try
					processPacket(packetType, packetData);
				catch (Exception e)
				{
					// (A protocol or authentication failure: fatal)
					if (!isReady)
					{
						isReady = true;
						readyPromise.reject(e);
					}
					conn.disconnect(e.msg);
					return;
				}
			}
			else
				break;
		}
	}

	void processPacket(PacketType type, Data data)
	{
		debug (PSQL_TRACE) { import std.stdio : stderr; stderr.writefln("psql: packet '%s' (queue=%d)", cast(char)type, pendingOps.length); }
		switch (type)
		{
			case PacketType.authenticationRequest:
				processAuthRequest(data);
				break;

			case PacketType.backendKeyData:
				// Process ID and secret key for cancel requests
				// Currently ignored
				break;

			case PacketType.errorResponse:
			{
				auto err = new PgSqlException(parseMessage(data));

				if (currentOp)
				{
					currentOp.hadError = true;
					final switch (currentOp.type)
					{
						case PendingOpType.query:
							currentOp.result.onError(err);
							break;
						case PendingOpType.prepare:
							currentOp.preparePromise.reject(err);
							break;
						case PendingOpType.close:
							currentOp.closePromise.reject(err);
							break;
					}
					// Don't pop here - wait for ReadyForQuery
				}
				else if (!isReady)
				{
					// Error during connection setup (e.g. authentication)
					isReady = true;
					readyPromise.reject(err);
					conn.disconnect(err.msg);
				}
				else
					// An error of no query (e.g. the server shutting down
					// the connection): fatal
					conn.disconnect(err.msg);
				break;
			}

			case PacketType.noticeResponse:
			{
				auto notice = parseMessage(data);
				if (handleNotice)
					handleNotice(notice);
				break;
			}

			case PacketType.parameterStatus:
				// Run-time parameters of the server (e.g. server_version)
				// Currently ignored
				break;

			case PacketType.readyForQuery:
			{
				auto status = cast(TransactionStatus)readChar(data);
				currentTransactionStatus = status;

				// First ReadyForQuery means connection is ready
				if (!isReady)
				{
					isReady = true;
					readyPromise.fulfill(this);
				}

				if (currentOp)
				{
					// Only complete successfully if no error occurred
					// (errors are already handled in ErrorResponse)
					if (!currentOp.hadError)
					{
						final switch (currentOp.type)
						{
							case PendingOpType.query:
								currentOp.result.onComplete();
								break;
							case PendingOpType.prepare:
								currentOp.preparePromise.fulfill(currentOp.stmt);
								break;
							case PendingOpType.close:
								currentOp.closePromise.fulfill();
								break;
						}
					}
					// Pop completed operation from queue
					pendingOps = pendingOps[1..$];
				}
				break;
			}

			case PacketType.rowDescription:
			{
				auto fieldCount = readInt!ushort(data);
				auto names = new string[fieldCount];
				foreach (i; 0..fieldCount)
				{
					names[i] = readString(data).idup;
					readInt!uint(data);   // table OID
					readInt!ushort(data); // column attribute number
					readInt!uint(data);   // type OID
					readInt!short(data);  // type size
					readInt!int(data);    // type modifier
					readInt!ushort(data); // format code
				}
				if (currentOp)
				{
					if (currentOp.type == PendingOpType.prepare)
						currentOp.stmt.columnNames = names;
					else if (currentOp.type == PendingOpType.query)
						currentOp.result.onColumns(names);
				}
				break;
			}

			case PacketType.dataRow:
			{
				auto columnCount = readInt!ushort(data);
				auto values = new const(char)[][columnCount];
				auto nulls = new bool[columnCount];
				foreach (i; 0..columnCount)
				{
					auto length = readInt!int(data);
					if (length == -1)
					{
						nulls[i] = true;
						values[i] = null;
					}
					else
					{
						nulls[i] = false;
						values[i] = readBytes(data, length);
					}
				}
				if (currentOp && currentOp.type == PendingOpType.query)
					currentOp.result.onRow(values, nulls);
				break;
			}

			case PacketType.commandComplete:
			{
				// The command tag, e.g. "INSERT 0 3", "UPDATE 2", "SELECT 5":
				// its last word, if a number, is the count of rows
				auto tag = readString(data);
				if (currentOp && currentOp.type == PendingOpType.query)
				{
					auto words = tag.split(' ');
					ulong count;
					if (words.length > 1 && words[$-1].length && words[$-1].isNumeric)
						count = words[$-1].to!ulong;
					currentOp.result.onAffected(count);
				}
				break;
			}

			case PacketType.emptyQueryResponse:
				// Empty query string was sent
				break;

			// Extended Query protocol responses
			case PacketType.parseComplete:
			case PacketType.bindComplete:
			case PacketType.closeComplete:
				break;

			case PacketType.noData:
				// Statement returns no rows (e.g., INSERT/UPDATE/DELETE)
				if (currentOp && currentOp.type == PendingOpType.prepare)
					currentOp.stmt.columnNames = null;
				break;

			case PacketType.parameterDescription:
				// (The types of a prepared statement's parameters, which its
				// parameters' text the server converts to)
				break;

			default:
				conn.disconnect("Unknown packet type '%s' (0x%02X)".format(cast(char)type, cast(ubyte)type));
		}
	}

	PgSqlMessage parseMessage(ref Data data)
	{
		PgSqlMessage message;
		while (data.length)
		{
			auto fieldType = readChar(data);
			if (!fieldType)
				break;
			message.fields ~= PgSqlMessage.Field(fieldType, readString(data));
		}
		return message;
	}

	void processAuthRequest(ref Data data)
	{
		auto authType = readInt!uint(data);
		switch (authType)
		{
			case 0: // AuthenticationOk
				break;

			case 3: // AuthenticationCleartextPassword
				enforce!PgSqlException(password !is null, "Password required but not provided");
				sendPasswordMessage(password);
				break;

			case 5: // AuthenticationMD5Password
				enforce!PgSqlException(password !is null, "Password required but not provided");
				enforce!PgSqlException(data.length >= 4, "Missing salt in MD5 auth request");
				ubyte[4] salt;
				data.enter((scope bytes) {
					salt[] = bytes[0..4];
				});
				sendMD5PasswordMessage(user, password, salt);
				break;

			case 10: // AuthenticationSASL
				enforce!PgSqlException(password !is null, "Password required but not provided");
				processSASLInit(data);
				break;

			case 11: // AuthenticationSASLContinue
				processSASLContinue(data);
				break;

			case 12: // AuthenticationSASLFinal
				processSASLFinal(data);
				break;

			default:
				throw new PgSqlException("Unsupported authentication method: " ~ authType.to!string);
		}
	}

	void processSASLInit(ref Data data)
	{
		// Parse list of supported mechanisms (null-terminated strings, ending with empty string)
		bool scramSha256Supported = false;
		while (data.length > 0)
		{
			auto mechanism = readString(data);
			if (mechanism.length == 0)
				break;
			if (mechanism == "SCRAM-SHA-256")
				scramSha256Supported = true;
		}

		enforce!PgSqlException(scramSha256Supported, "Server doesn't support SCRAM-SHA-256");

		// Initialize SCRAM client and send first message
		scramClient = ScramSHA256Client(user, password);
		auto clientFirst = scramClient.clientFirstMessage();

		sendSASLInitialResponse("SCRAM-SHA-256", clientFirst);
	}

	void processSASLContinue(ref Data data)
	{
		// Get server-first-message
		const(char)[] serverFirst;
		data.asDataOf!char.enter((scope s) {
			serverFirst = s.idup;
		});

		// Generate and send client-final-message
		auto clientFinal = scramClient.clientFinalMessage(cast(string) serverFirst);
		sendSASLResponse(clientFinal);
	}

	void processSASLFinal(ref Data data)
	{
		// Get server-final-message and verify
		const(char)[] serverFinal;
		data.asDataOf!char.enter((scope s) {
			serverFinal = s.idup;
		});

		enforce!PgSqlException(
			scramClient.verifyServerFinal(cast(string) serverFinal),
			"SCRAM server signature verification failed");

		// Clear SCRAM state
		scramClient = ScramSHA256Client.init;
	}

	void sendSASLInitialResponse(const(char)[] mechanism, const(char)[] response)
	{
		auto buf = appender!(ubyte[]);
		write(buf, mechanism);
		write(buf, cast(int) response.length);
		buf.put(cast(const(ubyte)[]) response);
		sendPacket('p', buf.data);
	}

	void sendSASLResponse(const(char)[] response)
	{
		sendPacket('p', cast(const(ubyte)[]) response);
	}

	void sendPasswordMessage(string pwd)
	{
		auto buf = appender!(ubyte[]);
		write(buf, pwd);
		sendPacket('p', buf.data);
	}

	void sendMD5PasswordMessage(string usr, string pwd, ubyte[4] salt)
	{
		// PostgreSQL MD5 auth: "md5" + md5(md5(password + username) + salt)
		auto inner = md5Of(pwd, usr);
		auto innerHex = inner.toHexString!(LetterCase.lower);
		auto outer = md5Of(innerHex[], salt[]);
		auto outerHex = outer.toHexString!(LetterCase.lower);

		auto buf = appender!(ubyte[]);
		write(buf, "md5" ~ outerHex[]);
		sendPacket('p', buf.data);
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

		// Coalesce the packet into one send, so that it forms a single
		// TLS record when the transport is an SSL adapter.
		auto packet = Data(uint.sizeof + buf.data.length);
		packet.enter((scope contents) {
			contents[0 .. 4] = nativeToBigEndian(cast(uint)(buf.data.length + uint.sizeof));
			contents[4 .. $] = buf.data[];
		});
		conn.send(packet);
	}

	void sendPacket(char type, const(ubyte)[] data)
	{
		// Coalesce the packet into one send, so that it forms a single
		// TLS record when the transport is an SSL adapter.
		auto packet = Data(1 + uint.sizeof + data.length);
		packet.enter((scope contents) {
			contents[0] = cast(ubyte)type;
			contents[1 .. 5] = nativeToBigEndian(cast(uint)(data.length + uint.sizeof));
			contents[5 .. $] = data[];
		});
		conn.send(packet);
	}

	void startQuery(Result result, const(char)[] sql, const(Param)[] params, bool simple, PreparedStatement stmt)
	{
		pendingOps ~= PendingOp(PendingOpType.query, result);

		if (stmt !is null)
		{
			// A prepared statement: Bind + Execute + Sync (its columns
			// were described when it was prepared)
			result.onColumns(stmt.columnNames);
			sendBind("", stmt.name, params);
			sendExecute("");
			sendSync();
		}
		else if (!simple)
		{
			// Extended Query protocol with the unnamed statement, in a
			// single round-trip
			sendParse("", sql, params);
			sendBind("", "", params);
			sendDescribe('P', "");
			sendExecute("");
			sendSync();
		}
		else
		{
			// Simple Query protocol
			auto buf = appender!(ubyte[]);
			write(buf, sql);
			sendPacket('Q', buf.data);
		}
	}

	/// Send Parse message (Extended Query protocol), with the types of the
	/// parameters `params` (if not null)
	void sendParse(const(char)[] stmtName, const(char)[] sql, const(Param)[] params)
	{
		auto buf = appender!(ubyte[]);
		write(buf, stmtName);           // Statement name
		write(buf, sql);                // Query string
		write(buf, cast(ushort)params.length);  // Number of parameter types
		foreach (ref param; params)
			write(buf, cast(uint)parameterType(param));
		sendPacket('P', buf.data);
	}

	/// Send Bind message (Extended Query protocol)
	void sendBind(const(char)[] portalName, const(char)[] stmtName, const(Param)[] params)
	{
		auto buf = appender!(ubyte[]);
		write(buf, portalName);         // Portal name
		write(buf, stmtName);           // Statement name
		write(buf, cast(ushort)0);      // Number of parameter format codes (use default text)
		write(buf, cast(ushort)params.length);  // Number of parameters

		foreach (ref param; params)
		{
			auto text = parameterText(param);
			if (text is null)
			{
				write(buf, cast(int)-1);  // NULL value
			}
			else
			{
				write(buf, cast(int)text.length);  // Length
				buf.put(cast(const(ubyte)[])text); // Value (no null terminator)
			}
		}

		write(buf, cast(ushort)0);      // Number of result format codes (use default text)
		sendPacket('B', buf.data);
	}

	/// Send Describe message (Extended Query protocol)
	void sendDescribe(char type, const(char)[] name)
	{
		auto buf = appender!(ubyte[]);
		buf.put(cast(ubyte)type);       // 'S' for statement, 'P' for portal
		write(buf, name);
		sendPacket('D', buf.data);
	}

	/// Send Execute message (Extended Query protocol)
	void sendExecute(const(char)[] portalName, int maxRows = 0)
	{
		auto buf = appender!(ubyte[]);
		write(buf, portalName);
		write(buf, maxRows);            // Max rows (0 = unlimited)
		sendPacket('E', buf.data);
	}

	/// Send Close message (Extended Query protocol)
	void sendClose(char type, const(char)[] name)
	{
		auto buf = appender!(ubyte[]);
		buf.put(cast(ubyte)type);       // 'S' for statement, 'P' for portal
		write(buf, name);
		sendPacket('C', buf.data);
	}

	/// Send Sync message (Extended Query protocol)
	void sendSync()
	{
		sendPacket('S', []);
	}

	/// Close a prepared statement
	Promise!void closeStatement(PreparedStatement stmt)
	{
		auto promise = new Promise!void;
		PendingOp op;
		op.type = PendingOpType.close;
		op.closePromise = promise;
		pendingOps ~= op;
		sendClose('S', stmt.name);
		sendSync();
		return promise;
	}
}

/// The type of the parameter `param` (see `PgSqlConnection.query`).
private PgOid parameterType(const Param param)
{
	final switch (param.type) with (Param.Type)
	{
		case null_: return PgOid.unknown;
		case boolean: return PgOid.boolean;
		case integer: return param.integer >= int.min && param.integer <= int.max ? PgOid.int4 : PgOid.int8;
		case floating: return PgOid.float8;
		case numeric: return PgOid.numeric;
		case text: return PgOid.unknown;
		case bytes: return PgOid.bytea;
		case array: return PgOid.unknown;
	}
}

/// The parameter `param` in PostgreSQL's text format (null: NULL): a
/// byte array as `bytea`'s hex format, an array as an array value (its
/// elements quoted, but numbers, booleans and NULL).
private const(char)[] parameterText(const Param param)
{
	final switch (param.type) with (Param.Type)
	{
		case null_:
		case boolean:
		case integer:
		case floating:
		case numeric:
		case text:
			return param.toText();
		case bytes:
			return "\\x" ~ bytesToHex(param.bytes);
		case array:
			auto items = appender!string;
			items.put('{');
			foreach (i, ref element; param.elements)
			{
				if (i)
					items.put(',');
				final switch (element.type) with (Param.Type)
				{
					case null_: items.put("NULL"); break;
					case boolean:
					case integer:
					case floating:
					case numeric:
					case array:
						items.put(parameterText(element));
						break;
					case text:
					case bytes:
						items.put('"');
						items.put(parameterText(element).replace(`\`, `\\`).replace(`"`, `\"`));
						items.put('"');
						break;
				}
			}
			items.put('}');
			return items.data;
	}
}

private string bytesToHex(const(ubyte)[] data)
{
	auto result = new char[data.length * 2];
	foreach (i, b; data)
	{
		result[i*2] = "0123456789abcdef"[b >> 4];
		result[i*2+1] = "0123456789abcdef"[b & 0xf];
	}
	return cast(string)result;
}

/// Decode PostgreSQL bytea hex format (\x...).
ubyte[] decodeBytea(const(char)[] value)
{
	if (value.length >= 2 && value[0..2] == "\\x")
	{
		// Hex format
		auto hex = value[2..$];
		auto result = new ubyte[hex.length / 2];
		foreach (i; 0 .. result.length)
		{
			result[i] = cast(ubyte)(hexDigit(hex[i*2]) << 4 | hexDigit(hex[i*2+1]));
		}
		return result;
	}
	else
	{
		// Escape format (legacy)
		auto result = appender!(ubyte[]);
		for (size_t i = 0; i < value.length; i++)
		{
			if (value[i] == '\\' && i + 1 < value.length)
			{
				if (value[i+1] == '\\')
				{
					result.put(cast(ubyte)'\\');
					i++;
				}
				else if (i + 3 < value.length)
				{
					// Octal escape \NNN
					result.put(cast(ubyte)(
						(value[i+1] - '0') * 64 +
						(value[i+2] - '0') * 8 +
						(value[i+3] - '0')
					));
					i += 3;
				}
			}
			else
			{
				result.put(cast(ubyte)value[i]);
			}
		}
		return result.data;
	}
}

private ubyte hexDigit(char c)
{
	if (c >= '0' && c <= '9') return cast(ubyte)(c - '0');
	if (c >= 'a' && c <= 'f') return cast(ubyte)(c - 'a' + 10);
	if (c >= 'A' && c <= 'F') return cast(ubyte)(c - 'A' + 10);
	throw new PgSqlException("Invalid hex digit: " ~ c);
}

/// PostgreSQL exception, with the fields of the server's error message
/// (if it is one).
class PgSqlException : DbException
{
	PgSqlMessage errorResponse;

	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}

	this(PgSqlMessage response, string file = __FILE__, size_t line = __LINE__)
	{
		this.errorResponse = response;
		auto msg = response.message;
		if (!msg.length)
			msg = response.toString();
		super(msg.idup, file, line);
	}

	@property const(char)[] severity() const { return errorResponse.severity; }
	@property const(char)[] sqlState() const { return errorResponse.sqlState; }
	@property const(char)[] detail() const { return errorResponse.detail; }
	@property const(char)[] hint() const { return errorResponse.hint; }
}

// Parameters: their types and text
debug(ae_unittest) unittest
{
	assert(parameterType(Param.of(1)) == PgOid.int4 && parameterType(Param.of(1L << 40)) == PgOid.int8);
	assert(parameterType(Param.of("x")) == PgOid.unknown && parameterType(Param.of(true)) == PgOid.boolean);
	assert(parameterType(Param.numeric("1.5")) == PgOid.numeric && parameterType(Param.of(1.5)) == PgOid.float8);
	assert(parameterText(Param.of(true)) == "true" && parameterText(Param.of(null)) is null);
	assert(parameterText(Param.of(cast(const(ubyte)[]) "AB")) == `\x4142`);
	auto array = Param.array([Param.of("a"), Param.of(`b"\`), Param.of(null), Param.of(3)]);
	assert(parameterText(array) == `{"a","b\"\\",NULL,3}`, parameterText(array));
	assert(parameterText(Param.array(null)) == "{}");
}

// Values
debug(ae_unittest) unittest
{
	auto row = Row(["i", "b", "s", "x"], ["42", "t", "hello", `\x48454c4c4f`], [false, false, false, false]);
	assert(row.column!int("i") == 42 && row.column!long(0) == 42 && row.column!bool("b"));
	assert(row.column!string("s") == "hello" && row.column!(ubyte[])("x") == cast(ubyte[]) "HELLO");
	assert(decodeBytea("\\x") == []);
}

// Unit tests for MD5 authentication
debug(ae_unittest) unittest
{
	// Test MD5 hash computation matches PostgreSQL's algorithm
	// md5("md5" + md5(password + username) + salt)
	import std.digest.md : md5Of, toHexString, LetterCase;

	string user = "testuser";
	string password = "testpass";
	ubyte[4] salt = [0x01, 0x02, 0x03, 0x04];

	auto inner = md5Of(password, user);
	auto innerHex = inner.toHexString!(LetterCase.lower);
	auto outer = md5Of(innerHex[], salt[]);
	auto outerHex = outer.toHexString!(LetterCase.lower);

	// The result should be "md5" + 32 hex chars
	auto result = "md5" ~ outerHex[];
	assert(result.length == 35);
	assert(result[0..3] == "md5");
}

// Queries, pipelined, with promises
version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await, awaitSync;

	async({
		// Uses environment variables: PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD
		auto pg = connect().await;
		scope(exit) pg.close().await;

		// Pipelined queries (all sent before the first completes)
		auto q1 = pg.query("SELECT 1 + 1 AS result").array;
		auto q2 = pg.query("SELECT 2 * 3 AS product").array;
		auto q3 = pg.query("SELECT generate_series(1, 3) AS n").array;
		auto rows = q1.await;
		assert(rows.length == 1 && rows[0].column!int(0) == 2 && rows[0].column!int("result") == 2);
		assert(q2.await[0].column!int("product") == 6);
		rows = q3.await;
		assert(rows.length == 3 && rows[2].column!int("n") == 3);

		// Prepared statements, reused
		auto stmt = pg.prepare("SELECT $1::int + $2::int AS sum").await;
		assert(stmt.query(10, 20).array.await[0].column!int("sum") == 30);
		assert(stmt.query([Param.of(100), Param.of(200)]).array.await[0].column!int("sum") == 300);

		// Fiber-based foreach
		int product = 1;
		foreach (row; stmt.query(2, 3))
			product *= row.column!int("sum");
		assert(product == 5);
		stmt.close().await;

		int sum = 0;
		foreach (row; pg.query("SELECT generate_series(1, 5) AS n"))
			sum += row.column!int("n");
		assert(sum == 15);
	}).awaitSync();
}

// Queries with parameters (unnamed Extended Query operations)
version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await, awaitSync;

	async({
		auto pg = connect().await;
		scope(exit) pg.close().await;

		// Zero parameters (Simple Query protocol), and parameters typed by
		// their D types
		assert(pg.query("SELECT 42 AS answer").array.await[0].column!int("answer") == 42);
		auto r1 = pg.query("SELECT $1 + $2 AS sum, $3 AS s, $4 AS b, pg_typeof($1)::text AS t1, " ~
			"pg_typeof($5)::text AS t5, pg_typeof($6)::text AS t6, pg_typeof($7)::text AS t7",
			10, 20, "hello", true, 5_000_000_000L, 1.5, Param.numeric("2.50")).array.await;
		assert(r1[0].column!int("sum") == 30 && r1[0].column!string("s") == "hello" && r1[0].column!bool("b"));
		assert(r1[0].column!string("t1") == "integer" && r1[0].column!string("t5") == "bigint");
		assert(r1[0].column!string("t6") == "double precision" && r1[0].column!string("t7") == "numeric");

		// Strings, typed by their context (as string literals are)
		auto r2 = pg.query("SELECT $1 = DATE '2020-01-31' AS d, $2 = ANY('{1,2}'::int[]) AS a",
			[Param.of("2020-01-31"), Param.of("2")]).array.await;
		assert(r2[0].column!bool("d") && r2[0].column!bool("a"));

		// Arrays, typed by their context
		auto r3 = pg.query("SELECT 2 = ANY($1) AS a, 'b' = ANY($2) AS b",
			[Param.array([Param.of(1), Param.of(2)]), Param.array([Param.of("a"), Param.of("b")])]).array.await;
		assert(r3[0].column!bool("a") && r3[0].column!bool("b"));

		// NULL parameters
		auto r4 = pg.query("SELECT $1::int IS NULL AS a, coalesce($2::text, 'dflt') AS b",
			null, Nullable!string.init).array.await;
		assert(r4[0].column!bool("a") && r4[0].column!string("b") == "dflt");
		auto r5 = pg.query("SELECT $1::int AS v", Nullable!int.init).array.await;
		assert(r5[0].isNull("v") && r5[0].column!(Nullable!int)("v").isNull);

		// Empty result set; statements returning no rows, and the rows
		// they affect
		assert(pg.query("SELECT 1 AS x WHERE $1 > $2", 1, 2).array.await.length == 0);
		pg.query("CREATE TEMP TABLE param_test (a int, b text, c bytea)").array.await;
		auto insert = pg.query("INSERT INTO param_test VALUES ($1, $2, $3), ($1 + 1, $2, NULL)",
			1, "one", cast(const(ubyte)[]) "\x00\xff");
		assert(insert.array.await.length == 0 && insert.affectedRows == 2);
		auto r6 = pg.query("SELECT b, c FROM param_test WHERE a = $1", 1).array.await;
		assert(r6.length == 1 && r6[0].column!string("b") == "one" && r6[0].column!(ubyte[])("c") == [0, 255]);

		// Lazy foreach iteration
		int sum = 0;
		foreach (row; pg.query("SELECT generate_series(1, $1) AS n", 5))
			sum += row.column!int("n");
		assert(sum == 15);
	}).awaitSync();
}

// Query errors, recovery, and pipelining
version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await, awaitSync;

	async({
		auto pg = connect().await;
		scope(exit) pg.close().await;

		bool failsWith(string sqlState, Result result)
		{
			try
				result.array.await;
			catch (PgSqlException e)
				return e.sqlState == sqlState;
			return false;
		}

		// Parse error (syntax error); runtime error (after Parse and Bind
		// succeed); the connection recovers after each
		assert(failsWith("42601", pg.query("SELECT WHERE FROM $1", 1)));
		assert(pg.query("SELECT $1 AS v", 1).array.await[0].column!int("v") == 1);
		assert(failsWith("22012", pg.query("SELECT $1 / $2 AS q", 1, 0)));
		assert(pg.query("SELECT $1 AS v", 2).array.await[0].column!int("v") == 2);

		// Several statements are rejected with parameters, accepted without
		assert(failsWith("42601", pg.query("SELECT 1 AS a; SELECT 2 AS b", 1)));
		auto rm = pg.query("SELECT 1 AS a; SELECT 2 AS b").array.await;
		assert(rm.length == 2 && rm[0].column!int("a") == 1 && rm[1].column!int("b") == 2);

		// Pipelined queries with an error in the middle: the error does not
		// affect the others
		auto pa = pg.query("SELECT $1 AS v", 1).array;
		auto pb = pg.query("SELECT $1 / 0 AS v", 1);
		auto pc = pg.query("SELECT 3 AS v").array;
		assert(pa.await[0].column!int("v") == 1);
		assert(failsWith("22012", pb));
		assert(pc.await[0].column!int("v") == 3);

		// Large SQL text and parameters
		import std.array : replicate;
		auto big = "y".replicate(1024 * 1024);
		auto r = pg.query("SELECT length($1::text) AS len, $1::text AS echo /* " ~ "x".replicate(512 * 1024) ~ " */",
			big).array.await;
		assert(r[0].column!int("len") == big.length && r[0].column!string("echo") == big);
	}).awaitSync();
}

// Connecting: by URI; DNS resolution failure and connection refused reject
// the connection's promise
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await, awaitSync;

	int errors;
	async({
		foreach (p; [connect("nonexistent.invalid.", 5432, "user", "db", "pass"),
				connect("127.0.0.1", 63999, "user", "db", "pass"), connect("http://localhost")])
			try
				p.await;
			catch (Exception e)
				errors++;
	}).awaitSync();
	assert(errors == 3, "Expected the connections to fail");
}

// Authentication error: rejected cleanly
version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await, awaitSync;

	bool gotError = false;
	async({
		try
			connect(environment.get("PGHOST", "localhost"), environment.get("PGPORT", "5432").to!ushort,
				environment.get("PGUSER", "testuser"), environment.get("PGDATABASE", "testdb"),
				"definitely_wrong_password_12345").await;
		catch (PgSqlException e)
			gotError = true;
	}).awaitSync();
	assert(gotError, "Expected authentication error");
}

// Test TLS against a real server. Active when the test environment selects
// TLS via PGSSLMODE (requires an SSL provider, e.g. ae.net.ssl.openssl).
version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await, awaitSync;

	auto sslMode = environment.get("PGSSLMODE", "prefer");
	if (sslMode == "disable" || (sslMode == "prefer" && !sslAvailable))
		return;

	async({
		auto pg = connect().await;
		scope(exit) pg.close().await;

		assert(pg.encrypted, "Expected a TLS connection with PGSSLMODE=" ~ sslMode);
		auto rows = pg.query("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()").array.await;
		assert(rows.length == 1 && rows[0].column!bool("ssl"), "Server does not see the connection as TLS");
	}).awaitSync();

	// With verification, connecting via a name not in the certificate must fail.
	if (sslMode == "verify-full")
	{
		bool gotError;
		async({
			auto ctx = ssl.createContext(SSLContext.Kind.client);
			ctx.setPeerVerify(SSLContext.Verify.require);
			if (auto rootCert = environment.get("PGSSLROOTCERT"))
				ctx.setPeerRootCertificate(rootCert);
			auto tcp = new TcpConnection;
			auto pg = connect(tcp,
				environment.get("PGUSER", "testuser"),
				environment.get("PGDATABASE", "testdb"),
				environment.get("PGPASSWORD"),
				SSLMode.require, ctx, "wrong-host.invalid");
			tcp.connect(environment.get("PGHOST", "localhost"), environment.get("PGPORT", "5432").to!ushort);
			try
				pg.await;
			catch (PgSqlException e)
				gotError = true;
		}).awaitSync();
		assert(gotError, "Expected certificate host name verification to fail");
	}
}

// Test SSL mode handling when no SSL provider is linked in:
// `prefer` (the default) silently skips TLS, `require` fails cleanly.
debug(ae_unittest) unittest
{
	import ae.net.ssl : SSLProvider, NoSSLProvider;
	import ae.utils.promise.await : async, await, awaitSync;

	auto savedProvider = ssl;
	ssl = new NoSSLProvider;
	scope(exit) ssl = savedProvider;

	// Mock server: expects a StartupMessage (not an SSLRequest), and
	// replies with AuthenticationOk + ReadyForQuery.
	ushort startServer(out bool sawSSLRequest)
	{
		auto server = new TcpServer;
		server.handleAccept = (TcpConnection c) {
			server.close();
			Data buf;
			c.handleReadData = (Data d) {
				buf ~= d;
				if (buf.length < 8)
					return;
				auto msg = buf.toGC();
				if (msg[4 .. 8].bigEndianToNative!uint == 80877103)
				{
					sawSSLRequest = true;
					return c.disconnect();
				}
				if (buf.length < msg[0 .. 4].bigEndianToNative!uint)
					return;
				static immutable ubyte[] reply = [
					'R', 0, 0, 0, 8, 0, 0, 0, 0, // AuthenticationOk
					'Z', 0, 0, 0, 5, 'I',        // ReadyForQuery
				];
				c.send(Data(reply));
			};
		};
		return server.listen(0, "127.0.0.1");
	}

	// Default mode (prefer): connects without TLS.
	{
		bool sawSSLRequest, ready, encrypted;
		auto port = startServer(sawSSLRequest);
		async({
			auto pg = connect("127.0.0.1", port, "user", "db").await;
			ready = true;
			encrypted = pg.encrypted;
			pg.close().await;
		}).awaitSync();
		assert(ready && !encrypted && !sawSSLRequest);
	}

	// require: fails with a clear error, without sending an SSLRequest.
	{
		bool sawSSLRequest;
		string error;
		auto port = startServer(sawSSLRequest);
		async({
			try
				connect("127.0.0.1", port, "user", "db", null, SSLMode.require).await;
			catch (PgSqlException e)
				error = e.msg;
		}).awaitSync();
		assert(error.indexOf("SSL provider") >= 0, error);
		assert(!sawSSLRequest);
	}

	// verify-full (of a URI): fails without an SSL provider; unsupported
	// modes and parameters are rejected.
	foreach (uri; ["postgresql://localhost/db?sslmode=verify-full", "postgresql://localhost/db?sslmode=allow",
			"postgresql://localhost/db?connect_timeout=1"])
	{
		string error;
		async({
			try
				connect(uri).await;
			catch (PgSqlException e)
				error = e.msg;
		}).awaitSync();
		assert(error.length, uri);
	}
}
