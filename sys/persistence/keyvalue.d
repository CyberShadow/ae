/**
 * ae.sys.persistence.keyvalue
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

module ae.sys.persistence.keyvalue;

import std.exception;

import ae.sys.persistence.core;
import ae.sys.sqlite3;
import ae.utils.json;

// ****************************************************************************

/// Persistent indexed key-value store, backed by an SQLite database.
/// Non-string keys/values are JSON-encoded.
struct KeyValueStore(K, V)
{
	KeyValueDatabase* db;
	string tableName;

	this(KeyValueDatabase* db, string tableName = "values")
	{
		this.db = db;
		this.tableName = tableName;
	}

	this(string fn)
	{
		auto db = new KeyValueDatabase(fn);
		this(db);
	}

	V opIndex()(auto ref K k)
	{
		checkInitialized();
		foreach (string s; sqlGet.iterate(toStr(k)))
			return fromStr!V(s);
		throw new Exception("Value not in KeyValueStore");
	}

	V get()(auto ref K k, auto ref V defaultValue)
	{
		checkInitialized();
		foreach (string s; sqlGet.iterate(toStr(k)))
			return fromStr!V(s);
		return defaultValue;
	}

	bool opIn_r()(auto ref K k)
	{
		checkInitialized();
		foreach (int count; sqlExists.iterate(toStr(k)))
			return count > 0;
		assert(false);
	}

	void opIndexAssign()(auto ref V v, auto ref K k)
	{
		checkInitialized();
		sqlSet.exec(toStr(k), toStr(v));
	}

	void remove()(auto ref K k)
	{
		checkInitialized();
		sqlDelete.exec(toStr(k));
	}

	@property int length()
	{
		checkInitialized();
		foreach (int count; sqlLength.iterate())
			return count;
		assert(false);
	}

private:
	static string toStr(T)(auto ref T v)
	{
		static if (is(T == string))
			return v;
		else
			return toJson(v);
	}

	static T fromStr(T)(string s)
	{
		static if (is(T == string))
			return s;
		else
			return jsonParse(s);
	}

	template sqlType(T)
	{
		static if (is(T : long))
			enum sqlType = "INTEGER";
		else
			enum sqlType = "BLOB";
	}

	bool initialized;

	SQLite.PreparedStatement sqlGet, sqlSet, sqlDelete, sqlExists, sqlLength;

	void checkInitialized()
	{
		if (!initialized)
		{
			assert(db, "KeyValueStore database not set");
			db.exec("CREATE TABLE IF NOT EXISTS [" ~ tableName ~ "] ([key] " ~ sqlType!K ~ " PRIMARY KEY, [value] " ~ sqlType!V ~ ")");
			sqlGet = db.prepare("SELECT [value] FROM [" ~ tableName ~ "] WHERE [key]=?");
			sqlSet = db.prepare("INSERT OR REPLACE INTO [" ~ tableName ~ "] VALUES (?, ?)");
			sqlDelete = db.prepare("DELETE FROM [" ~ tableName ~ "] WHERE [key]=?");
			sqlExists = db.prepare("SELECT COUNT(*) FROM [" ~ tableName ~ "] WHERE [key]=? LIMIT 1");
			sqlLength = db.prepare("SELECT COUNT(*) FROM [" ~ tableName ~ "]");
			initialized = true;
		}
	}
}

struct KeyValueDatabase
{
	string fileName;

	SQLite sqlite;

	@property SQLite getSQLite()
	{
		if (sqlite is null)
		{
			enforce(fileName, "KeyValueDatabase filename not set");
			sqlite = new SQLite(fileName);
		}
		return sqlite;
	}

	alias getSQLite this;
}

unittest
{
	import std.file;

	string fn = tempDir ~ "/ae-sys-persistence-keyvalue-test.s3db";
	if (fn.exists) fn.remove();
	//scope(exit) if (fn.exists) fn.remove();
	auto store = KeyValueStore!(string, string)(fn);

	assert(store.length == 0);
	assert("key" !in store);
	assert(store.get("key", null) is null);

	store["key"] = "value";

	assert(store.length == 1);
	assert("key" in store);
	assert(store.get("key", null) == "value");

	store["key"] = "value2";

	assert(store.length == 1);
	assert("key" in store);
	assert(store.get("key", null) == "value2");

	store["key2"] = "value3";

	assert(store.length == 2);
	assert("key" in store);
	assert("key2" in store);
	assert(store.get("key", null) == "value2");
	assert(store.get("key2", null) == "value3");

	store.remove("key");

	assert(store.length == 1);
	assert("key" !in store);
	assert("key2" in store);
	assert(store.get("key", null) is null);
}
