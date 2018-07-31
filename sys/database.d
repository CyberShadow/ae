/**
 * Higher-level wrapper around ae.sys.sqlite3.
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

module ae.sys.database;

import std.conv;
import std.exception;

import ae.sys.sqlite3;
public import ae.sys.sqlite3 : SQLiteException;
debug(DATABASE) import std.stdio : stderr;

struct Database
{
	string dbFileName;
	string[] schema;

	this(string dbFileName, string[] schema = null)
	{
		this.dbFileName = dbFileName;
		this.schema = schema;
	}

	SQLite.PreparedStatement stmt(string sql)()
	{
		debug(DATABASE) stderr.writeln(sql);
		static SQLite.PreparedStatement statement = null;
		if (!statement)
			statement = db.prepare(sql).enforce("Statement compilation failed: " ~ sql);
		return statement;
	}

	SQLite.PreparedStatement stmt(string sql)
	{
		debug(DATABASE) stderr.writeln(sql);
		static SQLite.PreparedStatement[const(void)*] cache;
		auto pstatement = sql.ptr in cache;
		if (pstatement)
			return *pstatement;

		auto statement = db.prepare(sql);
		enforce(statement, "Statement compilation failed: " ~ sql);
		return cache[sql.ptr] = statement;
	}

	private SQLite instance;

	@property SQLite db()
	{
		if (instance)
			return instance;

		instance = new SQLite(dbFileName);
		scope(failure) instance = null;

		// Protect against locked database due to queries from command
		// line or cron
		instance.exec("PRAGMA busy_timeout = 100;");

		if (schema !is null)
		{
			auto userVersion = stmt!"PRAGMA user_version".iterate().selectValue!int;
			if (userVersion != schema.length)
			{
				enforce(userVersion <= schema.length, "Database schema version newer than latest supported by this program!");
				foreach (upgradeInstruction; schema[userVersion..$])
					instance.exec(upgradeInstruction);
				instance.exec("PRAGMA user_version = " ~ text(schema.length));
			}
		}

		return instance;
	}
}

T selectValue(T, Iter)(Iter iter)
{
	foreach (T val; iter)
		return val;
	throw new Exception("No results for query");
}
