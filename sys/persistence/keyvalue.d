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
import std.traits;

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
		foreach (SqlType!V v; sqlGet.iterate(toSqlType(k)))
			return fromSqlType!V(v);
		throw new Exception("Value not in KeyValueStore");
	}

	V get()(auto ref K k, auto ref V defaultValue)
	{
		checkInitialized();
		foreach (SqlType!V v; sqlGet.iterate(toSqlType(k)))
			return fromSqlType!V(v);
		return defaultValue;
	}

	V getOrAdd()(auto ref K k, lazy V defaultValue)
	{
		checkInitialized();
		foreach (SqlType!V v; sqlGet.iterate(toSqlType(k)))
			return fromSqlType!V(v);
		auto v = defaultValue();
		sqlSet.exec(toSqlType(k), toSqlType(v));
		return v;
	}

	bool opBinaryRight(string op)(auto ref K k)
	if (op == "in")
	{
		checkInitialized();
		foreach (int count; sqlExists.iterate(toSqlType(k)))
			return count > 0;
		assert(false);
	}

	auto ref V opIndexAssign()(auto ref V v, auto ref K k)
	{
		checkInitialized();
		sqlSet.exec(toSqlType(k), toSqlType(v));
		return v;
	}

	void remove()(auto ref K k)
	{
		checkInitialized();
		sqlDelete.exec(toSqlType(k));
	}

	@property int length()
	{
		checkInitialized();
		foreach (int count; sqlLength.iterate())
			return count;
		assert(false);
	}

private:
	static SqlType!T toSqlType(T)(auto ref T v)
	{
		alias S = SqlType!T;
		static if (is(T : long)) // long
			return v;
		else
		static if (is(T : const(char)[])) // string
			return cast(S) v;
		else
		static if (is(T U : U[]) && !hasIndirections!U) // void[]
			return v;
		else
			return toJson(v);
	}

	static T fromSqlType(T)(SqlType!T v)
	{
		static if (is(T : long)) // long
			return cast(T) v;
		else
		static if (is(T : const(char)[])) // string
			return cast(T) v;
		else
		static if (is(T U : U[]) && !hasIndirections!U) // void[]
			static if (is(T V : V[N], size_t N))
			{
				assert(v.length == N, "Static array length mismatch");
				return cast(T) v[0..N];
			}
			else
				return cast(T) v;
		else
			return jsonParse!T(cast(string) v);
	}

	template SqlType(T)
	{
		static if (is(T : long))
			alias SqlType = long;
		else
		static if (is(T : const(char)[]))
			alias SqlType = string;
		else
		static if (is(T U : U[]) && !hasIndirections!U)
			alias SqlType = void[];
		else
			alias SqlType = string; // JSON-encoded
	}

	static assert(is(SqlType!int == long));
	static assert(is(SqlType!string == string));

	template sqlTypeName(T)
	{
		alias S = SqlType!T;
		static if (is(S == long))
			enum sqlTypeName = "INTEGER";
		else
		static if (is(S == string))
			enum sqlTypeName = "TEXT";
		else
		static if (is(S == void[]))
			enum sqlTypeName = "BLOB";
		else
			enum sqlTypeName = "TEXT"; // JSON
	}

	bool initialized;

	SQLite.PreparedStatement sqlGet, sqlSet, sqlDelete, sqlExists, sqlLength;

	void checkInitialized()
	{
		if (!initialized)
		{
			assert(db, "KeyValueStore database not set");
			db.exec("CREATE TABLE IF NOT EXISTS [" ~ tableName ~ "] ([key] " ~ sqlTypeName!K ~ " PRIMARY KEY, [value] " ~ sqlTypeName!V ~ ")");
			db.exec("PRAGMA SYNCHRONOUS=OFF");
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
	assert(store["key"] == "value");
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

unittest
{
	if (false)
	{
		KeyValueStore!(string, ubyte[20]) kv;
		ubyte[20] s = kv[""];
	}
}
