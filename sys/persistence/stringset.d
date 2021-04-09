/**
 * ae.sys.persistence.stringset
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

module ae.sys.persistence.stringset;

import ae.sys.persistence.core;

// ****************************************************************************

// https://issues.dlang.org/show_bug.cgi?id=7016
static import ae.sys.file;

/// A string hashset, stored one line per entry.
struct PersistentStringSet
{
	import ae.utils.aa : HashSet;

	static HashSet!string _load(string fileName)
	{
		import std.file : readText;
		import std.string : splitLines;

		return HashSet!string(fileName.readText().splitLines());
	} ///

	static void _save(string fileName, HashSet!string data)
	{
		import std.array : join;
		import ae.sys.file : atomicWrite;

		atomicWrite(fileName, data.keys.join("\n"));
	} ///

	private alias Cache = FileCache!(_load, _save, FlushPolicy.manual);
	private Cache cache;

	this(string fileName) { cache = Cache(fileName); } ///

	auto opBinaryRight(string op)(string key)
	if (op == "in")
	{
		return key in cache;
	} ///

	void add(string key)
	{
		assert(key !in cache);
		cache.add(key);
		cache.save();
	} ///

	void remove(string key)
	{
		assert(key in cache);
		cache.remove(key);
		cache.save();
	} ///

	@property string[] lines() { return cache.keys; } ///
	@property size_t length() { return cache.length; } ///
}

///
unittest
{
	import std.file, std.conv, core.thread;

	enum FN = "test.txt";
	if (FN.exists) remove(FN);
	scope(exit) if (FN.exists) remove(FN);

	{
		auto s = PersistentStringSet(FN);
		assert("foo" !in s);
		assert(s.length == 0);
		s.add("foo");
	}
	{
		auto s = PersistentStringSet(FN);
		assert("foo" in s);
		assert(s.length == 1);
		s.remove("foo");
	}
	{
		auto s = PersistentStringSet(FN);
		assert("foo" !in s);
		Thread.sleep(filesystemTimestampGranularity);
		std.file.write(FN, "foo\n");
		assert("foo" in s);
		Thread.sleep(filesystemTimestampGranularity);
		std.file.write(FN, "bar\n");
		assert(s.lines == ["bar"], text(s.lines));
	}
}
