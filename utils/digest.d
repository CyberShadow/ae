/**
 * Data digest (hashes etc.)
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

module ae.utils.digest;

import std.traits;

import ae.sys.cmd;
import ae.utils.text;
import ae.utils.array;

ubyte[] hmac_sha1(string message, ubyte[] privateKey)
{
	return
		arrayFromHex(sha1sum(vector!("^")(padRight(privateKey, 64, cast(ubyte)0x00), repeatOne(cast(ubyte)0x5c, 64)) ~
		arrayFromHex(sha1sum(vector!("^")(padRight(privateKey, 64, cast(ubyte)0x00), repeatOne(cast(ubyte)0x36, 64)) ~
		cast(ubyte[])message))));
}

uint[256] crc32Table = [
	0x00000000,0x77073096,0xee0e612c,0x990951ba,0x076dc419,0x706af48f,0xe963a535,0x9e6495a3,0x0edb8832,0x79dcb8a4,0xe0d5e91e,0x97d2d988,0x09b64c2b,0x7eb17cbd,0xe7b82d07,0x90bf1d91,
	0x1db71064,0x6ab020f2,0xf3b97148,0x84be41de,0x1adad47d,0x6ddde4eb,0xf4d4b551,0x83d385c7,0x136c9856,0x646ba8c0,0xfd62f97a,0x8a65c9ec,0x14015c4f,0x63066cd9,0xfa0f3d63,0x8d080df5,
	0x3b6e20c8,0x4c69105e,0xd56041e4,0xa2677172,0x3c03e4d1,0x4b04d447,0xd20d85fd,0xa50ab56b,0x35b5a8fa,0x42b2986c,0xdbbbc9d6,0xacbcf940,0x32d86ce3,0x45df5c75,0xdcd60dcf,0xabd13d59,
	0x26d930ac,0x51de003a,0xc8d75180,0xbfd06116,0x21b4f4b5,0x56b3c423,0xcfba9599,0xb8bda50f,0x2802b89e,0x5f058808,0xc60cd9b2,0xb10be924,0x2f6f7c87,0x58684c11,0xc1611dab,0xb6662d3d,
	0x76dc4190,0x01db7106,0x98d220bc,0xefd5102a,0x71b18589,0x06b6b51f,0x9fbfe4a5,0xe8b8d433,0x7807c9a2,0x0f00f934,0x9609a88e,0xe10e9818,0x7f6a0dbb,0x086d3d2d,0x91646c97,0xe6635c01,
	0x6b6b51f4,0x1c6c6162,0x856530d8,0xf262004e,0x6c0695ed,0x1b01a57b,0x8208f4c1,0xf50fc457,0x65b0d9c6,0x12b7e950,0x8bbeb8ea,0xfcb9887c,0x62dd1ddf,0x15da2d49,0x8cd37cf3,0xfbd44c65,
	0x4db26158,0x3ab551ce,0xa3bc0074,0xd4bb30e2,0x4adfa541,0x3dd895d7,0xa4d1c46d,0xd3d6f4fb,0x4369e96a,0x346ed9fc,0xad678846,0xda60b8d0,0x44042d73,0x33031de5,0xaa0a4c5f,0xdd0d7cc9,
	0x5005713c,0x270241aa,0xbe0b1010,0xc90c2086,0x5768b525,0x206f85b3,0xb966d409,0xce61e49f,0x5edef90e,0x29d9c998,0xb0d09822,0xc7d7a8b4,0x59b33d17,0x2eb40d81,0xb7bd5c3b,0xc0ba6cad,
	0xedb88320,0x9abfb3b6,0x03b6e20c,0x74b1d29a,0xead54739,0x9dd277af,0x04db2615,0x73dc1683,0xe3630b12,0x94643b84,0x0d6d6a3e,0x7a6a5aa8,0xe40ecf0b,0x9309ff9d,0x0a00ae27,0x7d079eb1,
	0xf00f9344,0x8708a3d2,0x1e01f268,0x6906c2fe,0xf762575d,0x806567cb,0x196c3671,0x6e6b06e7,0xfed41b76,0x89d32be0,0x10da7a5a,0x67dd4acc,0xf9b9df6f,0x8ebeeff9,0x17b7be43,0x60b08ed5,
	0xd6d6a3e8,0xa1d1937e,0x38d8c2c4,0x4fdff252,0xd1bb67f1,0xa6bc5767,0x3fb506dd,0x48b2364b,0xd80d2bda,0xaf0a1b4c,0x36034af6,0x41047a60,0xdf60efc3,0xa867df55,0x316e8eef,0x4669be79,
	0xcb61b38c,0xbc66831a,0x256fd2a0,0x5268e236,0xcc0c7795,0xbb0b4703,0x220216b9,0x5505262f,0xc5ba3bbe,0xb2bd0b28,0x2bb45a92,0x5cb36a04,0xc2d7ffa7,0xb5d0cf31,0x2cd99e8b,0x5bdeae1d,
	0x9b64c2b0,0xec63f226,0x756aa39c,0x026d930a,0x9c0906a9,0xeb0e363f,0x72076785,0x05005713,0x95bf4a82,0xe2b87a14,0x7bb12bae,0x0cb61b38,0x92d28e9b,0xe5d5be0d,0x7cdcefb7,0x0bdbdf21,
	0x86d3d2d4,0xf1d4e242,0x68ddb3f8,0x1fda836e,0x81be16cd,0xf6b9265b,0x6fb077e1,0x18b74777,0x88085ae6,0xff0f6a70,0x66063bca,0x11010b5c,0x8f659eff,0xf862ae69,0x616bffd3,0x166ccf45,
	0xa00ae278,0xd70dd2ee,0x4e048354,0x3903b3c2,0xa7672661,0xd06016f7,0x4969474d,0x3e6e77db,0xaed16a4a,0xd9d65adc,0x40df0b66,0x37d83bf0,0xa9bcae53,0xdebb9ec5,0x47b2cf7f,0x30b5ffe9,
	0xbdbdf21c,0xcabac28a,0x53b39330,0x24b4a3a6,0xbad03605,0xcdd70693,0x54de5729,0x23d967bf,0xb3667a2e,0xc4614ab8,0x5d681b02,0x2a6f2b94,0xb40bbe37,0xc30c8ea1,0x5a05df1b,0x2d02ef8d,
];

// the standard Phobos crc32 function relies on inlining for usable performance
uint fastCRC(in void[] data, uint start = cast(uint)-1)
{
	uint crc = start;
	foreach (val; cast(ubyte[])data)
		crc = crc32Table[cast(ubyte) crc ^ val] ^ (crc >> 8);
	return crc;
}

// TODO: reimplement via std.digest

// Struct (for streaming)
struct MurmurHash2A
{
	private static string mmix(string h, string k) { return "{ "~k~" *= m; "~k~" ^= "~k~" >> r; "~k~" *= m; "~h~" *= m; "~h~" ^= "~k~"; }"; }

public:
	void Begin ( uint seed = 0 )
	{
		m_hash  = seed;
		m_tail  = 0;
		m_count = 0;
		m_size  = 0;
	}

	void Add ( const(void) * vdata, sizediff_t len )
	{
		ubyte * data = cast(ubyte*)vdata;
		m_size += len;

		MixTail(data,len);

		while(len >= 4)
		{
			uint k = *cast(uint*)data;

			mixin(mmix("m_hash","k"));

			data += 4;
			len -= 4;
		}

		MixTail(data,len);
	}

	uint End ( )
	{
		mixin(mmix("m_hash","m_tail"));
		mixin(mmix("m_hash","m_size"));

		m_hash ^= m_hash >> 13;
		m_hash *= m;
		m_hash ^= m_hash >> 15;

		return m_hash;
	}

	// D-specific
	void Add(ref ubyte v) { Add(&v, v.sizeof); }
	void Add(ref int v) { Add(&v, v.sizeof); }
	void Add(ref uint v) { Add(&v, v.sizeof); }
	void Add(string s) { Add(s.ptr, cast(uint)s.length); }
	void Add(ubyte[] s) { Add(s.ptr, cast(uint)s.length); }

private:

	static const uint m = 0x5bd1e995;
	static const int r = 24;

	void MixTail ( ref ubyte * data, ref sizediff_t len )
	{
		while( len && ((len<4) || m_count) )
		{
			m_tail |= (*data++) << (m_count * 8);

			m_count++;
			len--;

			if(m_count == 4)
			{
				mixin(mmix("m_hash","m_tail"));
				m_tail = 0;
				m_count = 0;
			}
		}
	}

	uint m_hash;
	uint m_tail;
	uint m_count;
	uint m_size;
}

// Function
uint murmurHash2(in void[] data, uint seed=0)
{
	enum { m = 0x5bd1e995, r = 24 }
	uint len = cast(uint)data.length;
	uint h = seed ^ len;
	ubyte* p = cast(ubyte*)data.ptr;

	while (len >= 4)
	{
		uint k = *cast(uint*)p;

		k *= m;
		k ^= k >> r;
		k *= m;

		h *= m;
		h ^= k;

		p += 4;
		len -= 4;
	}

	switch(len)
	{
		case 3: h ^= p[2] << 16; goto case;
		case 2: h ^= p[1] << 8;  goto case;
		case 1: h ^= p[0];
		/*   */ h *= m;          goto case;
		case 0: break;
		default: assert(0);
	}

	// Do a few final mixes of the hash to ensure the last few
	// bytes are well-incorporated.

	h ^= h >> 13;
	h *= m;
	h ^= h >> 15;

	return h;
}

import ae.utils.digest_murmurhash3;

uint murmurHash3_32(in void[] data, uint seed=0)
{
	uint result;
	MurmurHash3_x86_32(data.ptr, cast(uint)data.length, seed, &result);
	return result;
}

alias uint[4] MH3Digest128;

MH3Digest128 murmurHash3_x86_128(in void[] data, uint seed=0)
{
	MH3Digest128 result;
	MurmurHash3_x86_128(data.ptr, cast(uint)data.length, seed, &result);
	return result;
}

MH3Digest128 murmurHash3_x64_128(in void[] data, uint seed=0)
{
	MH3Digest128 result;
	MurmurHash3_x64_128(data.ptr, cast(uint)data.length, seed, &result);
	return result;
}

/// Select version optimized for target platform.
/// WARNING: Output depends on platform.
version(D_LP64)
	alias murmurHash3_x64_128 murmurHash3_128;
else
	alias murmurHash3_x86_128 murmurHash3_128;

string digestToStringMH3(MH3Digest128 digest)
{
	import std.string;
	return format("%08X%08X%08X%08X", digest[0], digest[1], digest[2], digest[3]);
}

unittest
{
	assert(murmurHash3_32("The quick brown fox jumps over the lazy dog") == 0x2e4ff723);
	assert(murmurHash3_32("The quick brown fox jumps over the lazy cog") == 0xf08200fc);

	assert(murmurHash3_x86_128("The quick brown fox jumps over the lazy dog") == [ 0x2f1583c3 , 0xecee2c67 , 0x5d7bf66c , 0xe5e91d2c ]);
	assert(murmurHash3_x86_128("The quick brown fox jumps over the lazy cog") == [ 0x0ed64388 , 0x3e9ae779 , 0x97034593 , 0x49b3f32f ]);

	assert(murmurHash3_x64_128("The quick brown fox jumps over the lazy dog") == [ 0xbc071b6c , 0xe34bbc7b , 0xc49a9347 , 0x7a433ca9 ]);
	assert(murmurHash3_x64_128("The quick brown fox jumps over the lazy cog") == [ 0xff85269a , 0x658ca970 , 0xa68e5c3e , 0x43fee3ea ]);

	assert(digestToStringMH3(murmurHash3_x86_128("The quick brown fox jumps over the lazy dog")) == "2F1583C3ECEE2C675D7BF66CE5E91D2C");
}

// ************************************************************************

public import std.digest.md;

/// Get digest string of given data.
/// Short-hand for std.digest.md5Of (and similar) and toHexString.
/// Similar to the old std.md5.getDigestString.
template getDigestString(Digest)
{
	string getDigestString(T)(const(T)[][] data...)
		if (!hasIndirections!T)
	{
		return getDigestStringImpl(arrOfArrCastInPlace!(const(ubyte))(data));
	}

	// A dirty hack to fix the array lengths right on the stack, to avoid an allocation.
	T[][] arrOfArrCastInPlace(T, S)(S[][] arrs)
	{
		static struct Array
		{
			size_t length;
			void* ptr;
		}
		auto rawArrs = cast(Array[])arrs;
		foreach (ref ra; rawArrs)
			ra.length = ra.length * S.sizeof / T.sizeof;
		return cast(T[][])rawArrs;
	}

	string getDigestStringImpl(in ubyte[][] data)
	{
		Digest digest;
		digest.start();
		foreach (datum; data)
			digest.put(cast(const(ubyte)[])datum);
		auto result = digest.finish();
		// https://issues.dlang.org/show_bug.cgi?id=9279
		auto str = result.toHexString();
		return str[].idup;
	}
}

///
unittest
{
	assert(getDigestString!MD5("abc") == "900150983CD24FB0D6963F7D28E17F72");
}

// ************************************************************************

/// HMAC digest with a hash algorithm.
/// Params:
///   Algorithm = std.digest-compatible hash type
///   blockSize = Algorithm block size, in bytes
///   key       = Secret key bytes
///   message   = Message data
template HMAC(alias Algorithm, size_t blockSize)
{
	alias Digest = typeof(Algorithm.init.finish());

	Digest HMAC(in ubyte[] key, in ubyte[] message)
	{
		ubyte[blockSize] keyBlock = 0;
		if (key.length > blockSize)
			keyBlock[0..Digest.length] = digest!Algorithm(key)[];
		else
			keyBlock[0..key.length] = key[];

		ubyte[blockSize] oKeyPad = 0x5C; oKeyPad[] ^= keyBlock[];
		ubyte[blockSize] iKeyPad = 0x36; iKeyPad[] ^= keyBlock[];

		Algorithm oHash;
		oHash.start();
		oHash.put(oKeyPad[]);

		Algorithm iHash;
		iHash.start();
		iHash.put(iKeyPad[]);
		iHash.put(message);
		auto iDigest = iHash.finish();

		oHash.put(iDigest[]);
		auto oDigest = oHash.finish();

		return oDigest;
	}
}

auto HMAC_MD5    ()(in ubyte[] key, in ubyte[] message) { import std.digest.md ; return HMAC!(MD5   , 64)(key, message); }
auto HMAC_SHA1   ()(in ubyte[] key, in ubyte[] message) { import std.digest.sha; return HMAC!(SHA1  , 64)(key, message); }
auto HMAC_SHA256 ()(in ubyte[] key, in ubyte[] message) { import std.digest.sha; return HMAC!(SHA256, 64)(key, message); }

unittest
{
	import std.string : representation;
	import std.conv : hexString;

	assert(HMAC_MD5([], []) == hexString!"74e6f7298a9c2d168935f58c001bad88".representation);
	assert(HMAC_SHA1([], []) == hexString!"fbdb1d1b18aa6c08324b7d64b71fb76370690e1d".representation);
	assert(HMAC_SHA256([], []) == hexString!"b613679a0814d9ec772f95d778c35fc5ff1697c493715653c6c712144292c5ad".representation);

	auto message = "The quick brown fox jumps over the lazy dog".representation;
	auto key = "key".representation;
	assert(HMAC_MD5   (key, message) == hexString!"80070713463e7749b90c2dc24911e275".representation);
	assert(HMAC_SHA1  (key, message) == hexString!"de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9".representation);
	assert(HMAC_SHA256(key, message) == hexString!"f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8".representation);
}
