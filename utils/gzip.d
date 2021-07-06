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
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.utils.gzip;

// TODO: recent zlib versions support gzip headers,
// reimplement this module as zlib flags

import std.exception;
import std.conv;
import std.range.primitives : ElementType;
debug import std.stdio, std.file;

import ae.sys.data;
import ae.utils.array;
import ae.utils.bitmanip;

static import zlib = ae.utils.zlib;
public import ae.utils.zlib : ZlibOptions, ZlibMode;
import std.digest.crc;

private enum
{
	FTEXT = 1,
	FHCRC = 2,
	FEXTRA = 4,
	FNAME = 8,
	FCOMMENT = 16
}

/// Calculate CRC32 from `Data[]`
uint crc32(R)(R data)
if (is(ElementType!R : const(Data)))
{
	CRC32 crc;
	foreach (ref d; data)
		crc.put(cast(ubyte[])d.contents);
	auto result = crc.finish();
	return *cast(uint*)result.ptr;
}

unittest
{
	assert(crc32([Data("ab"), Data("c")]) == 0x352441C2);
}

/// Add a Gzip header to deflated data.
DataVec deflate2gzip(scope Data[] compressed, uint dataCrc, size_t dataLength)
{
	ubyte[] header;
	header.length = 10;
	header[0] = 0x1F;
	header[1] = 0x8B;
	header[2] = 0x08;
	header[3..8] = 0;  // TODO: set MTIME
	header[8] = 4;
	header[9] = 3;     // TODO: set OS
	uint[2] footer = [dataCrc, std.conv.to!uint(dataLength)];

	return DataVec(
		Data(header),
		compressed.bytes[2 .. $ - 4],
		Data(footer),
	);
}

/// Compress data to Gzip.
DataVec compress(scope Data[] data, ZlibOptions options = ZlibOptions.init)
{
	return deflate2gzip(zlib.compress(data, options)[], crc32(data), data.bytes.length);
}

Data compress(Data input) { return compress(input.toArray).joinData(); } /// ditto

/// Strip the Gzip header from `data`.
DataVec gzipToRawDeflate(scope Data[] data)
{
	auto bytes = data.bytes;
	enforce(bytes.length >= 10, "Gzip too short");
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
	return bytes[start..bytes.length-8];
}

/// Uncompress Gzip-compressed data.
DataVec uncompress(scope Data[] data)
{
	auto bytes = data.bytes;
	enforce(bytes.length >= 4, "No data to decompress");

	ZlibOptions options; options.mode = ZlibMode.raw;
	DataVec uncompressed = zlib.uncompress(gzipToRawDeflate(data)[], options);

	LittleEndian!uint size;
	bytes[$-4 .. $].copyTo(size.toArray);
	enforce(cast(uint)uncompressed.bytes.length == size, "Decompressed data length mismatch");

	return uncompressed;
}

Data uncompress(Data input) { return uncompress(input.toArray).joinData(); } /// ditto

unittest
{
	void testRoundtrip(ubyte[] src)
	{
		ubyte[] def = cast(ubyte[])  compress(Data(src)).toHeap;
		ubyte[] res = cast(ubyte[])uncompress(Data(def)).toHeap;
		assert(res == src);

		DataVec srcData;
		foreach (c; src)
			srcData ~= Data([c]);
		res = cast(ubyte[])uncompress(compress(srcData[])[]).joinToHeap;
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
