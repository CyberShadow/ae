/**
 * std.regex helpers
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

module ae.utils.regex;

import std.conv;
import std.exception;
import std.regex;
import std.string;

import ae.utils.text;

// ************************************************************************

/// Allows specifying regular expression patterns in expressions,
/// without having to compile them each time.
/// Example:
///   if (text.match(`^\d+$`)) {}    // old code - recompiles every time
///   if (text.match(re!`^\d+$`)) {} // new code - recompiles once

Regex!char re(string pattern)
{
	static Regex!char r;
	if (r.empty)
		r = regex(pattern);
	return r;
}

/// Lua-like pattern matching.
bool matchInto(S, R, Args...)(S s, R r, ref Args args)
{
	auto m = s.match(r);
	if (m)
	{
		assert(args.length == m.captures.length-1, "matchInto called with %s arguments but %s capture groups".format(args.length, m.captures.length-1));
		foreach (n, ref arg; args)
			arg = to!(Args[n])(m.captures[n+1]);
		return true;
	}
	return false;
}

///
unittest
{
	string name, fruit;
	int count;
	assert("Mary has 5 apples"
		.matchInto(`^(\w+) has (\d+) (\w+)$`, name, count, fruit));
	assert(name == "Mary" && count == 5 && fruit == "apples");
}

// ************************************************************************

/// Take a string, and return a regular expression that matches that string
/// exactly (escape RE metacharacters).
string escapeRE(string s)
{
	// TODO: test

	string result;
	foreach (c; s)
		switch (c)
		{
		//	case '!':
		//	case '"':
		//	case '#':
			case '$':
		//	case '%':
		//	case '&':
			case '\'':
			case '(':
			case ')':
			case '*':
			case '+':
		//	case ',':
		//	case '-':
			case '.':
			case '/':
		//	case ':':
		//	case ';':
		//	case '<':
		//	case '=':
		//	case '>':
			case '?':
		//	case '@':
			case '[':
			case '\\':
			case ']':
			case '^':
		//	case '_':
		//	case '`':
			case '{':
			case '|':
			case '}':
		//	case '~':
				result ~= '\\';
				goto default;
			default:
				result ~= c;
		}
	return result;
}

// We only need to make sure that there are no unescaped forward slashes
// in the regex, which would mean the end of the search pattern part of the
// regex transform. All escaped forward slashes will be unescaped during
// parsing of the regex transform (which won't affect the regex, as forward
// slashes have no special meaning, escaped or unescaped).
private string escapeUnescapedSlashes(string s)
{
	bool escaped = false;
	string result;
	foreach (c; s)
	{
		if (escaped)
			escaped = false;
		else
		if (c == '\\')
			escaped = true;
		else
		if (c == '/')
			result ~= '\\';

		result ~= c;
	}
	assert(!escaped, "Regex ends with an escape");
	return result;
}

// For the replacement part, we just need to escape all forward and backslashes.
private string escapeSlashes(string s)
{
	return s.fastReplace(`\`, `\\`).fastReplace(`/`, `\/`);
}

// Reverse of the above
private string unescapeSlashes(string s)
{
	return s.fastReplace(`\/`, `/`).fastReplace(`\\`, `\`);
}

/// Build a RE search-and-replace transform (as used by applyRE).
string buildReplaceTransformation(string search, string replacement, string flags)
{
	return "s/" ~ escapeUnescapedSlashes(search) ~ "/" ~ escapeSlashes(replacement) ~ "/" ~ flags;
}

private string[] splitRETransformation(string t)
{
	enforce(t.length >= 2, "Bad transformation");
	string[] result = [t[0..1]];
	auto boundary = t[1];
	t = t[2..$];
	size_t start = 0;
	bool escaped = false;
	foreach (i, c; t)
		if (escaped)
			escaped = false;
		else
		if (c=='\\')
			escaped = true;
		else
		if (c == boundary)
		{
			result ~= t[start..i];
			start = i+1;
		}
	result ~= t[start..$];
	return result;
}

unittest
{
	assert(splitRETransformation("s/from/to/") == ["s", "from", "to", ""]);
}

/// Apply regex transformation (in the form of "s/FROM/TO/FLAGS") to a string.
string applyRE()(string str, string transformation)
{
	import std.regex;
	auto params = splitRETransformation(transformation);
	enforce(params[0] == "s", "Unsupported regex transformation");
	enforce(params.length == 4, "Wrong number of regex transformation parameters");
	auto r = regex(params[1], params[3]);
	return replace(str, r, unescapeSlashes(params[2]));
}

unittest
{
	auto transformation = buildReplaceTransformation(`(?<=\d)(?=(\d\d\d)+\b)`, `,`, "g");
	assert("12000 + 42100 = 54100".applyRE(transformation) == "12,000 + 42,100 = 54,100");

	void testSlashes(string s)
	{
		assert(s.applyRE(buildReplaceTransformation(`\/`, `\`, "g")) == s.fastReplace(`/`, `\`));
		assert(s.applyRE(buildReplaceTransformation(`\\`, `/`, "g")) == s.fastReplace(`\`, `/`));
	}
	testSlashes(`a/b\c`);
	testSlashes(`a//b\\c`);
	testSlashes(`a/\b\/c`);
	testSlashes(`a/\\b\//c`);
	testSlashes(`a//\b\\/c`);
}

// ************************************************************************
