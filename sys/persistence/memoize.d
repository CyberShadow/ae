/**
 * ae.sys.persistence.memoize
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

module ae.sys.persistence.memoize;

import ae.sys.persistence.core;
import ae.sys.persistence.json;

// ****************************************************************************

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
static import ae.utils.json;

/// std.functional.memoize variant with automatic persistence
struct PersistentMemoized(alias fun, FlushPolicy flushPolicy = FlushPolicy.atThreadExit)
{
	import std.traits;
	import std.typecons;
	import ae.utils.json;

	alias ReturnType!fun[string] AA;
	private JsonFileCache!(AA, flushPolicy) memo;

	this(string fileName) { memo.fileName = fileName; }

	ReturnType!fun opCall(ParameterTypeTuple!fun args)
	{
		string key;
		static if (args.length==1 && is(typeof(args[0]) : string))
			key = args[0];
		else
			key = toJson(tuple(args));
		auto p = key in memo;
		if (p) return *p;
		auto r = fun(args);
		return memo[key] = r;
	}
}

unittest
{
	import std.file;

	static int value = 42;
	int getValue(int x) { return value; }

	enum FN = "test4.json";
	scope(exit) if (FN.exists) remove(FN);

	{
		auto getValueMemoized = PersistentMemoized!(getValue, FlushPolicy.atScopeExit)(FN);

		assert(getValueMemoized(1) == 42);
		value = 24;
		assert(getValueMemoized(1) == 42);
		assert(getValueMemoized(2) == 24);
	}

	value = 0;

	{
		auto getValueMemoized = PersistentMemoized!(getValue, FlushPolicy.atScopeExit)(FN);
		assert(getValueMemoized(1) == 42);
		assert(getValueMemoized(2) == 24);
	}
}
