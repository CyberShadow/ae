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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.database;

import std.conv;
import std.exception;
import std.typecons;

import ae.sys.sqlite3;
public import ae.sys.sqlite3 : SQLiteException;
debug(DATABASE) import std.stdio : stderr;

/// A higher-level wrapper around `SQLite`,
/// providing automatic initialization,
/// cached prepared statements,
/// and schema migrations.
struct Database
{
	/// Database file name.
	string dbFileName;

	/// Schema definition, starting with the initial version, and followed by migration instructions.
	/// SQLite `user_version` is used to keep track of the current version.
	/// Successive versions of applications should only extend this array by adding new items at the end.
	string[] schema;

	this(string dbFileName, string[] schema = null)
	{
		this.dbFileName = dbFileName;
		this.schema = schema;
	} ///

	/// Return an `SQLite.PreparedStatement`, caching it.
	SQLite.PreparedStatement stmt(string sql)()
	{
		debug(DATABASE) stderr.writeln(sql);
		static SQLite.PreparedStatement statement = null;
		static Database statementDatabase; // Ensure the statement belongs to the current database
		if (statementDatabase !is this)
		{
			statement = db.prepare(sql).enforce("Statement compilation failed: " ~ sql);
			statementDatabase = this;
		}
		return statement;
	}

	private SQLite.PreparedStatement[const(void)*] cache;

	/// ditto
	SQLite.PreparedStatement stmt(string sql)
	{
		debug(DATABASE) stderr.writeln(sql);
		auto pstatement = sql.ptr in cache;
		if (pstatement)
			return *pstatement;

		auto statement = db.prepare(sql);
		enforce(statement, "Statement compilation failed: " ~ sql);
		return cache[sql.ptr] = statement;
	}

	private struct SQLiteContainer
	{
		typeof(scoped!SQLite(null)) ptr;
	}
	private RefCounted!(SQLiteContainer, RefCountedAutoInitialize.no) instance;

	/// Return a handle to the database, creating it first if necessary.
	@property SQLite db()
	{
		if (instance !is typeof(instance).init)
			return instance.ptr;

		instance = refCounted(SQLiteContainer(scoped!SQLite(dbFileName)));
		scope(failure) instance = typeof(instance).init;

		auto db = &instance.ptr;

		// Protect against locked database due to queries from command
		// line or cron
		db.exec("PRAGMA busy_timeout = 100;");

		if (schema !is null)
		{
			auto userVersion = stmt!"PRAGMA user_version".iterate().selectValue!int;
			if (userVersion != schema.length)
			{
				enforce(userVersion <= schema.length, "Database schema version newer than latest supported by this program!");
				while (userVersion < schema.length)
				{
					auto upgradeInstruction = schema[userVersion];
					db.exec("BEGIN TRANSACTION;");
					db.exec(upgradeInstruction);
					userVersion++;
					db.exec("PRAGMA user_version = " ~ text(userVersion));
					db.exec("COMMIT TRANSACTION;");
				}
			}
		}

		return *db;
	}
}

/// Return the first value of the given iterator.
/// Can be used to select the only value of an SQL query
/// (such as `"SELECT COUNT(*) FROM ..."`).
T selectValue(T, Iter)(Iter iter)
{
	foreach (T val; iter)
		return val;
	throw new Exception("No results for query");
}
