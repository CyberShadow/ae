/**
 * Common parts of the database drivers (`ae.net.db.psql`,
 * `ae.net.db.mysql`, `ae.net.db.sqlite`): typed statement parameters,
 * result rows and lazy query results, and the drivers' base exception.
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

module ae.net.db.common;

import std.conv : to;
import std.exception : enforce;
import std.typecons : Nullable;

import ae.utils.promise;

// https://issues.dlang.org/show_bug.cgi?id=7016
static import ae.utils.promise.await;

/// Base class of the database drivers' exceptions.
class DbException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

/// A parameter of a statement: a typed value, which each driver sends
/// natively (e.g. PostgreSQL: with its type OID; MySQL: with its
/// binary-protocol type; SQLite: with the bind function of its type).
struct Param
{
	/// The parameter's type (the default value is NULL).
	enum Type : ubyte
	{
		null_,
		boolean,
		integer,
		floating,
		numeric,  /// an exact number, as its decimal text
		text,     /// a string (whose type the server may infer from the context, see the drivers)
		bytes,
		array,    /// an array of parameters (PostgreSQL)
	}

	Type type; ///
	bool boolean; ///
	long integer; ///
	double floating = 0; ///
	string text; /// of `numeric` and `text`
	immutable(ubyte)[] bytes; ///
	const(Param)[] elements; /// of `array`

	/// The parameter of the D value `value`: `null`, a `Nullable`, a
	/// boolean, an integer, a floating-point number, a string, a byte
	/// array, or a `Param`.
	static Param of(T)(T value)
	{
		import std.traits : isFloatingPoint, isIntegral, isSomeString, Unqual;
		alias U = Unqual!T;
		Param p;
		static if (is(U == typeof(null)))
			{}
		else static if (is(U == Param))
			p = value;
		else static if (is(U == Nullable!V, V))
		{
			if (!value.isNull)
				p = of(value.get);
		}
		else static if (is(U == bool))
		{
			p.type = Type.boolean;
			p.boolean = value;
		}
		else static if (isIntegral!U)
		{
			static if (is(U == ulong))
				enforce!DbException(value <= long.max, "Integer parameter out of range");
			p.type = Type.integer;
			p.integer = value;
		}
		else static if (isFloatingPoint!U)
		{
			p.type = Type.floating;
			p.floating = value;
		}
		else static if (is(U : const(ubyte)[]))
		{
			p.type = Type.bytes;
			p.bytes = value.idup;
		}
		else static if (isSomeString!U)
		{
			p.type = Type.text;
			p.text = value.to!string;
		}
		else
			static assert(false, "Unsupported parameter type: " ~ T.stringof);
		return p;
	}

	/// An exact number, given as its decimal text (e.g. "1.50").
	static Param numeric(string decimal)
	{
		Param p;
		p.type = Type.numeric;
		p.text = decimal;
		return p;
	}

	/// An array of the parameters `elements`.
	static Param array(const(Param)[] elements)
	{
		Param p;
		p.type = Type.array;
		p.elements = elements;
		return p;
	}

	/// Whether the parameter is NULL.
	@property bool isNull() const { return type == Type.null_; }

	/// The value as text (as SQL writes it; null: NULL): of a boolean,
	/// "true" or "false"; of a floating-point number, with all its
	/// significant digits. (Not of byte arrays and arrays, whose text
	/// depends on the driver.)
	const(char)[] toText() const
	{
		import std.format : format;
		final switch (type)
		{
			case Type.null_: return null;
			case Type.boolean: return boolean ? "true" : "false";
			case Type.integer: return integer.to!string;
			case Type.floating: return format!"%.17g"(floating);
			case Type.numeric:
			case Type.text: return text is null ? "" : text;
			case Type.bytes:
			case Type.array: assert(false, "No common text of a parameter of type " ~ type.to!string);
		}
	}
}

/// The parameters of the D values `args` (see `Param.of`).
const(Param)[] toParams(Args...)(Args args)
{
	Param[] result;
	foreach (arg; args)
		result ~= Param.of(arg);
	return result;
}

/// The bytes of a value in text format, as they are.
ubyte[] rawBytes(const(char)[] text)
{
	return cast(ubyte[]) text.dup;
}

/// Convert a value in text format to the D type `T`: a string, an integer
/// or floating-point number, a boolean ("t", "true" or "1"), or (with
/// `decodeBytes`) a byte array.
T convertText(T, alias decodeBytes = rawBytes)(const(char)[] text)
{
	import std.traits : isFloatingPoint, isIntegral;
	static if (is(T == string))
		return text.idup;
	else static if (is(T == const(char)[]))
		return text;
	else static if (is(T == bool))
		return text == "t" || text == "true" || text == "1";
	else static if (isIntegral!T || isFloatingPoint!T)
		return text.to!T;
	else static if (is(T == ubyte[]))
		return decodeBytes(text);
	else
		static assert(false, "Unsupported column type: " ~ T.stringof);
}

/// A row of a query's result: the values of its columns in text format
/// (null: NULL), which `column` converts (see `convertText`; byte arrays
/// with `decodeBytes`).
struct Row(alias decodeBytes = rawBytes)
{
	private const(string)[] names;
	private const(const(char)[])[] values;
	private const(bool)[] nulls;

	/// A row of the values `values` (null: NULL, see `nulls`) of the
	/// columns `names`.
	this(const(string)[] names, const(const(char)[])[] values, const(bool)[] nulls)
	{
		this.names = names;
		this.values = values;
		this.nulls = nulls;
	}

	/// The value of the column `idx` (or of the column named `name`), as
	/// the type `T` (a `Nullable` for a column which may be NULL).
	T column(T)(size_t idx) const
	{
		enforce!DbException(idx < values.length, "Column index out of range");
		static if (is(T == Nullable!U, U))
		{
			if (nulls[idx])
				return T.init;
			return T(column!U(idx));
		}
		else
		{
			enforce!DbException(!nulls[idx], "NULL value for non-nullable column");
			return convertText!(T, decodeBytes)(values[idx]);
		}
	}

	/// ditto
	T column(T)(const(char)[] name) const
	{
		return column!T(columnIndex(name));
	}

	/// Whether the value of the column `idx` (or of the column named
	/// `name`) is NULL.
	bool isNull(size_t idx) const
	{
		enforce!DbException(idx < nulls.length, "Column index out of range");
		return nulls[idx];
	}

	/// ditto
	bool isNull(const(char)[] name) const
	{
		return isNull(columnIndex(name));
	}

	/// The number of columns.
	size_t length() const
	{
		return values.length;
	}

	/// The names of the columns.
	@property const(string)[] columnNames() const
	{
		return names;
	}

	private size_t columnIndex(const(char)[] name) const
	{
		foreach (i, n; names)
			if (n == name)
				return i;
		throw new DbException("Unknown column: " ~ name.idup);
	}
}

/// The lazy result of a query: the query is sent when the result is first
/// consumed, once, with `array`, `map` or `foreach` (in a fiber).
final class Result(Row)
{
	/// A result whose query `start` sends (when the result is consumed);
	/// the driver then reports the query's columns, rows and completion
	/// (or error) to it.
	package(ae.net.db) this(void delegate(Result) start)
	{
		this.start = start;
	}

	/// Collect all rows.
	Promise!(Row[]) array()
	{
		consume();
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

	/// Map `fn` over the rows as they arrive, collecting the results.
	Promise!(T[]) map(T)(T delegate(Row) fn)
	{
		consume();
		auto resultPromise = new Promise!(T[]);
		if (error)
		{
			resultPromise.reject(error);
			return resultPromise;
		}
		T[] results;
		if (completed)
		{
			foreach (row; bufferedRows)
				results ~= fn(row);
			resultPromise.fulfill(results);
			return resultPromise;
		}
		rowCallback = (Row row) { results ~= fn(row); };
		arrayPromise = new Promise!(Row[]);
		arrayPromise.then((Row[] _) {
			resultPromise.fulfill(results);
		}).except((Exception e) {
			resultPromise.reject(e);
		});
		startIfNeeded();
		return resultPromise;
	}

	/// Iterate the rows as they arrive (in a fiber).
	int opApply(scope int delegate(Row) dg)
	{
		import ae.utils.promise.await : await;

		consume();
		if (error)
			throw error;
		if (completed)
		{
			foreach (row; bufferedRows)
				if (auto r = dg(row))
					return r;
			return 0;
		}

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
				break;
			if (auto r = dg(item.get))
				return r;
		}
		return 0;
	}

	/// The number of rows the query affected (e.g. of an INSERT, UPDATE
	/// or DELETE), once it completed.
	@property ulong affectedRows() const { return affected; }

	/// The ID of the row the query inserted (MySQL: `LAST_INSERT_ID()`;
	/// SQLite: the row ID), once it completed; 0 if none.
	@property ulong lastInsertId() const { return insertId; }

	// ---- For the drivers ----

	/// The query's (next) result set has the columns `names`.
	package(ae.net.db) void onColumns(const(string)[] names)
	{
		columnNames = names;
	}

	/// The query's result set has the row of the values `values` (null:
	/// NULL, see `nulls`).
	package(ae.net.db) void onRow(const(const(char)[])[] values, const(bool)[] nulls)
	{
		auto row = Row(columnNames, values, nulls);
		if (iterating)
			iterQueue.fulfillOne(Nullable!Row(row));
		else if (rowCallback)
			rowCallback(row);
		else
			bufferedRows ~= row;
	}

	/// The query affected `affectedRows` rows (and inserted the row
	/// `lastInsertId`) (of a query of several statements: the last one).
	package(ae.net.db) void onAffected(ulong affectedRows, ulong lastInsertId = 0)
	{
		affected = affectedRows;
		if (lastInsertId)
			insertId = lastInsertId;
	}

	/// The query completed.
	package(ae.net.db) void onComplete()
	{
		if (completed)
			return;
		completed = true;
		if (arrayPromise)
			arrayPromise.fulfill(bufferedRows);
		if (iterating)
			iterQueue.fulfillOne(Nullable!Row.init);
	}

	/// The query failed with `e`.
	package(ae.net.db) void onError(Exception e)
	{
		if (completed)
			return;
		error = e;
		completed = true;
		if (arrayPromise)
			arrayPromise.reject(e);
		if (iterating)
			iterQueue.fulfillOne(Nullable!Row.init);
	}

private:
	void delegate(Result) start;
	bool started, completed, consumed;
	Exception error;
	const(string)[] columnNames;
	ulong affected, insertId;
	Row[] bufferedRows;
	Promise!(Row[]) arrayPromise;
	void delegate(Row) rowCallback;
	bool iterating;
	PromiseQueue!(Nullable!Row) iterQueue;

	void consume()
	{
		enforce!DbException(!consumed, "Result has already been consumed");
		consumed = true;
	}

	void startIfNeeded()
	{
		if (!started)
		{
			started = true;
			start(this);
		}
	}
}

/// The parts of a `postgresql://` or `mysql://` URI
/// (`scheme://user:password@host:port/database?name=value&...`, the user,
/// password, database and parameters percent-encoded; all but the host
/// optional).
struct DbUri
{
	string user, password, host, database;
	Nullable!ushort port;
	string[string] parameters; /// The query parameters

	/// Parse `uri`, whose scheme must be one of `schemes`.
	static DbUri parse(string uri, const(string)[] schemes)
	{
		import std.algorithm.iteration : splitter;
		import std.algorithm.searching : canFind, findSplit;
		import std.uri : decodeComponent;

		auto scheme = uri.findSplit("://");
		enforce!DbException(scheme[1].length && schemes.canFind(scheme[0]),
			"Invalid connection URI: must start with " ~ schemes[0] ~ "://");
		DbUri result;
		auto query = scheme[2].findSplit("?");
		auto rest = query[0];
		if (query[1].length)
			foreach (parameter; query[2].splitter("&"))
				if (parameter.length)
				{
					auto nameValue = parameter.findSplit("=");
					result.parameters[decodeComponent(nameValue[0])] = decodeComponent(nameValue[2]);
				}
		auto credentials = rest.findSplit("@");
		string hostPart = rest;
		if (credentials[1].length)
		{
			hostPart = credentials[2];
			auto userPassword = credentials[0].findSplit(":");
			result.user = decodeComponent(userPassword[0]);
			result.password = userPassword[1].length ? decodeComponent(userPassword[2]) : null;
		}
		auto path = hostPart.findSplit("/");
		if (path[1].length)
			result.database = decodeComponent(path[2]);
		auto hostPort = path[0].findSplit(":");
		result.host = hostPort[0];
		if (hostPort[1].length)
			result.port = hostPort[2].to!ushort;
		return result;
	}
}

debug(ae_unittest) unittest
{
	auto u = DbUri.parse("postgresql://us%40er:p%3Ass@db.example:6543/my%20db", ["postgresql", "postgres"]);
	assert(u.user == "us@er" && u.password == "p:ss" && u.host == "db.example" && u.port.get == 6543 &&
		u.database == "my db");
	u = DbUri.parse("postgres://localhost", ["postgresql", "postgres"]);
	assert(u.host == "localhost" && u.port.isNull && u.user is null && u.password is null && u.database is null);
	assert(!u.parameters.length);
	u = DbUri.parse("postgresql://h:1/d?sslmode=verify-full&sslrootcert=%2Ftmp%2Fca.crt", ["postgresql"]);
	assert(u.host == "h" && u.port.get == 1 && u.database == "d");
	assert(u.parameters == ["sslmode": "verify-full", "sslrootcert": "/tmp/ca.crt"]);
	u = DbUri.parse("mysql://root@h/d", ["mysql"]);
	assert(u.user == "root" && u.password is null && u.host == "h" && u.database == "d");
	import std.exception : assertThrown;
	assertThrown!DbException(DbUri.parse("http://h", ["mysql"]));
}

debug(ae_unittest) unittest
{
	// Parameters
	assert(Param.of(null).isNull && Param.of(Nullable!int.init).isNull);
	assert(Param.of(Nullable!int(3)).type == Param.Type.integer && Param.of(3).integer == 3);
	assert(Param.of(true).toText == "true" && Param.of(-5L).toText == "-5");
	assert(Param.of(0.1).toText == "0.10000000000000001");
	assert(Param.of("x").toText == "x" && Param.of("").toText !is null);
	assert(Param.numeric("1.50").toText == "1.50");
	assert(toParams(1, "a", null).length == 3);

	// Rows
	alias R = Row!();
	auto row = R(["a", "b", "c"], ["42", null, "t"], [false, true, false]);
	assert(row.column!int("a") == 42 && row.column!string(0) == "42" && row.isNull("b"));
	assert(row.column!(Nullable!long)("b").isNull && row.column!bool("c"));
	assert(row.length == 3 && row.columnNames == ["a", "b", "c"]);
	import std.exception : assertThrown;
	assertThrown!DbException(row.column!int("b"));
	assertThrown!DbException(row.column!int("d"));
}

debug(ae_unittest) unittest
{
	// Results: rows reported before or after the result is consumed
	alias R = Row!();
	auto r = new Result!R((Result!R res) {
		res.onColumns(["n"]);
		res.onRow(["1"], [false]);
		res.onRow(["2"], [false]);
		res.onAffected(2);
		res.onComplete();
	});
	R[] rows;
	r.array.then((R[] rs) { rows = rs; });
	import ae.net.asockets : socketManager;
	socketManager.loop();
	assert(rows.length == 2 && rows[1].column!int("n") == 2 && r.affectedRows == 2);
}
