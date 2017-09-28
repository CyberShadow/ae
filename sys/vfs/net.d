/**
 * VFS driver over ae.sys.net.
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

module ae.sys.vfs.net;

private:

import ae.sys.vfs;

import ae.sys.net;

class NetVFS : VFS
{
	override void[] read(string path) { return getFile(path); }
	override void copy(string src, string dst) { downloadFile(src, dst); }
	override bool exists(string path) { return urlOK(path); }

	static this()
	{
		registry["http"] =
		registry["https"] =
			new NetVFS();
	}

	override void remove(string path) { assert(false, "NetVFS is read-only"); }
	override void mkdirRecurse(string path) { assert(false, "NetVFS is read-only"); }
	override void write(string path, const(void)[] data) { assert(false, "NetVFS is read-only"); }
}

unittest
{
	if (false)
	{
		assert( "http://thecybershadow.net/robots.txt".exists);
		assert(!"http://thecybershadow.net/nonexistent".exists);
	}
}
