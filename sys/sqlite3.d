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

	auto exec(string sql)
	{
		struct Iterator
		{
			alias int delegate(ref const(char)[][] args, ref const(char)[][] columns) F;

			string sql;
			sqlite3* db;
			F dg;
			int res;

			int opApply(F dg)
			{
				this.dg = dg;
				auto ret = sqlite3_exec(db, toStringz(sql), &callback, &this, null);
				if (ret == SQLITE_ABORT)
					return res;
				else
				if (ret != SQLITE_OK)
					throw new SQLiteException(db);
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
				return i.res = i.dg(args, cols);
			}
		}

		return Iterator(sql, db);
	}

	private void sqenforce(int res)
	{
		if (res != SQLITE_OK)
			throw new SQLiteException(db);
	}
}

class SQLiteException : Exception
{
	this(sqlite3* db)
	{
		super(to!string(sqlite3_errmsg(db)));
	}
}

