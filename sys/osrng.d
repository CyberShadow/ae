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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.osrng;

import std.conv : to;

version (CRuntime_Bionic)
	version = SecureARC4Random; // ChaCha20
version (OSX)
	version = SecureARC4Random; // AES
version (OpenBSD)
	version = SecureARC4Random; // ChaCha20
version (NetBSD)
	version = SecureARC4Random; // ChaCha20

// Not SecureARC4Random:
// CRuntime_UClibc (ARC4)
// FreeBSD (ARC4)
// DragonFlyBSD (ARC4)

version (Windows)
{
	import ae.sys.windows;

	import ae.sys.windows.imports;
	mixin(importWin32!q{wincrypt});
	mixin(importWin32!q{windef});

	/// Fill `buf` with random data.
	void genRandom(ubyte[] buf)
	{
		HCRYPTPROV hCryptProv;
		wenforce(CryptAcquireContext(&hCryptProv, null, null, PROV_RSA_FULL, 0), "CryptAcquireContext");
		scope(exit) wenforce(CryptReleaseContext(hCryptProv, 0), "CryptReleaseContext");
		wenforce(CryptGenRandom(hCryptProv, buf.length.to!DWORD, buf.ptr), "CryptGenRandom");
	}
}
else
version (SecureARC4Random)
{
	extern(C) private @nogc nothrow
	{
		void arc4random_buf(scope void* buf, size_t nbytes) @system;
	}

	/// Fill `buf` with random data.
	void genRandom(ubyte[] buf)
	{
		arc4random_buf(buf.ptr, buf.length);
	}
}
else
version (Posix)
{
	import std.stdio;
	import std.exception;

	/// Fill `buf` with random data.
	void genRandom(ubyte[] buf)
	{
		auto f = File("/dev/urandom");
		auto result = f.rawRead(buf);
		enforce(result.length == buf.length, "Couldn't read enough random bytes");
	}
}
