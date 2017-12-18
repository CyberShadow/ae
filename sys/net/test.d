/**
 * Tests all Network implementations.
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

module ae.sys.net.test;

import std.file;

static import ae.sys.net.ae;
static import ae.sys.net.curl;
version(Windows)
static import ae.sys.net.wininet;
static import ae.sys.net.cachedcurl;

debug static import std.stdio;

// Server-side test scripts are here:
// https://gist.github.com/58df32ed1dbe64fffd0545f87d9321ad

void test(string moduleName, string className)()
{
	debug std.stdio.stderr.writeln("Testing " ~ className);

	mixin("import ae.sys.net." ~ moduleName ~ ";");
	mixin("alias Net = " ~ className ~ ";");
	auto net = new Net();

	debug std.stdio.stderr.writeln(" - getFile");
	{
		assert(net.getFile("http://thecybershadow.net/d/nettest/testUrl1") == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - downloadFile");
	{
		enum fn = "test.txt";
		if (fn.exists) fn.remove();
		scope(exit) if (fn.exists) fn.remove();

		net.downloadFile("http://thecybershadow.net/d/nettest/testUrl1", fn);
		assert(fn.readText() == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - urlOK");
	{
		assert( net.urlOK("http://thecybershadow.net/d/nettest/testUrl1"));
		assert(!net.urlOK("http://thecybershadow.net/d/nettest/testUrlNX"));
		static if (moduleName == "wininet")
			assert( net.urlOK("https://thecybershadow.net/d/nettest/testUrl1"));
	}

	debug std.stdio.stderr.writeln(" - resolveRedirect");
	{
		auto result = net.resolveRedirect("http://thecybershadow.net/d/nettest/testUrl3");
		assert(result == "http://thecybershadow.net/d/nettest/testUrl2", result);
	}

	debug std.stdio.stderr.writeln(" - post");
	{
		auto result = cast(string)net.post("http://thecybershadow.net/d/nettest/testUrl4", "Hello world\n");
		assert(result == "Hello world\n", result);
	}
}

unittest
{
	test!("ae", "AENetwork");
	test!("curl", "CurlNetwork");
	version(Windows)
	test!("wininet", "WinINetNetwork");

	import ae.utils.meta : classInit;
	auto cacheDir = classInit!(ae.sys.net.cachedcurl.CachedCurlNetwork).cacheDir;
	if (cacheDir.exists) cacheDir.rmdirRecurse();
	scope(exit) if (cacheDir.exists) cacheDir.rmdirRecurse();
	test!("cachedcurl", "CachedCurlNetwork");
}
