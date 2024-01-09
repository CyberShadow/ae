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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.net.test;

import std.array;
import std.file;
import std.process : environment;

import ae.net.http.common;
import ae.sys.data : Data;
import ae.sys.dataset : DataVec, joinToGC;
import ae.utils.array : asBytes;

static import ae.sys.net.ae;
static import ae.sys.net.curl;
version(Windows)
static import ae.sys.net.wininet;
static import ae.sys.net.cachedcurl;

debug static import std.stdio;

/// Test endpoint base.
/// Server-side test scripts are here:
/// https://gist.github.com/58df32ed1dbe64fffd0545f87d9321ad
string testBaseURL = "http://thecybershadow.net/d/nettest/"; // (must be HTTP)

/// Test a `ae.sys.net.Network` implementation.
void test(string moduleName, string className)()
{
	debug std.stdio.stderr.writeln("Testing " ~ className);

	mixin("import ae.sys.net." ~ moduleName ~ ";");
	mixin("alias Net = " ~ className ~ ";");
	auto net = new Net();

	debug std.stdio.stderr.writeln(" - getFile");
	{
		assert(net.getFile(testBaseURL ~ "testUrl1") == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - downloadFile");
	{
		enum fn = "test.txt";
		if (fn.exists) fn.remove();
		scope(exit) if (fn.exists) fn.remove();

		net.downloadFile(testBaseURL ~ "testUrl1", fn);
		assert(fn.readText() == "Hello world\n");
	}

	debug std.stdio.stderr.writeln(" - urlOK");
	{
		assert( net.urlOK(testBaseURL ~ "testUrl1"));
		assert(!net.urlOK(testBaseURL ~ "testUrlNX"));
		static if (moduleName == "wininet")
			assert( net.urlOK(testBaseURL.replace("http://", "https://") ~  "testUrl1"));
	}

	debug std.stdio.stderr.writeln(" - resolveRedirect");
	{
		auto result = net.resolveRedirect(testBaseURL ~ "testUrl3");
		assert(result == testBaseURL ~ "testUrl2", result);
	}

	debug std.stdio.stderr.writeln(" - post");
	{
		auto result = cast(string)net.post(testBaseURL ~ "testUrl4", "Hello world\n");
		assert(result == "Hello world\n", result);
	}

	debug std.stdio.stderr.writeln(" - httpRequest");
	{
		auto request = new HttpRequest(testBaseURL ~ "testUrl5");
		request.method = "PUT";
		request.headers.add("Test-Request-Header", "foo");
		request.data = DataVec(Data("bar".asBytes));
		auto response = net.httpRequest(request);
		assert(response.status == HttpStatusCode.Accepted);
		assert(response.statusMessage == "Custom Message");
		assert(response.data.joinToGC() == "PUT foo bar");
		assert(response.headers["Test-Response-Header"] == "baz");
	}
}

unittest
{
	// Don't do network requests on the project tester.
	// See:
	// - https://github.com/CyberShadow/ae/issues/30
	// - https://github.com/dlang/dmd/pull/9618#issuecomment-483214780
	if (environment.get("BUILDKITE_AGENT_NAME"))
		return;

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
