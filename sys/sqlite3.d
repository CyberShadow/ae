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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.sqlite3;

pragma(lib, "sqlite3");

import etc.c.sqlite3;
import std.string : toStringz;
import std.conv : to;

final class SQLite
{
	private sqlite3* db;

	this(string fn)
	{
		sqenforce(sqlite3_open(toStringz(fn), &db));
	}

	~this()
	{
		sqlite3_close(db);
	}

	auto query(string sql)
	{
		struct Iterator
		{
			alias int delegate(ref const(char)[][] args, ref const(char)[][] columns) F;

			string sql;
			sqlite3* db;
			F dg;
			int fres;

			int opApply(F dg)
			{
				this.dg = dg;
				auto res = sqlite3_exec(db, toStringz(sql), &callback, &this, null);
				if (res == SQLITE_ABORT)
					return fres;
				else
				if (res != SQLITE_OK)
					throw new SQLiteException(db, res);
				return 0;
			}

			static extern(C) int callback(void* ctx, int argc, char** argv, char** colv)
			{
				auto i = cast(Iterator*)ctx;
				static const(char)[][] args, cols;
				args.length = cols.length = argc;
				foreach (n; 0..argc)
					args[n] = to!(const(char)[])(argv[n]),
					cols[n] = to!(const(char)[])(colv[n]);
				return i.fres = i.dg(args, cols);
			}
		}

		return Iterator(sql, db);
	}

	void exec(string sql)
	{
		foreach (cells, columns; query(sql))
			break;
	}

	@property long lastInsertRowID()
	{
		return sqlite3_last_insert_rowid(db);
	}

	final class PreparedStatement
	{
		sqlite3_stmt* stmt;

		void bind(int idx, int v)
		{
			sqlite3_bind_int(stmt, idx, v);
		}

		void bind(int idx, long v)
		{
			sqlite3_bind_int64(stmt, idx, v);
		}

		void bind(int idx, double v)
		{
			sqlite3_bind_double(stmt, idx, v);
		}

		void bind(int idx, in char[] v)
		{
			sqlite3_bind_text(stmt, idx, v.ptr, to!int(v.length), SQLITE_TRANSIENT);
		}

		void bind(int idx, in wchar[] v)
		{
			sqlite3_bind_text16(stmt, idx, v.ptr, to!int(v.length*2), SQLITE_TRANSIENT);
		}

		void bind(int idx, void* n)
		{
			assert(n is null);
			sqlite3_bind_null(stmt, idx);
		}

		void bind(int idx, in ubyte[] v)
		{
			sqlite3_bind_blob(stmt, idx, v.ptr, to!int(v.length), SQLITE_TRANSIENT);
		}

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
				sqlite3_reset(stmt);
				sqenforce(res);
				return false; // only on SQLITE_OK, which shouldn't happen
			}
		}

		void reset()
		{
			sqenforce(sqlite3_reset(stmt));
		}

		void exec(T...)(T args)
		{
			static if (T.length)
				bindAll!T(args);
			while (step()) {}
		}

		static struct Iterator
		{
			PreparedStatement stmt;

			@trusted int opApply(U...)(int delegate(ref U args) @system dg)
			{
				int res = 0;
				while (stmt.step())
				{
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
			}
		}

		Iterator iterate(T...)(T args)
		{
			static if (T.length)
				bindAll!T(args);
			return Iterator(this);
		}

		T column(T)(int idx)
		{
			static if (is(T == string))
				return (cast(char*)sqlite3_column_blob(stmt, idx))[0..sqlite3_column_bytes(stmt, idx)].idup;
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

		void columns(T...)(ref T args)
		{
			foreach (i, arg; args)
				args[i] = column!(typeof(arg))(i);
		}

		T[] getArray(T=string)()
		{
			T[] result = new T[dataCount()];
			foreach (i, ref value; result)
				value = column!T(i);
			return result;
		}

		T[string] getAssoc(T=string)()
		{
			T[string] result;
			foreach (i; 0..dataCount())
				result[columnName(i)] = column!T(i);
			return result;
		}

		int columnCount()
		{
			return sqlite3_column_count(stmt);
		}

		int dataCount()
		{
			return sqlite3_data_count(stmt);
		}

		string columnName(int idx)
		{
			return to!string(sqlite3_column_name(stmt, idx));
		}

		~this()
		{
			sqlite3_finalize(stmt);
		}
	}

	PreparedStatement prepare(string sql)
	{
		auto s = new PreparedStatement;
		sqenforce(sqlite3_prepare_v2(db, toStringz(sql), -1, &s.stmt, null));
		return s;
	}

	private void sqenforce(int res)
	{
		if (res != SQLITE_OK)
			throw new SQLiteException(db, res);
	}
}

class SQLiteException : Exception
{
	int code;

	this(sqlite3* db, int code)
	{
		this.code = code;
		super(to!string(sqlite3_errmsg(db)));
	}
}

