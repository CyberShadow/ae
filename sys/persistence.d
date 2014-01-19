/**
 * A simple wrapper to automatically load and save a value.
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

module ae.sys.persistence;

struct Persistent(T, string filename)
{
	static T value;
	alias value this;

	import ae.utils.json;
	import std.file;

	shared static this()
	{
		if (filename.exists)
			value = jsonParse!T(filename.readText());
	}

	shared static ~this()
	{
		std.file.write(filename, toJson(value));
	}
}

/// std.functional.memoize variant with automatic persistence
template persistentMemoize(alias fun, string filename)
{
	import std.traits;
	import std.typecons;
	import ae.utils.json;

	ReturnType!fun persistentMemoize(ParameterTypeTuple!fun args)
	{
		alias ReturnType!fun[string] AA;
		static Persistent!(AA, filename) memo;
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
