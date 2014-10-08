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
	ref inout(string) opIndex(string name) inout
	{
		return headers[toUpper(name)][0];
	}

	string opIndexAssign(string value, string name)
	{
		headers[toUpper(name)] = [value];
		return value;
	}

	inout(string)* opIn_r(string name) inout
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

	// Copy-paste because of https://issues.dlang.org/show_bug.cgi?id=7543
	int opApply(int delegate(ref string name, ref const(string) value) dg) const
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

	string get(string key, string def) const
	{
		return getLazy(key, def);
	}

	string getLazy(string key, lazy string def) const
	{
		auto pvalue = key in this;
		return pvalue ? *pvalue : def;
	}

	inout(string)[] getAll(string key) inout
	{
		return headers[toUpper(key)];
	}

	/// Warning: discards repeating headers
	string[string] opCast(T)() const
		if (is(T == string[string]))
	{
		string[string] result;
		foreach (key, value; this)
			result[key] = value;
		return result;
	}

	string[][string] opCast(T)() inout
		if (is(T == string[][string]))
	{
		string[][string] result;
		foreach (k, v; this)
			result[k] ~= v;
		return result;
	}
}

unittest
{
	Headers headers;
	headers["test"] = "test";

	void test(T)(T headers)
	{
		assert("TEST" in headers);
		assert(headers["TEST"] == "test");

		foreach (k, v; headers)
			assert(k == "Test" && v == "test");

		auto aas = cast(string[string])headers;
		assert(aas == ["Test" : "test"]);

		auto aaa = cast(string[][string])headers;
		assert(aaa == ["Test" : ["test"]]);
	}

	test(headers);

	const constHeaders = headers;
	test(constHeaders);
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
