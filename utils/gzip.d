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

static import zlib = ae.utils.zlib;
static import stdcrc32 = crc32;
debug import std.stdio, std.file;
import ae.sys.data;
import std.exception;

private enum
{
	FTEXT = 1,
	FHCRC = 2,
	FEXTRA = 4,
	FNAME = 8,
	FCOMMENT = 16
}

uint crc32(const(void)[] data)
{
	uint crc = stdcrc32.init_crc32();
	foreach(v;cast(ubyte[])data)
		crc = stdcrc32.update_crc32(v, crc);
	return ~crc;
}

Data compress(Data data)
{
	ubyte[] header;
	header.length = 10;
	header[0] = 0x1F;
	header[1] = 0x8B;
	header[2] = 0x08;
	header[3..8] = 0;  // TODO: set MTIME
	header[8] = 4;
	header[9] = 3;     // TODO: set OS
	uint[2] footer = [crc32(data.contents), std.conv.to!uint(data.length)];
	Data compressed = zlib.compress(data, 9);
	return header ~ compressed[2..compressed.length-4] ~ cast(ubyte[])footer;
}

Data uncompress(Data data)
{
	enforce(data.length>=10, "Gzip too short");
	ubyte[] bytes = cast(ubyte[])data.contents;
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
	Data uncompressed = zlib.uncompress(data[start..data.length-8], 0, -15);
	enforce(uncompressed.length == *cast(uint*)(&data.contents[$-4]), "Decompressed data length mismatch");
	return uncompressed;
}
