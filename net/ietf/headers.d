/**
 * HTTP / mail / etc. headers
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

module ae.net.ietf.headers;

import std.string;
import std.ascii;
import std.exception;

/// AA-like superset structure with the purpose of maintaining
/// compatibility with the old HTTP string[string] headers field
struct Headers
{
	// All keys are internally upper-case.
	private string[][string] headers;

	/// If multiple headers with this name are present,
	/// only the first one is returned.
	string opIndex(string name)
	{
		return headers[toUpper(name)][0];
	}

	string opIndexAssign(string value, string name)
	{
		headers[toUpper(name)] = [value];
		return value;
	}

	string* opIn_r(string name)
	{
		auto pvalues = toUpper(name) in headers;
		if (pvalues && (*pvalues).length)
			return (*pvalues).ptr;
		return null;
	}

	void remove(string name)
	{
		headers.remove(toUpper(name));
	}

	// D forces these to be "ref"
	int opApply(int delegate(ref string name, ref string value) dg)
	{
		int ret;
		outer:
		foreach (name, values; headers)
			foreach (value; values)
			{
				auto normName = normalizeHeaderName(name);
				ret = dg(normName, value);
				if (ret)
					break outer;
			}
		return ret;
	}

	void add(string name, string value)
	{
		name = toUpper(name);
		if (name !in headers)
			headers[name] = [value];
		else
			headers[name] ~= value;
	}

	string get(string key, string def)
	{
		return getLazy(key, def);
	}

	string getLazy(string key, lazy string def)
	{
		auto pvalue = key in this;
		return pvalue ? *pvalue : def;
	}

	string[] getAll(string key)
	{
		return headers[toUpper(key)];
	}

	/// Warning: discards repeating headers
	string[string] opCast(T)()
		if (is(T == string[string]))
	{
		string[string] result;
		foreach (key, value; this)
			result[key] = value;
		return result;
	}

	string[][string] opCast(T)()
		if (is(T == string[][string]))
	{
		string[][string] result;
		foreach (k, v; this)
			result[k] ~= v;
		return result;
	}
}

/// Normalize capitalization
string normalizeHeaderName(string header)
{
	alias std.ascii.toUpper toUpper;
	alias std.ascii.toLower toLower;

	auto s = header.dup;
	auto segments = s.split("-");
	foreach (segment; segments)
	{
		foreach (ref c; segment)
			c = cast(char)toUpper(c);
		switch (segment)
		{
			case "ID":
			case "IP":
			case "NNTP":
			case "TE":
			case "WWW":
				continue;
			case "ETAG":
				segment[] = "ETag";
				break;
			default:
				foreach (ref c; segment[1..$])
					c = cast(char)toLower(c);
				break;
		}
	}
	return assumeUnique(s);
}

unittest
{
	assert(normalizeHeaderName("X-ORIGINATING-IP") == "X-Originating-IP");
}
