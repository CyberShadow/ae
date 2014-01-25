/**
 * VFS driver for curl.
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

module ae.sys.vfs_curl;

private:

import ae.sys.vfs;

import etc.c.curl : CurlOption;
import std.net.curl;
import std.string;

class CurlVFS : VFS
{
	override void[] read(string path) { return get!(AutoProtocol, ubyte)(path); }
	override void write(string path, const(void)[] data) { put!(AutoProtocol, ubyte)(path, cast(ubyte[])data); }
	override bool exists(string path)
	{
		auto proto = path.split("://")[0];
		if (proto == "http" || proto == "https")
		{
			auto http = HTTP(path);
			http.method = HTTP.Method.head;
			bool ok = false;
			http.onReceiveStatusLine = (statusLine) { ok = statusLine.code < 400; };
			http.perform();
			return ok;
		}
		else
		{
			try
			{
				read(path);
				return true;
			}
			catch (Exception e)
				return false;
		}
	}
	override void remove(string path) { del(path); }
	override void mkdirRecurse(string path) { assert(false, "Operation not supported"); }

	static this()
	{
		registry["http"] =
		registry["https"] =
		registry["ftp"] =
		registry["ftps"] =
		// std.net.curl (artificially) restricts supported protocols to the above
		//registry["scp"] =
		//registry["sftp"] =
		//registry["telnet"] =
		//registry["ldap"] =
		//registry["ldaps"] =
		//registry["dict"] =
		//registry["file"] =
		//registry["tftp"] =
			new CurlVFS();
	}
}

unittest
{
	assert( "http://thecybershadow.net/robots.txt".exists);
	assert(!"http://thecybershadow.net/nonexistent".exists);
}
