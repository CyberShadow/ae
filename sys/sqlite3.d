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
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2009-2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
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

/// Higher-level wrapper over etc.c.sqlite3
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
			sqlite3_bind_text(stmt, idx, v.ptr, v.length, SQLITE_TRANSIENT);
		}

		void bind(int idx, in wchar[] v)
		{
			sqlite3_bind_text16(stmt, idx, v.ptr, v.length*2, SQLITE_TRANSIENT);
		}

		void bind(int idx, void* n)
		{
			assert(n is null);
			sqlite3_bind_null(stmt, idx);
		}

		void bind(int idx, in ubyte[] v)
		{
			sqlite3_bind_blob(stmt, idx, v.ptr, v.length, SQLITE_TRANSIENT);
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

		int columnCount()
		{
			return sqlite3_column_count(stmt);
		}

		int dataCount()
		{
			return sqlite3_data_count(stmt);
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

