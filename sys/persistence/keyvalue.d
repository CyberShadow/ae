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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.persistence.keyvalue;

import std.exception;
import std.traits;

import ae.sys.persistence.core;
import ae.sys.sqlite3;
import ae.utils.array : nonNull;
import ae.utils.json;

// ****************************************************************************

/// Persistent indexed key-value store, backed by an SQLite database.
/// Non-string keys/values are JSON-encoded.
struct KeyValueStore(K, V)
{
	KeyValueDatabase* db; ///
	string tableName; ///

	/// Constructor with `KeyValueDatabase` and `tableName`.
	/// Allows using the same database file for multiple key/value tables.
	this(KeyValueDatabase* db, string tableName = "values")
	{
		this.db = db;
		this.tableName = tableName;
	}

	/// Constructor with file name.
	/// Creates a new `KeyValueDatabase` for private use.
	this(string fn)
	{
		auto db = new KeyValueDatabase(fn);
		this(db);
	}

	/// Implements common D associative array operations.
	V opIndex()(auto ref const K k)
	{
		checkInitialized();
		foreach (SqlType!V v; sqlGet.iterate(toSqlType(k)))
			return fromSqlType!V(v);
		throw new Exception("Value not in KeyValueStore");
	}

	V get()(auto ref const K k, auto ref V defaultValue)
	{
		checkInitialized();
		foreach (SqlType!V v; sqlGet.iterate(toSqlType(k)))
			return fromSqlType!V(v);
		return defaultValue;
	} /// ditto

	V getOrAdd()(auto ref const K k, lazy V defaultValue)
	{
		checkInitialized();
		foreach (SqlType!V v; sqlGet.iterate(toSqlType(k)))
			return fromSqlType!V(v);
		auto v = defaultValue();
		sqlSet.exec(toSqlType(k), toSqlType(v));
		return v;
	} /// ditto

	bool opBinaryRight(string op)(auto ref const K k)
	if (op == "in")
	{
		checkInitialized();
		foreach (int count; sqlExists.iterate(toSqlType(k)))
			return count > 0;
		assert(false);
	} /// ditto

	auto ref const(V) opIndexAssign()(auto ref const V v, auto ref const K k)
	{
		checkInitialized();
		sqlSet.exec(toSqlType(k), toSqlType(v));
		return v;
	} /// ditto

	void remove()(auto ref const K k)
	{
		checkInitialized();
		sqlDelete.exec(toSqlType(k));
	} /// ditto

	@property int length()
	{
		checkInitialized();
		foreach (int count; sqlLength.iterate())
			return count;
		assert(false);
	} /// ditto

	@property K[] keys()
	{
		checkInitialized();
		K[] result;
		foreach (SqlType!K key; sqlListKeys.iterate())
			result ~= fromSqlType!K(key);
		return result;
	}

	int opApply(int delegate(K key, V value) dg)
	{
		checkInitialized();
		foreach (SqlType!K key, SqlType!V value; sqlListPairs.iterate())
		{
			auto res = dg(fromSqlType!K(key), fromSqlType!V(value));
			if (res)
				return res;
		}
		return 0;
	}

private:
	static SqlType!T toSqlType(T)(auto ref T v)
	{
		alias S = SqlType!T;
		static if (is(T : long)) // long
			return v;
		else
		static if (is(T : const(char)[])) // string
			return cast(S) v.nonNull;
		else
		static if (is(T U : U[]) && !hasIndirections!U) // void[]
			return v.nonNull;
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
				assert(v.length == N * V.sizeof, "Static array length mismatch");
				return cast(T) v[0 .. N * V.sizeof];
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
			alias SqlType = const(void)[];
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

	SQLite.PreparedStatement sqlGet, sqlSet, sqlDelete, sqlExists, sqlLength, sqlListKeys, sqlListPairs;

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
			sqlListKeys = db.prepare("SELECT [key] FROM [" ~ tableName ~ "]");
			sqlListPairs = db.prepare("SELECT [key], [value] FROM [" ~ tableName ~ "]");
			initialized = true;
		}
	}
}

/// A `KeyValueDatabase` holds one or more key/value tables (`KeyValueStore`).
struct KeyValueDatabase
{
	string fileName; /// Database file name.

	SQLite sqlite; /// SQLite database instance. Initialized automatically.

	@property SQLite _getSQLite()
	{
		if (sqlite is null)
		{
			enforce(fileName, "KeyValueDatabase filename not set");
			sqlite = new SQLite(fileName);
		}
		return sqlite;
	}

	alias _getSQLite this;
}

unittest
{
	import std.file;

	string fn = tempDir ~ "/ae-sys-persistence-keyvalue-test.s3db";
	if (fn.exists) fn.remove();
	scope(success) fn.remove();

	auto store = KeyValueStore!(string, string)(fn);

	assert(store.length == 0);
	assert("key" !in store);
	assert(store.get("key", null) is null);
	assert(store.keys.length == 0);

	store["key"] = "value";

	assert(store.length == 1);
	assert("key" in store);
	assert(store["key"] == "value");
	assert(store.get("key", null) == "value");
	assert(store.keys == ["key"]);

	store["key"] = "value2";

	assert(store.length == 1);
	assert("key" in store);
	assert(store.get("key", null) == "value2");
	assert(store.keys == ["key"]);

	store["key2"] = "value3";

	assert(store.length == 2);
	assert("key" in store);
	assert("key2" in store);
	assert(store.get("key", null) == "value2");
	assert(store.get("key2", null) == "value3");
	assert(store.keys == ["key", "key2"]);

	store.remove("key");

	assert(store.length == 1);
	assert("key" !in store);
	assert("key2" in store);
	assert(store.get("key", null) is null);
	assert(store.keys == ["key2"]);
}

unittest
{
	if (false)
	{
		KeyValueStore!(string, ubyte[20]) kv;
		ubyte[20] s = kv[""];
	}
}

unittest
{
	if (false)
	{
		KeyValueStore!(string, float[20]) kv;
		float[20] s = kv[""];
	}
}

unittest
{
	if (false)
	{
		struct K {}
		KeyValueStore!(K, K) kv;
		assert(K.init !in kv);
		immutable K ik;
		assert(ik !in kv);
	}
}

unittest
{
	import std.file;

	string fn = tempDir ~ "/ae-sys-persistence-keyvalue-test.s3db";
	if (fn.exists) fn.remove();
	scope(success) fn.remove();

	KeyValueStore!(float[], float[]) kv;
	kv = typeof(kv)(fn);
	assert(null !in kv);
	kv[null] = null;
	assert(null in kv);
	assert(kv[null] == null);
}
