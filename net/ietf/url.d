/**
 * ae.net.ietf.url
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

module ae.net.ietf.url;

import std.exception;
import std.string;

import ae.utils.array;

string applyRelativeURL(string base, string rel)
{
	if (rel.indexOf("://") >= 0)
		return rel;

	base = base.split("?")[0];
	base = base[0..base.lastIndexOf('/')+1];
	while (true)
	{
		if (rel.startsWith("../"))
		{
			rel = rel[3..$];
			base = base[0..base[0..$-1].lastIndexOf('/')+1];
			enforce(base.length, "Bad relative URL");
		}
		else
		if (rel.startsWith("/"))
			return base.split("/").slice(0, 3).join("/") ~ rel;
		else
			return base ~ rel;
	}
}

unittest
{
	assert(applyRelativeURL("http://example.com/", "index.html") == "http://example.com/index.html");
	assert(applyRelativeURL("http://example.com/index.html", "page.html") == "http://example.com/page.html");
	assert(applyRelativeURL("http://example.com/dir/index.html", "page.html") == "http://example.com/dir/page.html");
	assert(applyRelativeURL("http://example.com/dir/index.html", "/page.html") == "http://example.com/page.html");
	assert(applyRelativeURL("http://example.com/dir/index.html", "../page.html") == "http://example.com/page.html");
	assert(applyRelativeURL("http://example.com/script.php?path=a/b/c", "page.html") == "http://example.com/page.html");
	assert(applyRelativeURL("http://example.com/index.html", "http://example.org/page.html") == "http://example.org/page.html");
}

string fileNameFromURL(string url)
{
	return url.split("?")[0].split("/")[$-1];
}

unittest
{
	assert(fileNameFromURL("http://example.com/index.html") == "index.html");
	assert(fileNameFromURL("http://example.com/dir/index.html") == "index.html");
	assert(fileNameFromURL("http://example.com/script.php?path=a/b/c") == "script.php");
}

// ***************************************************************************

/// Encode an URL part using a custom function to decide
/// characters to encode.
template UrlEncoder(alias isCharAllowed, char escape = '%')
{
	bool[256] genCharAllowed()
	{
		bool[256] result;
		foreach (c; 0..256)
			result[c] = isCharAllowed(cast(char)c);
		return result;
	}

	immutable bool[256] charAllowed = genCharAllowed();

	struct UrlEncoder(Sink)
	{
		Sink sink;

		void put(in char[] s)
		{
			foreach (c; s)
				if (charAllowed[c])
					sink.put(c);
				else
				{
					sink.put(escape);
					sink.put(hexDigits[cast(ubyte)c >> 4]);
					sink.put(hexDigits[cast(ubyte)c & 15]);
				}
		}
	}
}

import ae.utils.textout : countCopy;

string encodeUrlPart(alias isCharAllowed, char escape = '%')(string s)
{
	alias UrlPartEncoder = UrlEncoder!(isCharAllowed, escape);

	static struct Encoder
	{
		string s;

		void opCall(Sink)(Sink sink)
		{
			auto encoder = UrlPartEncoder!Sink(sink);
			encoder.put(s);
		}
	}

	Encoder encoder = {s};
	return countCopy!char(encoder).assumeUnique();
}

import std.ascii;

alias encodeUrlParameter = encodeUrlPart!(c => isAlphaNum(c) || c=='-' || c=='_');

unittest
{
	assert(encodeUrlParameter("abc?123") == "abc%3F123");
}

import ae.utils.aa : MultiAA;

alias UrlParameters = MultiAA!(string, string);

string encodeUrlParameters(UrlParameters dic)
{
	string[] segs;
	foreach (name, value; dic)
		segs ~= encodeUrlParameter(name) ~ '=' ~ encodeUrlParameter(value);
	return join(segs, "&");
}

string encodeUrlParameters(string[string] dic) { return encodeUrlParameters(UrlParameters(dic)); }

import ae.utils.text;

string decodeUrlParameter(bool plusToSpace=true, char escape = '%')(string encoded)
{
	string s;
	for (auto i=0; i<encoded.length; i++)
		if (encoded[i] == escape && i+3 <= encoded.length)
		{
			s ~= cast(char)fromHex!ubyte(encoded[i+1..i+3]);
			i += 2;
		}
		else
		if (plusToSpace && encoded[i] == '+')
			s ~= ' ';
		else
			s ~= encoded[i];
	return s;
}

UrlParameters decodeUrlParameters(string qs)
{
	UrlParameters dic;
	if (!qs.length)
		return dic;
	string[] segs = split(qs, "&");
	foreach (pair; segs)
	{
		auto p = pair.indexOf('=');
		if (p < 0)
			dic.add(decodeUrlParameter(pair), null);
		else
			dic.add(decodeUrlParameter(pair[0..p]), decodeUrlParameter(pair[p+1..$]));
	}
	return dic;
}

unittest
{
	assert(decodeUrlParameters("").length == 0);
}
