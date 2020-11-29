/**
 * Abstract interface for basic network operations.
 * Import ae.sys.net.* to select an implementation.
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

module ae.sys.net;

import std.functional;
import std.path;

import ae.net.http.common;
import ae.net.ietf.url;
import ae.sys.file;

/// Base interface for basic network operations.
class Network
{
	/// Download file located at the indicated URL,
	/// unless the target file already exists.
	void downloadFile(string url, string target)
	{
		notImplemented();
	}

	// TODO: use ubyte[] instead of void[]

	/// Get resource located at the indicated URL.
	void[] getFile(string url)
	{
		notImplemented();
		assert(false);
	}

	/// Post data to the specified URL.
	// TODO: Content-Type?
	void[] post(string url, const(void)[] data)
	{
		notImplemented();
		assert(false);
	}

	/// Check if the resource exists and is downloadable.
	/// E.g. the HTTP status code for a HEAD request should be 200.
	bool urlOK(string url)
	{
		notImplemented();
		assert(false);
	}

	/// Get the destination of an HTTP redirect.
	string resolveRedirect(string url)
	{
		notImplemented();
		assert(false);
	}

	/// Perform a HTTP request.
	HttpResponse httpRequest(HttpRequest request)
	{
		notImplemented();
		assert(false);
	}

	private final void notImplemented()
	{
		assert(false, "Not implemented or Network implementation not set");
	}
}

/// The instance of the selected Network implementation.
Network net;

static this()
{
	assert(!net);
	net = new Network();
}

/// UFCS-able global synonym functions.
void downloadFile(string url, string target) { net.downloadFile(url, target); }
void[] getFile(string url) { return net.getFile(url); } /// ditto
void[] post(string url, const(void)[] data) { return net.post(url, data); } /// ditto
bool urlOK(string url) { return net.urlOK(url); } /// ditto
string resolveRedirect(string url) { return net.resolveRedirect(url); } /// ditto
