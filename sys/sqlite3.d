/**
 * Higher-level wrapper over etc.c.sqlite3
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

module ae.sys.sqlite3;

pragma(lib, "sqlite3");

import etc.c.sqlite3;
import std.exception;
import std.string : toStringz;
import std.conv : to;
import std.traits;
import std.typecons : Nullable;

/// `sqlite3*` wrapper.
final class SQLite
{
	/// C `sqlite3*` object.
	sqlite3* db;

	this(string fn, bool readOnly = false)
	{
		sqenforce(sqlite3_open_v2(toStringz(fn), &db, readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null));
	} ///

	~this() /*@nogc*/
	{
		sqlite3_close(db);
	}

	/// Run a simple query, provided as an SQL string.
	auto query(string sql)
	{
		struct Iterator
		{
			alias int delegate(ref const(char)[][] args, ref const(char)[][] columns) F;

			string sql;
			sqlite3* db;
			F dg;
			int fres;
			Throwable throwable = null;

			int opApply(F dg)
			{
				this.dg = dg;
				auto res = sqlite3_exec(db, toStringz(sql), &callback, &this, null);
				if (res == SQLITE_ABORT)
				{
					if (throwable)
						throw throwable;
					else
						return fres;
				}
				else
				if (res != SQLITE_OK)
					throw new SQLiteException(db, res);
				return 0;
			}

			static /*nothrow*/ extern(C) int callback(void* ctx, int argc, char** argv, char** colv)
			{
				auto i = cast(Iterator*)ctx;
				static const(char)[][] args, cols;
				args.length = cols.length = argc;
				foreach (n; 0..argc)
					args[n] = to!(const(char)[])(argv[n]),
					cols[n] = to!(const(char)[])(colv[n]);
				try
					return i.fres = i.dg(args, cols);
				catch (Exception e)
				{
					i.throwable = e;
					return 1;
				}
			}
		}

		return Iterator(sql, db);
	}

	/// Run a simple query, discarding the result.
	void exec(string sql)
	{
		foreach (cells, columns; query(sql))
			break;
	}

	/// Return the ID of the last inserted row.
	/// (`sqlite3_last_insert_rowid`)
	@property long lastInsertRowID()
	{
		return sqlite3_last_insert_rowid(db);
	}

	/// Return the number of changed rows.
	/// (`sqlite3_changes`)
	@property int changes()
	{
		return sqlite3_changes(db);
	}

	/// `sqlite3_stmt*` wrapper.
	final class PreparedStatement
	{
		private sqlite3_stmt* stmt;

		/// `sqlite3_bind_XXX` wrapper.
		void bind(int idx, int v)
		{
			sqlite3_bind_int(stmt, idx, v);
		}

		void bind(int idx, long v)
		{
			sqlite3_bind_int64(stmt, idx, v);
		} /// ditto

		void bind(int idx, double v)
		{
			sqlite3_bind_double(stmt, idx, v);
		} /// ditto

		void bind(int idx, in char[] v)
		{
			sqlite3_bind_text(stmt, idx, v.ptr, to!int(v.length), SQLITE_TRANSIENT);
		} /// ditto

		void bind(int idx, in wchar[] v)
		{
			sqlite3_bind_text16(stmt, idx, v.ptr, to!int(v.length*2), SQLITE_TRANSIENT);
		} /// ditto

		void bind(int idx, void* n)
		{
			assert(n is null);
			sqlite3_bind_null(stmt, idx);
		} /// ditto

		void bind(int idx, const(void)[] v)
		{
			sqlite3_bind_blob(stmt, idx, v.ptr, to!int(v.length), SQLITE_TRANSIENT);
		} /// ditto

		void bind(T)(int idx, Nullable!T v)
		if (is(typeof(bind(idx, v.get()))))
		{
			if (v.isNull)
				sqlite3_bind_null(stmt, idx);
			else
				bind(v.get());
		} /// ditto

		/// Bind all arguments according to their type, in order.
		void bindAll(T...)(T args)
		{
			foreach (int n, arg; args)
				bind(n+1, arg);
		}

		/// Return "true" if a row is available, "false" if done.
		bool step()
		{
			auto res = sqlite3_step(stmt);
			if (res == SQLITE_DONE)
			{
				reset();
				return false;
			}
			else
			if (res == SQLITE_ROW)
				return true;
			else
			{
				scope(exit) sqlite3_reset(stmt);
				sqenforce(res);
				return false; // only on SQLITE_OK, which shouldn't happen
			}
		}

		/// Calls `sqlite3_reset`.
		void reset()
		{
			sqenforce(sqlite3_reset(stmt));
		}

		/// Binds the given arguments and executes the prepared statement, discarding the result.
		void exec(T...)(T args)
		{
			static if (T.length)
				bindAll!T(args);
			while (step()) {}
		}

		/// Binds the given arguments and executes the prepared statement, returning the results as an iterator.
		static struct Iterator
		{
			PreparedStatement stmt; ///

			@trusted int opApply(U...)(int delegate(ref U args) @system dg)
			{
				int res = 0;
				while (stmt.step())
				{
					scope(failure) stmt.reset();
					static if (U.length == 1 && is(U[0] V : V[]) &&
						!is(U[0] : string) && !is(Unqual!V == void) && !is(V == ubyte))
					{
						U[0] result;
						result.length = stmt.columnCount();
						foreach (int c, ref r; result)
							r = stmt.column!V(c);
						res = dg(result);
					}
					else
					static if (U.length == 1 && is(U[0] V : V[string]))
					{
						U[0] result;
						foreach (c; 0..stmt.columnCount())
							result[stmt.columnName(c)] = stmt.column!V(c);
						res = dg(result);
					}
					else
					{
						U columns;
						stmt.columns(columns);
						res = dg(columns);
					}
					if (res)
					{
						stmt.reset();
						break;
					}
				}
				return res;
			} ///
		}

		/// ditto
		Iterator iterate(T...)(T args)
		{
			static if (T.length)
				bindAll!T(args);
			return Iterator(this);
		}

		/// Returns the value of a column by its index, as the given D type.
		T column(T)(int idx)
		{
			static if (is(T == Nullable!U, U))
				return sqlite3_column_type(stmt, idx) == SQLITE_NULL
					? T.init
					: T(column!U(idx));
			else
			static if (is(T == string))
				return (cast(char*)sqlite3_column_blob(stmt, idx))[0..sqlite3_column_bytes(stmt, idx)].idup;
			else
			static if (is(T V : V[]) && (is(Unqual!V == void) || is(V == ubyte)))
			{
				auto arr = (cast(V*)sqlite3_column_blob(stmt, idx))[0..sqlite3_column_bytes(stmt, idx)];
				static if (isStaticArray!T)
				{
					enforce(arr.length == T.length, "Wrong size for static array column");
					return arr[0..T.length];
				}
				else
					return arr.dup;
			}
			else
			static if (is(T == int))
				return sqlite3_column_int(stmt, idx);
			else
			static if (is(T == long))
				return sqlite3_column_int64(stmt, idx);
			else
			static if (is(T == bool))
				return sqlite3_column_int(stmt, idx) != 0;
			else
			static if (is(T == double))
				return sqlite3_column_double(stmt, idx);
			else
				static assert(0, "Can't get column with type " ~ T.stringof);
		}

		debug(ae_unittest) unittest
		{
			PreparedStatement s;
			if (false)
			{
				s.column!(void[])(0);
				s.column!(ubyte[])(0);
				s.column!(void[16])(0);
				s.column!(ubyte[16])(0);
				s.column!(Nullable!(ubyte[16]))(0);
			}
		}

		/// Returns the value of all columns, as the given D types.
		void columns(T...)(ref T args)
		{
			foreach (i, arg; args)
				args[i] = column!(typeof(arg))(i);
		}

		/// Returns the value of all columns, as an array of the given D type (`string` by default).
		T[] getArray(T=string)()
		{
			T[] result = new T[dataCount()];
			foreach (i, ref value; result)
				value = column!T(i);
			return result;
		}

		/// Returns the value of all columns as an associative array,
		/// with the column names as the key,
		/// and the values with given D type (`string` by default).
		T[string] getAssoc(T=string)()
		{
			T[string] result;
			foreach (i; 0..dataCount())
				result[columnName(i)] = column!T(i);
			return result;
		}

		/// `sqlite3_column_count` wrapper.
		int columnCount()
		{
			return sqlite3_column_count(stmt);
		}

		/// `sqlite3_data_count` wrapper.
		int dataCount()
		{
			return sqlite3_data_count(stmt);
		}

		/// Returns the column name by its index, as a D string.
		string columnName(int idx)
		{
			return to!string(sqlite3_column_name(stmt, idx));
		}

		~this() /*@nogc*/
		{
			sqlite3_finalize(stmt);
		}
	}

	/// Construct a prepared statement.
	PreparedStatement prepare(string sql)
	{
		auto s = new PreparedStatement;
		const(char)* tail;
		auto sqlz = toStringz(sql);
		sqenforce(sqlite3_prepare_v2(db, sqlz, -1, &s.stmt, &tail));
		assert(tail == sqlz + sql.length, "Trailing SQL not compiled: " ~ sql[tail - sqlz .. $]);
		return s;
	}

	private void sqenforce(int res)
	{
		if (res != SQLITE_OK)
			throw new SQLiteException(db, res);
	}
}

/// Exception class thrown on SQLite errors.
class SQLiteException : Exception
{
	int code; ///

	this(sqlite3* db, int code)
	{
		this.code = code;
		super(to!string(sqlite3_errmsg(db)) ~ " (" ~ to!string(code) ~ ")");
	} ///
}
