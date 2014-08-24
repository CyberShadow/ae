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
