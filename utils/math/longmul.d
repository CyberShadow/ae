/**
 * Wrapper for long integer multiplication operands
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

module ae.utils.math.longmul;

import std.traits;

import ae.utils.math;

struct LongInt(uint bits, bool signed)
{
	TypeForBits!bits low;
	static if (signed)
		Signed!(TypeForBits!bits) high;
	else
		TypeForBits!bits high;
}

alias Cent = LongInt!(64, true);
alias UCent = LongInt!(64, false);

version (X86)
	version = Intel;
else
version (X86_64)
	version = Intel;

LongInt!(T.sizeof * 8, isSigned!T) longMul(T)(T a, T b)
if (is(T : long) && T.sizeof >= 2)
{
	enum regPrefix =
		T.sizeof == 2 ? "" :
		T.sizeof == 4 ? "E" :
		T.sizeof == 8 ? "R" :
		"?"; // force syntax error

	enum signedPrefix = isSigned!T ? "i" : "";

	T low, high;
	version (Intel)
		mixin(`
			asm
			{
				mov `~regPrefix~`AX, a;
				`~signedPrefix~`mul b;
				mov low, `~regPrefix~`AX;
				mov high, `~regPrefix~`DX;
			}
		`);
	else
		static assert(false, "Not implemented on this architecture");
	return typeof(return)(low, high);
}

unittest
{
	assert(longMul(1, 1) == LongInt!(32, true)(1, 0));
	assert(longMul(1, 2) == LongInt!(32, true)(2, 0));
	assert(longMul(0x1_0000, 0x1_0000) == LongInt!(32, true)(0, 1));

	assert(longMul(short(1), short(1)) == LongInt!(16, true)(1, 0));
	assert(longMul(short(0x100), short(0x100)) == LongInt!(16, true)(0, 1));

	assert(longMul(short(1), short(-1)) == LongInt!(16, true)(cast(ushort)-1, -1));
	assert(longMul(ushort(1), cast(ushort)-1) == LongInt!(16, false)(cast(ushort)-1, 0));

	version(X86_64)
	{
		assert(longMul(1L, 1L) == LongInt!(64, true)(1, 0));
		assert(longMul(0x1_0000_0000L, 0x1_0000_0000L) == LongInt!(64, true)(0, 1));
	}
}
