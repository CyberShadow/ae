/**
 * Bit manipulation.
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

module ae.utils.bitmanip;

import std.bitmanip;
import std.traits;

struct BigEndian(T)
{
	private ubyte[T.sizeof] _endian_bytes;
	@property T _endian_value() { return cast(T)bigEndianToNative!(OriginalType!T)(_endian_bytes); }
	@property void _endian_value(T value) { _endian_bytes = nativeToBigEndian(OriginalType!T(value)); }
	alias _endian_value this;
	alias opAssign = _endian_value;
}

struct LittleEndian(T)
{
	private ubyte[T.sizeof] _endian_bytes;
	@property T _endian_value() { return cast(T)littleEndianToNative!(OriginalType!T)(_endian_bytes); }
	@property void _endian_value(T value) { _endian_bytes = nativeToLittleEndian(OriginalType!T(value)); }
	alias _endian_value this;
	alias opAssign = _endian_value;
}

unittest
{
	union U
	{
		BigEndian!ushort be;
		LittleEndian!ushort le;
		ubyte[2] bytes;
	}
	U u;

	u.be = 0x1234;
	assert(u.bytes == [0x12, 0x34]);

	u.le = 0x1234;
	assert(u.bytes == [0x34, 0x12]);

	u.bytes = [0x56, 0x78];
	assert(u.be == 0x5678);
	assert(u.le == 0x7856);
}

unittest
{
	enum E : uint { e }
	BigEndian!E be;
}
