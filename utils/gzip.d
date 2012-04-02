/**
 * ae.utils.gzip
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.utils.gzip;

// TODO: recent zlib versions support gzip headers,
// reimplement this module as zlib flags

import std.exception;
import std.conv;
debug import std.stdio, std.file;

import ae.sys.data;

static import zlib = ae.utils.zlib;
import ae.utils.zlib : ZlibOptions, ZlibMode;
static import stdcrc32 = crc32;

private enum
{
	FTEXT = 1,
	FHCRC = 2,
	FEXTRA = 4,
	FNAME = 8,
	FCOMMENT = 16
}

uint crc32(Data[] data)
{
	uint crc = stdcrc32.init_crc32();
	foreach (ref d; data)
		foreach (v; cast(ubyte[])d.contents)
			crc = stdcrc32.update_crc32(v, crc);
	return ~crc;
}

Data[] compress(Data[] data, ZlibOptions options = ZlibOptions.init)
{
	ubyte[] header;
	header.length = 10;
	header[0] = 0x1F;
	header[1] = 0x8B;
	header[2] = 0x08;
	header[3..8] = 0;  // TODO: set MTIME
	header[8] = 4;
	header[9] = 3;     // TODO: set OS
	uint[2] footer = [crc32(data), std.conv.to!uint(data.bytes.length)];

	Data[] compressed = zlib.compress(data, options);
	compressed = compressed.bytes[2..compressed.bytes.length-4];

	return [Data(header)] ~ compressed ~ [Data(footer)];
}

Data compress(Data input) { return compress([input]).joinData(); }

Data[] uncompress(Data[] data)
{
	enforce(data.bytes.length >= 10, "Gzip too short");
	auto bytes = data.bytes;
	enforce(bytes[0] == 0x1F && bytes[1] == 0x8B, "Invalid Gzip signature");
	enforce(bytes[2] == 0x08, "Unsupported Gzip compression method");
	ubyte flg = bytes[3];
	enforce((flg & FHCRC)==0, "FHCRC not supported");
	enforce((flg & FEXTRA)==0, "FEXTRA not supported");
	enforce((flg & FCOMMENT)==0, "FCOMMENT not supported");
	uint start = 10;
	if (flg & FNAME)
	{
		while (bytes[start]) start++;
		start++;
	}
	ZlibOptions options; options.mode = ZlibMode.raw;
	Data[] uncompressed = zlib.uncompress(bytes[start..bytes.length-8], options);
	enforce(uncompressed.bytes.length == *cast(uint*)(&data[$-1].contents[$-4]), "Decompressed data length mismatch");
	return uncompressed;
}

Data uncompress(Data input) { return uncompress([input]).joinData(); }

unittest
{
	void testRoundtrip(ubyte[] src)
	{
		ubyte[] def = cast(ubyte[])  compress(Data(src)).toHeap;
		ubyte[] res = cast(ubyte[])uncompress(Data(def)).toHeap;
		assert(res == src);

		Data[] srcData;
		foreach (c; src)
			srcData ~= Data([c]);
		res = cast(ubyte[])uncompress(compress(srcData)).joinToHeap;
		assert(res == src);
	}

	testRoundtrip(cast(ubyte[])
"the quick brown fox jumps over the lazy dog\r
the quick brown fox jumps over the lazy dog\r
");
	testRoundtrip([0]);
	testRoundtrip(null);

	void testUncompress(ubyte[] src, ubyte[] dst)
	{
		assert(cast(ubyte[])uncompress(Data(src)).toHeap == dst);
	}

	testUncompress([
		0x1F, 0x8B, 0x08, 0x08, 0xD3, 0xB2, 0x6E, 0x4F, 0x02, 0x00, 0x74, 0x65, 0x73, 0x74, 0x2E, 0x74,
		0x78, 0x74, 0x00, 0x2B, 0xC9, 0x48, 0x55, 0x28, 0x2C, 0xCD, 0x4C, 0xCE, 0x56, 0x48, 0x2A, 0xCA,
		0x2F, 0xCF, 0x53, 0x48, 0xCB, 0xAF, 0x50, 0xC8, 0x2A, 0xCD, 0x2D, 0x28, 0x56, 0xC8, 0x2F, 0x4B,
		0x2D, 0x52, 0x00, 0x49, 0xE7, 0x24, 0x56, 0x55, 0x2A, 0xA4, 0xE4, 0xA7, 0x03, 0x00, 0x14, 0x51,
		0x0C, 0xCE, 0x2B, 0x00, 0x00, 0x00], cast(ubyte[])"the quick brown fox jumps over the lazy dog");
}
