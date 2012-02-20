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

	string opIndex(string name)
	{
		auto values = headers[toUpper(name)];
		assert(values.length == 1);
		return values[0];
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

	string[string] opCast(T)()
		if (is(T == string[string]))
	{
		string[string] result;
		foreach (key, value; this)
			result[key] = value;
		return result;
	}
}

/// Overload for aaGet from ae.utils.array.
string aaGet(Headers headers, string key, string def)
{
	return aaGetLazy(headers, key, def);
}

string aaGetLazy(Headers headers, string key, lazy string def)
{
	auto pvalue = key in headers;
	if (pvalue)
		return *pvalue;
	else
		return def;
}

/// Normalize capitalization
string normalizeHeaderName(string header)
{
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
