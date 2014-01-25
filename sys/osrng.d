/**
 * Interface to the OS CSPRNG.
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

module ae.sys.osrng;

import std.conv : to;

version (Windows)
{
	import win32.wincrypt;
	import win32.windef;
	import ae.sys.windows;

	void genRandom(ubyte[] buf)
	{
		HCRYPTPROV hCryptProv;
		wenforce(CryptAcquireContext(&hCryptProv, null, null, PROV_RSA_FULL, 0), "CryptAcquireContext");
		scope(exit) wenforce(CryptReleaseContext(hCryptProv, 0), "CryptReleaseContext");
		wenforce(CryptGenRandom(hCryptProv, buf.length.to!DWORD, buf.ptr), "CryptGenRandom");
	}
}
else
version (Linux)
{
	import std.stdio;

	void genRandom(ubyte[] buf)
	{
		auto f = File("/dev/random");
		auto result = f.rawRead(buf);
		enforce(result == buf.length, "Couldn't read enough random bytes");
	}
}
