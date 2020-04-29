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

import std.algorithm;
import std.string;
import std.ascii;
import std.exception;

import ae.utils.text;
import ae.utils.aa;

/// AA-like superset structure with the purpose of maintaining
/// compatibility with the old HTTP string[string] headers field
struct Headers
{
	struct Header { string name, value; }

	private Header[][CIAsciiString] headers;

	this(string[string] aa)
	{
		foreach (k, v; aa)
			this.add(k, v);
	}

	this(string[][string] aa)
	{
		foreach (k, vals; aa)
			foreach (v; vals)
				this.add(k, v);
	}

	/// If multiple headers with this name are present,
	/// only the first one is returned.
	ref inout(string) opIndex(string name) inout
	{
		return headers[CIAsciiString(name)][0].value;
	}

	string opIndexAssign(string value, string name)
	{
		headers[CIAsciiString(name)] = [Header(name, value)];
		return value;
	}

	inout(string)* opBinaryRight(string op)(string name) inout @nogc
	if (op == "in")
	{
		auto pvalues = CIAsciiString(name) in headers;
		if (pvalues && (*pvalues).length)
			return &(*pvalues)[0].value;
		return null;
	}

	void remove(string name)
	{
		headers.remove(CIAsciiString(name));
	}

	// D forces these to be "ref"
	int opApply(int delegate(ref string name, ref string value) dg)
	{
		int ret;
		outer:
		foreach (key, values; headers)
			foreach (header; values)
			{
				ret = dg(header.name, header.value);
				if (ret)
					break outer;
			}
		return ret;
	}

	// Copy-paste because of https://issues.dlang.org/show_bug.cgi?id=7543
	int opApply(int delegate(ref const(string) name, ref const(string) value) dg) const
	{
		int ret;
		outer:
		foreach (name, values; headers)
			foreach (header; values)
			{
				ret = dg(header.name, header.value);
				if (ret)
					break outer;
			}
		return ret;
	}

	void add(string name, string value)
	{
		auto key = CIAsciiString(name);
		if (key !in headers)
			headers[key] = [Header(name, value)];
		else
			headers[key] ~= Header(name, value);
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
		inout(string)[] result;
		foreach (header; headers.get(CIAsciiString(key), null))
			result ~= header.value;
		return result;
	}

	ref string require(string key, lazy string value)
	{
		return headers.require(CIAsciiString(key), [Header(key, value)])[0].value;
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

	@property Headers dup()
	{
		Headers c;
		foreach (k, v; this)
			c.add(k, v);
		return c;
	}

	@property size_t length() const
	{
		return headers.length;
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
			assert(k == "test" && v == "test");

		auto aas = cast(string[string])headers;
		assert(aas == ["test" : "test"]);

		auto aaa = cast(string[][string])headers;
		assert(aaa == ["test" : ["test"]]);
	}

	test(headers);

	const constHeaders = headers;
	test(constHeaders);
}

/// Normalize capitalization
string normalizeHeaderName(string header) pure
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
	return s;
}

unittest
{
	assert(normalizeHeaderName("X-ORIGINATING-IP") == "X-Originating-IP");
}

struct TokenHeader
{
	string value;
	string[string] properties;
}

TokenHeader decodeTokenHeader(string s)
{
	string take(char until)
	{
		string result;
		auto p = s.indexOf(until);
		if (p < 0)
			result = s,
			s = null;
		else
			result = s[0..p],
			s = asciiStrip(s[p+1..$]);
		return result;
	}

	TokenHeader result;
	result.value = take(';');

	while (s.length)
	{
		string name = take('=').toLower();
		string value;
		if (s.length && s[0] == '"')
		{
			s = s[1..$];
			value = take('"');
			take(';');
		}
		else
			value = take(';');
		result.properties[name] = value;
	}

	return result;
}
