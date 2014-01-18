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
