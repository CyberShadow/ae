/**
 * PostgreSQL protocol implementation.
 *
 * Implements the PostgreSQL wire protocol (version 3.0) for asynchronous
 * database access integrated with the ae event loop.
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
import ae.utils.array;
import ae.utils.exception;
import ae.utils.promise;

// TODO: SCRAM-SHA-256 authentication (modern default, more secure than MD5)
// TODO: SSL/TLS support - wrap connection with OpenSSLAdapter before passing to PgSqlConnection
// TODO: COPY protocol for bulk data import/export
// TODO: LISTEN/NOTIFY for async notifications
// TODO: Large Object support
// TODO: Connection pooling
// TODO: Unix socket support (currently only TCP; PGHOST must be a hostname, not a socket path)

/// PostgreSQL connection handling the wire protocol.
final class PgSqlConnection
{
public:
	/// Connect using standard PostgreSQL environment variables.
	/// Environment variables used:
	///   PGHOST - server hostname (default: localhost)
	///   PGPORT - server port (default: 5432)
	///   PGUSER - username (default: current OS user)
	///   PGDATABASE - database name (default: same as user)
	///   PGPASSWORD - password (default: none)
	this()
	{
		this(
			environment.get("PGHOST", "localhost"),
			environment.get("PGPORT", "5432").to!ushort,
			environment.get("PGUSER", environment.get("USER", "postgres")),
			environment.get("PGDATABASE", environment.get("PGUSER", environment.get("USER", "postgres"))),
			environment.get("PGPASSWORD")
		);
	}

	/// Connect with explicit connection parameters.
	this(string host, ushort port, string user, string database, string password = null)
	{
		this.user = user;
		this.database = database;
		this.password = password;

		auto tcpConn = new TcpConnection;
		this.conn = tcpConn;

		tcpConn.handleConnect = &onConnect;
		tcpConn.handleReadData = &onReadData;
		tcpConn.handleDisconnect = &onDisconnect;

		tcpConn.connect(host, port);
	}

	/// Construct with an existing connection (for custom transports like SSL).
	/// The connection should not yet be connected; PgSqlConnection will
	/// send the startup message when it connects.
	/// Params:
	///   conn = underlying transport connection (e.g., TcpConnection wrapped in OpenSSLAdapter)
	///   user = PostgreSQL user name
	///   database = database name to connect to
	///   password = optional password for authentication
	this(IConnection conn, string user, string database, string password = null)
	{
		this.conn = conn;
		this.user = user;
		this.database = database;
		this.password = password;

		conn.handleConnect = &onConnect;
		conn.handleReadData = &onReadData;
		conn.handleDisconnect = &onDisconnect;
	}

	/// PostgreSQL error/notice response fields.
	struct ErrorResponse
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

	/// Description of a result field/column.
	struct FieldDescription
	{
		const(char)[] name;
		uint tableOid;       /// OID of the table (0 if not a table column)
		ushort columnAttr;   /// Column attribute number (0 if not a table column)
		uint typeOid;        /// OID of the data type
		short typeSize;      /// Data type size (-1 for variable-length)
		int typeModifier;    /// Type-specific modifier
		ushort formatCode;   /// Format code: 0=text, 1=binary
	}

	/// Common PostgreSQL type OIDs.
	enum PgOid : uint
	{
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

	/// A single row from a query result.
	struct Row
	{
		private const(FieldDescription)[] fields;
		private const(const(char)[])[] values;
		private const(bool)[] nulls;

		/// Get column value by index with type conversion.
		T column(T)(size_t idx) const
		{
			enforce!PgSqlException(idx < values.length, "Column index out of range");
			static if (is(T == Nullable!U, U))
			{
				if (nulls[idx])
					return T.init;
				return T(column!U(idx));
			}
			else
			{
				enforce!PgSqlException(!nulls[idx], "NULL value for non-nullable column");
				return convertValue!T(values[idx], fields[idx].typeOid);
			}
		}

		/// Get column value by name with type conversion.
		T column(T)(const(char)[] name) const
		{
			return column!T(fieldIndex(name));
		}

		/// Check if a column is NULL.
		bool isNull(size_t idx) const
		{
			enforce!PgSqlException(idx < nulls.length, "Column index out of range");
			return nulls[idx];
		}

		/// Check if a column is NULL by name.
		bool isNull(const(char)[] name) const
		{
			return isNull(fieldIndex(name));
		}

		/// Get the number of columns.
		size_t length() const
		{
			return values.length;
		}

		/// Find column index by name.
		private size_t fieldIndex(const(char)[] name) const
		{
			foreach (i, field; fields)
				if (field.name == name)
					return i;
			throw new PgSqlException("Unknown column: " ~ name.idup);
		}
	}

	/// Lazy query result handle.
	/// The query is not sent until a consumption method is called.
	/// Each Result can only be consumed once (via array(), map(), or foreach).
	final class Result
	{
		private const(char)[] sql;
		private PreparedStatement preparedStatement;
		private const(char)[][] queryArgs;
		private bool started;
		private bool completed;
		private bool consumed;
		private FieldDescription[] fields;
		private const(char)[] commandTag;
		private PgSqlException error;

		// For array() mode
		private Row[] bufferedRows;
		private Promise!(Row[]) arrayPromise;

		// For map() mode
		private void delegate(Row) rowCallback;

		// For lazy iteration (opApply)
		private bool iterating;
		private PromiseQueue!(Nullable!Row) iterQueue;

		private this(const(char)[] sql)
		{
			this.sql = sql;
		}

		/// Collect all rows and return as array.
		Promise!(Row[]) array()
		{
			enforce!PgSqlException(!consumed, "Result has already been consumed");
			consumed = true;

			if (error)
			{
				auto p = new Promise!(Row[]);
				p.reject(error);
				return p;
			}
			if (completed)
				return resolve(bufferedRows);

			arrayPromise = new Promise!(Row[]);
			startIfNeeded();
			return arrayPromise;
		}

		/// Map a function over rows as they arrive, returning collected results.
		Promise!(T[]) map(T)(T delegate(Row) fn)
		{
			enforce!PgSqlException(!consumed, "Result has already been consumed");
			consumed = true;

			auto resultPromise = new Promise!(T[]);
			T[] results;

			if (error)
			{
				resultPromise.reject(error);
				return resultPromise;
			}

			if (completed)
			{
				foreach (row; bufferedRows)
					results ~= fn(row);
				resultPromise.fulfill(results);
				return resultPromise;
			}

			rowCallback = (Row row) {
				results ~= fn(row);
			};
			arrayPromise = new Promise!(Row[]);
			arrayPromise.then((Row[] _) {
				resultPromise.fulfill(results);
			}).except((Exception e) {
				resultPromise.reject(e);
			});

			startIfNeeded();
			return resultPromise;
		}

		/// Fiber-based foreach iteration (requires fiber context).
		/// Rows are processed lazily as they arrive from the server.
		int opApply(scope int delegate(Row) dg)
		{
			import ae.utils.promise.await : await;

			enforce!PgSqlException(!consumed, "Result has already been consumed");
			consumed = true;

			if (error)
				throw error;

			// If already completed, iterate buffered rows
			if (completed)
			{
				foreach (row; bufferedRows)
					if (auto r = dg(row))
						return r;
				return 0;
			}

			// Lazy iteration: process rows as they arrive
			iterating = true;
			iterQueue = PromiseQueue!(Nullable!Row).init;
			scope(exit)
			{
				iterating = false;
				iterQueue = PromiseQueue!(Nullable!Row).init;
			}

			startIfNeeded();

			while (true)
			{
				auto item = iterQueue.waitOne().await;

				if (error)
					throw error;

				if (item.isNull)
					break;  // End of results

				if (auto r = dg(item.get))
					return r;
			}

			return 0;
		}

		private void startIfNeeded()
		{
			if (!started)
			{
				started = true;
				this.outer.startQuery(this);
			}
		}

		private void onRowDescription(FieldDescription[] fields)
		{
			this.fields = fields;
		}

		private void onDataRow(const(const(char)[])[] values, const(bool)[] nulls)
		{
			auto row = Row(fields, values, nulls);
			if (iterating)
				iterQueue.fulfillOne(Nullable!Row(row));
			else if (rowCallback)
				rowCallback(row);
			else
				bufferedRows ~= row;
		}

		private void onCommandComplete(const(char)[] tag)
		{
			commandTag = tag;
		}

		private void onComplete()
		{
			completed = true;
			if (arrayPromise)
				arrayPromise.fulfill(bufferedRows);
			if (iterating)
				iterQueue.fulfillOne(Nullable!Row.init);  // End marker
		}

		private void onError(PgSqlException e)
		{
			error = e;
			completed = true;
			if (arrayPromise)
				arrayPromise.reject(e);
			if (iterating)
				iterQueue.fulfillOne(Nullable!Row.init);  // Signal to unblock, error checked after
		}
	}

	/// Create a lazy query result using Simple Query protocol.
	/// The query is not sent until you call .array(), .map(), or iterate.
	/// For parameterized queries, use prepare() instead.
	Result query(const(char)[] sql)
	{
		return new Result(sql);
	}

	/// Prepared statement handle for Extended Query protocol.
	/// Allows executing the same query multiple times with different parameters.
	final class PreparedStatement
	{
		private const(char)[] name;
		private FieldDescription[] fields;
		private uint[] paramTypes;
		private bool closed;

		private this(const(char)[] name)
		{
			this.name = name;
		}

		/// Execute the prepared statement with the given parameters.
		/// Returns a lazy Result that can be consumed with .array(), .map(), or foreach.
		Result query(Args...)(Args args)
		{
			enforce!PgSqlException(!closed, "PreparedStatement has been closed");
			auto result = new Result(null);
			result.preparedStatement = this;
			result.queryArgs = toQueryArgs(args);
			return result;
		}

		/// Close the prepared statement, freeing server resources.
		/// The statement cannot be used after closing.
		Promise!void close()
		{
			enforce!PgSqlException(!closed, "PreparedStatement already closed");
			closed = true;
			return this.outer.closeStatement(this);
		}

		private void setFields(FieldDescription[] fields)
		{
			this.fields = fields;
		}

		private void setParamTypes(uint[] types)
		{
			this.paramTypes = types;
		}
	}

	/// Prepare a statement for execution with parameters.
	/// Uses Extended Query protocol for safe parameter binding (prevents SQL injection).
	/// Example:
	/// ---
	/// pg.prepare("SELECT * FROM users WHERE id = $1").then((stmt) {
	///     stmt.query(42).array.then((rows) { ... });
	/// });
	/// ---
	Promise!PreparedStatement prepare(const(char)[] sql)
	{
		auto promise = new Promise!PreparedStatement;
		auto name = generateStatementName();
		auto stmt = new PreparedStatement(name);
		PendingOp op;
		op.type = PendingOpType.prepare;
		op.stmt = stmt;
		op.preparePromise = promise;
		pendingOps ~= op;
		sendParse(name, sql);
		sendDescribe('S', name);
		sendSync();
		return promise;
	}

	/// Disconnect from the server.
	void disconnect(string reason = "Client disconnect")
	{
		conn.disconnect(reason);
	}

	/// Promise that fulfills when the connection is ready for queries.
	/// Fulfilled with the initial transaction status on first ReadyForQuery.
	/// Rejected if an error occurs during connection setup.
	/// For fiber users: `await(pg.ready);`
	@property Promise!TransactionStatus ready()
	{
		if (readyPromise is null)
		{
			readyPromise = new Promise!TransactionStatus;
			// If already ready, fulfill immediately
			if (isReady)
				readyPromise.fulfill(currentTransactionStatus);
		}
		return readyPromise;
	}

	/// Callback handlers for connection-level events.
	void delegate(ErrorResponse response) handleError;
	void delegate() handleAuthenticated;
	void delegate(const(char)[] name, const(char)[] value) handleParameterStatus;
	void delegate(TransactionStatus transactionStatus) handleReadyForQuery;
	void delegate(ErrorResponse notice) handleNotice;
	void delegate(string reason, DisconnectType type) handleDisconnect;

	string applicationName = "ae.net.db.psql";

private:
	IConnection conn;

	string user;
	string database;
	string password;

	/// Promise for ready() property
	Promise!TransactionStatus readyPromise;
	bool isReady;
	TransactionStatus currentTransactionStatus;

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
	}

	/// Queue of pending operations (FIFO - PostgreSQL processes in order)
	PendingOp[] pendingOps;

	/// Counter for generating unique statement names
	uint statementCounter;

	/// Get the current operation being processed (head of queue)
	@property PendingOp* currentOp()
	{
		return pendingOps.length > 0 ? &pendingOps[0] : null;
	}

	/// Generate a unique statement name
	const(char)[] generateStatementName()
	{
		return "_ps" ~ (statementCounter++).to!string;
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
		sendStartupMessage();
	}

	void onDisconnect(string reason, DisconnectType type)
	{
		// Fail all pending operations
		auto err = new PgSqlException("Connection lost: " ~ reason);

		// Reject ready promise if not yet ready
		if (!isReady && readyPromise)
			readyPromise.reject(err);

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

		if (handleDisconnect)
			handleDisconnect(reason, type);
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
			else
				break;
		}
	}

	void processPacket(PacketType type, Data data)
	{
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
				auto response = parseErrorResponse(data);
				auto err = new PgSqlException(response);

				if (currentOp)
				{
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
				else if (!isReady && readyPromise)
				{
					// Error during connection setup - reject ready promise
					readyPromise.reject(err);
				}
				else if (handleError)
					handleError(response);
				else
					throw err;
				break;
			}

			case PacketType.noticeResponse:
			{
				auto response = parseErrorResponse(data);
				if (handleNotice)
					handleNotice(response);
				break;
			}

			case PacketType.parameterStatus:
			{
				auto name = readString(data);
				auto value = readString(data);
				if (handleParameterStatus)
					handleParameterStatus(name, value);
				break;
			}

			case PacketType.readyForQuery:
			{
				auto status = cast(TransactionStatus)readChar(data);
				currentTransactionStatus = status;

				// First ReadyForQuery means connection is ready
				if (!isReady)
				{
					isReady = true;
					if (readyPromise)
						readyPromise.fulfill(status);
				}

				if (currentOp)
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
					// Pop completed operation from queue
					pendingOps = pendingOps[1..$];
				}

				if (handleReadyForQuery)
					handleReadyForQuery(status);
				break;
			}

			case PacketType.rowDescription:
			{
				auto fieldCount = readInt!ushort(data);
				auto fields = new FieldDescription[fieldCount];
				foreach (i; 0..fieldCount)
				{
					fields[i].name = readString(data);
					fields[i].tableOid = readInt!uint(data);
					fields[i].columnAttr = readInt!ushort(data);
					fields[i].typeOid = readInt!uint(data);
					fields[i].typeSize = readInt!short(data);
					fields[i].typeModifier = readInt!int(data);
					fields[i].formatCode = readInt!ushort(data);
				}
				if (currentOp)
				{
					if (currentOp.type == PendingOpType.prepare)
						currentOp.stmt.setFields(fields);
					else if (currentOp.type == PendingOpType.query)
						currentOp.result.onRowDescription(fields);
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
					currentOp.result.onDataRow(values, nulls);
				break;
			}

			case PacketType.commandComplete:
			{
				auto tag = readString(data);
				if (currentOp && currentOp.type == PendingOpType.query)
					currentOp.result.onCommandComplete(tag);
				break;
			}

			case PacketType.emptyQueryResponse:
				// Empty query string was sent
				if (currentOp && currentOp.type == PendingOpType.query)
					currentOp.result.onCommandComplete(null);
				break;

			// Extended Query protocol responses
			case PacketType.parseComplete:
				// Parse succeeded, statement is ready
				break;

			case PacketType.bindComplete:
				// Bind succeeded, portal is ready
				break;

			case PacketType.closeComplete:
				// Close succeeded
				break;

			case PacketType.noData:
				// Statement returns no rows (e.g., INSERT/UPDATE/DELETE)
				if (currentOp && currentOp.type == PendingOpType.prepare)
					currentOp.stmt.setFields(null);
				break;

			case PacketType.parameterDescription:
			{
				auto paramCount = readInt!ushort(data);
				auto types = new uint[paramCount];
				foreach (i; 0 .. paramCount)
					types[i] = readInt!uint(data);
				if (currentOp && currentOp.type == PendingOpType.prepare)
					currentOp.stmt.setParamTypes(types);
				break;
			}

			default:
				throw new PgSqlException("Unknown packet type '%s' (0x%02X)".format(cast(char)type, cast(ubyte)type));
		}
	}

	ErrorResponse parseErrorResponse(ref Data data)
	{
		ErrorResponse response;
		while (data.length)
		{
			auto fieldType = readChar(data);
			if (!fieldType)
				break;
			response.fields ~= ErrorResponse.Field(fieldType, readString(data));
		}
		return response;
	}

	void processAuthRequest(ref Data data)
	{
		auto authType = readInt!uint(data);
		switch (authType)
		{
			case 0: // AuthenticationOk
				if (handleAuthenticated)
					handleAuthenticated();
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

			default:
				throw new PgSqlException("Unsupported authentication method: " ~ authType.to!string);
		}
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

		conn.send(Data(nativeToBigEndian(cast(uint)(buf.data.length + uint.sizeof))[]));
		conn.send(Data(buf.data));
	}

	void sendPacket(char type, const(ubyte)[] data)
	{
		conn.send(Data(type.asBytes));
		conn.send(Data(nativeToBigEndian(cast(uint)(data.length + uint.sizeof))[]));
		conn.send(Data(data));
	}

	void startQuery(Result result)
	{
		pendingOps ~= PendingOp(PendingOpType.query, result);

		if (result.preparedStatement !is null)
		{
			// Extended Query protocol: Bind + Execute + Sync
			auto stmt = result.preparedStatement;

			// Use the prepared statement's cached field descriptions
			if (stmt.fields !is null)
				result.onRowDescription(stmt.fields);

			sendBind("", stmt.name, result.queryArgs);
			sendExecute("");
			sendSync();
		}
		else
		{
			// Simple Query protocol
			auto buf = appender!(ubyte[]);
			write(buf, result.sql);
			sendPacket('Q', buf.data);
		}
	}

	/// Send Parse message (Extended Query protocol)
	void sendParse(const(char)[] stmtName, const(char)[] sql)
	{
		auto buf = appender!(ubyte[]);
		write(buf, stmtName);           // Statement name
		write(buf, sql);                // Query string
		write(buf, cast(ushort)0);      // Number of parameter types (let server infer)
		sendPacket('P', buf.data);
	}

	/// Send Bind message (Extended Query protocol)
	void sendBind(const(char)[] portalName, const(char)[] stmtName, const(char)[][] params)
	{
		auto buf = appender!(ubyte[]);
		write(buf, portalName);         // Portal name
		write(buf, stmtName);           // Statement name
		write(buf, cast(ushort)0);      // Number of parameter format codes (use default text)
		write(buf, cast(ushort)params.length);  // Number of parameters

		foreach (param; params)
		{
			if (param is null)
			{
				write(buf, cast(int)-1);  // NULL value
			}
			else
			{
				write(buf, cast(int)param.length);  // Length
				buf.put(cast(const(ubyte)[])param); // Value (no null terminator)
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

/// Convert D values to PostgreSQL text format parameters
const(char)[][] toQueryArgs(Args...)(Args args)
{
	const(char)[][] result;
	foreach (arg; args)
	{
		result ~= toQueryArg(arg);
	}
	return result;
}

/// Convert a single D value to PostgreSQL text format
const(char)[] toQueryArg(T)(T value)
{
	import std.format : format;

	static if (is(T == typeof(null)))
		return null;
	else static if (is(T == Nullable!U, U))
		return value.isNull ? null : toQueryArg(value.get);
	else static if (is(T : const(char)[]))
		return value;
	else static if (is(T == bool))
		return value ? "t" : "f";
	else static if (is(T : long) || is(T : double))
		return format!"%s"(value);
	else static if (is(T == ubyte[]) || is(T == const(ubyte)[]))
		return "\\x" ~ bytesToHex(value);
	else
		static assert(false, "Unsupported parameter type: " ~ T.stringof);
}

private string bytesToHex(const(ubyte)[] data)
{
	import std.format : format;
	auto result = new char[data.length * 2];
	foreach (i, b; data)
	{
		result[i*2] = "0123456789abcdef"[b >> 4];
		result[i*2+1] = "0123456789abcdef"[b & 0xf];
	}
	return cast(string)result;
}

/// Convert PostgreSQL text format value to D type.
T convertValue(T)(const(char)[] textValue, uint typeOid)
{
	static if (is(T == string))
		return textValue.idup;
	else static if (is(T == const(char)[]))
		return textValue;
	else static if (is(T == int))
		return textValue.to!int;
	else static if (is(T == long))
		return textValue.to!long;
	else static if (is(T == short))
		return textValue.to!short;
	else static if (is(T == double))
		return textValue.to!double;
	else static if (is(T == float))
		return textValue.to!float;
	else static if (is(T == bool))
		return textValue == "t" || textValue == "true" || textValue == "1";
	else static if (is(T == ubyte[]))
		return decodeBytea(textValue);
	else
		static assert(false, "Unsupported type for PostgreSQL conversion: " ~ T.stringof);
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

/// PostgreSQL exception with optional error response fields.
class PgSqlException : Exception
{
	PgSqlConnection.ErrorResponse errorResponse;

	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}

	this(PgSqlConnection.ErrorResponse response, string file = __FILE__, size_t line = __LINE__)
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

// Unit tests for type conversion
debug(ae_unittest) unittest
{
	// Integer conversion
	assert(convertValue!int("42", PgSqlConnection.PgOid.int4) == 42);
	assert(convertValue!int("-123", PgSqlConnection.PgOid.int4) == -123);
	assert(convertValue!long("9223372036854775807", PgSqlConnection.PgOid.int8) == long.max);

	// Float conversion
	import std.math : isClose;
	assert(isClose(convertValue!double("3.14159", PgSqlConnection.PgOid.float8), 3.14159));

	// Boolean conversion
	assert(convertValue!bool("t", PgSqlConnection.PgOid.boolean) == true);
	assert(convertValue!bool("f", PgSqlConnection.PgOid.boolean) == false);
	assert(convertValue!bool("true", PgSqlConnection.PgOid.boolean) == true);
	assert(convertValue!bool("false", PgSqlConnection.PgOid.boolean) == false);

	// String conversion
	assert(convertValue!string("hello", PgSqlConnection.PgOid.text) == "hello");

	// Bytea hex format
	assert(decodeBytea("\\x48454c4c4f") == cast(ubyte[])"HELLO");
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

version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	// Uses environment variables: PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD
	auto pg = new PgSqlConnection();

	int completed;
	enum totalTests = 5;

	void checkDone()
	{
		if (completed == totalTests)
			pg.disconnect("Test complete");
	}

	pg.handleReadyForQuery = (PgSqlConnection.TransactionStatus ts) {
		pg.handleReadyForQuery = null;

		// Test 1: Simple query with .array
		pg.query("SELECT 1 + 1 AS result").array.dmd21804workaround.then((rows) {
			assert(rows.length == 1, "Expected 1 row");
			assert(rows[0].column!int(0) == 2, "Expected 1+1=2");
			assert(rows[0].column!int("result") == 2, "Expected column by name");
			completed++;
			checkDone();
		}).except((Exception e) {
			assert(false, "Query 1 failed: " ~ e.msg);
		});

		// Test 2: Pipelined query (sent before first completes)
		pg.query("SELECT 2 * 3 AS product").array.dmd21804workaround.then((rows) {
			assert(rows.length == 1, "Expected 1 row");
			assert(rows[0].column!int("product") == 6, "Expected 2*3=6");
			completed++;
			checkDone();
		}).except((Exception e) {
			assert(false, "Query 2 failed: " ~ e.msg);
		});

		// Test 3: Another pipelined query with multiple rows
		pg.query("SELECT generate_series(1, 3) AS n").array.dmd21804workaround.then((rows) {
			assert(rows.length == 3, "Expected 3 rows from generate_series");
			assert(rows[0].column!int("n") == 1);
			assert(rows[1].column!int("n") == 2);
			assert(rows[2].column!int("n") == 3);
			completed++;
			checkDone();
		}).except((Exception e) {
			assert(false, "Query 3 failed: " ~ e.msg);
		});

		// Test 4: Prepared statement with parameters
		pg.prepare("SELECT $1::int + $2::int AS sum").dmd21804workaround.then((PgSqlConnection.PreparedStatement stmt) {
			stmt.query(10, 20).array.dmd21804workaround.then((rows) {
				assert(rows.length == 1, "Expected 1 row from prepared stmt");
				assert(rows[0].column!int("sum") == 30, "Expected 10+20=30");
				completed++;
				checkDone();

				// Test 5: Reuse prepared statement with different params
				stmt.query(100, 200).array.dmd21804workaround.then((rows2) {
					assert(rows2.length == 1, "Expected 1 row from reused stmt");
					assert(rows2[0].column!int("sum") == 300, "Expected 100+200=300");
					completed++;
					checkDone();
				}).except((Exception e) {
					assert(false, "Query 5 (reuse) failed: " ~ e.msg);
				});
			}).except((Exception e) {
				assert(false, "Query 4 (prepared) failed: " ~ e.msg);
			});
		}).except((Exception e) {
			assert(false, "Prepare failed: " ~ e.msg);
		});
	};

	pg.handleError = (PgSqlConnection.ErrorResponse err) {
		assert(false, "Connection error: " ~ err.toString());
	};

	socketManager.loop();
	assert(completed == totalTests, "Not all tests completed: " ~ completed.to!string);
}

// Test fiber-based API using await
version (HAVE_PSQL_SERVER)
debug(ae_unittest) unittest
{
	import ae.utils.promise.await : async, await;

	auto pg = new PgSqlConnection();
	bool done;

	// Run tests in a fiber using async
	async({
		// Wait for connection to be ready (replaces handleReadyForQuery callback)
		pg.ready.await;

		// Test 1: Simple query with await
		auto rows1 = pg.query("SELECT 1 + 1 AS result").array.await;
		assert(rows1.length == 1, "Expected 1 row");
		assert(rows1[0].column!int("result") == 2, "Expected 1+1=2");

		// Test 2: Prepared statement with await
		auto stmt = pg.prepare("SELECT $1::int * $2::int AS product").await;
		auto rows2 = stmt.query(6, 7).array.await;
		assert(rows2.length == 1, "Expected 1 row from prepared stmt");
		assert(rows2[0].column!int("product") == 42, "Expected 6*7=42");

		// Test 3: Fiber-based foreach (opApply)
		int sum = 0;
		foreach (row; pg.query("SELECT generate_series(1, 5) AS n"))
			sum += row.column!int("n");
		assert(sum == 15, "Expected sum 1+2+3+4+5=15, got " ~ sum.to!string);

		// Test 4: Prepared statement reuse with foreach
		int product = 1;
		foreach (row; stmt.query(2, 3))
			product *= row.column!int("product");
		assert(product == 6, "Expected 2*3=6");

		done = true;
		pg.disconnect("Fiber test complete");
	});

	socketManager.loop();
	assert(done, "Fiber test did not complete");
}
