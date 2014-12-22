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

debug static import std.stdio;

void test(string moduleName, string className)()
{
	debug std.stdio.stderr.writeln("Testing " ~ className);

	mixin("import ae.sys.net." ~ moduleName ~ ";");
	mixin("alias Net = " ~ className ~ ";");
	auto net = new Net();

	debug std.stdio.stderr.writeln(" - getFile");
	{
		assert(net.getFile("http://d-lang.appspot.com/testUrl1") == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - downloadFile");
	{
		enum fn = "test.txt";
		if (fn.exists) fn.remove();
		scope(exit) if (fn.exists) fn.remove();

		net.downloadFile("http://d-lang.appspot.com/testUrl1", fn);
		assert(fn.readText() == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - urlOK");
	{
		assert( net.urlOK("http://d-lang.appspot.com/testUrl1"));
		assert(!net.urlOK("http://d-lang.appspot.com/testUrlNX"));
		static if (moduleName == "wininet")
			assert( net.urlOK("https://d-lang.appspot.com/testUrl1"));
	}

	debug std.stdio.stderr.writeln(" - resolveRedirect");
	{
		auto result = net.resolveRedirect("http://d-lang.appspot.com/testUrl3");
		assert(result == "http://d-lang.appspot.com/testUrl2", result);
	}
}

unittest
{
	test!("ae", "AENetwork");
	test!("curl", "CurlNetwork");
	version(Windows)
	test!("wininet", "WinINetNetwork");
}
