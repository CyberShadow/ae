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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.net;

import std.functional;
import std.path;

import ae.net.ietf.url;
import ae.sys.file;

class Network
{
	/// Download file located at the indicated URL,
	/// unless the target file already exists.
	void downloadFile(string url, string target)
	{
		notImplemented();
	}

	/// Get resource located at the indicated URL.
	void[] getFile(string url)
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

/// Download a file and save it to the given directory,
/// unless the file already exists.
/// By default, the file name is extracted from the URL.
string downloadTo(string url, string targetDirectory, string fileName = null)
{
	if (!fileName)
		fileName = url.fileNameFromURL();
	auto target = buildPath(targetDirectory, fileName);
	cachedDg(&net.downloadFile, url, target);
	return target;
}
