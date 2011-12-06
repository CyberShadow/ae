/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2006
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// HTTP / mail / etc. headers
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
string aaGet(ref Headers headers, string key, string def)
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
