/**
 * ae.sys.persistence.json
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

module ae.sys.persistence.json;

import ae.sys.file : atomicWrite;
import ae.sys.persistence.core;

// ****************************************************************************

/// `FileCache` wrapper which stores a D type as JSON serialization.
template JsonFileCache(T, FlushPolicy flushPolicy = FlushPolicy.none)
{
	import std.file;
	import ae.utils.json;

	static T getJson(T)(string fileName)
	{
		return fileName.readText.jsonParse!T;
	}

	static void putJson(T)(string fileName, in T t)
	{
		atomicWrite(fileName, t.toJson());
	}

	alias JsonFileCache = FileCache!(getJson!T, putJson!T, flushPolicy);
}

version(ae_unittest) unittest
{
	import std.file;

	enum FN = "test1.json";
	std.file.write(FN, "{}");
	scope(exit) remove(FN);

	auto cache = JsonFileCache!(string[string])(FN);
	assert(cache.length == 0);
}

version(ae_unittest) unittest
{
	import std.file;

	enum FN = "test2.json";
	scope(exit) if (FN.exists) remove(FN);

	auto cache = JsonFileCache!(string[string], FlushPolicy.manual)(FN);
	assert(cache.length == 0);
	cache["foo"] = "bar";
	cache.save();

	auto cache2 = JsonFileCache!(string[string])(FN);
	assert(cache2["foo"] == "bar");
}

version(ae_unittest) unittest
{
	import std.file;

	enum FN = "test3.json";
	scope(exit) if (FN.exists) remove(FN);

	{
		auto cache = JsonFileCache!(string[string], FlushPolicy.atScopeExit)(FN);
		cache["foo"] = "bar";
	}

	auto cache2 = JsonFileCache!(string[string])(FN);
	assert(cache2["foo"] == "bar");
}
