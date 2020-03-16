/**
 * Wrapper for long integer multiplication / division opcodes
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

alias LongInt(T) = LongInt!(T.sizeof * 8, isSigned!T);

alias Cent = LongInt!long;
alias UCent = LongInt!ulong;

version (X86)
	version = Intel;
else
version (X86_64)
	version = Intel;

version (Intel)
{
	version (DigitalMars)
		enum x86RegSizePrefix(T) =
			T.sizeof == 2 ? "" :
			T.sizeof == 4 ? "E" :
			T.sizeof == 8 ? "R" :
			"?"; // force syntax error
	else
	{
		enum x86RegSizePrefix(T) =
			T.sizeof == 2 ? "" :
			T.sizeof == 4 ? "e" :
			T.sizeof == 8 ? "r" :
			"?"; // force syntax error
		enum x86SizeOpSuffix(T) =
			T.sizeof == 2 ? "w" :
			T.sizeof == 4 ? "l" :
			T.sizeof == 8 ? "q" :
			"?"; // force syntax error
	}

	enum x86SignedOpPrefix(T) = isSigned!T ? "i" : "";
}

LongInt!T longMul(T)(T a, T b)
if (is(T : long) && T.sizeof >= 2)
{
	version (Intel)
	{
		version (LDC)
		{
			import ldc.llvmasm;
			auto t = __asmtuple!(T, T)(
				x86SignedOpPrefix!T~`mul`~x86SizeOpSuffix!T~` $3`,
				// Technically, the last one should be "rm", but that generates suboptimal code in many cases
				`={`~x86RegSizePrefix!T~`ax},={`~x86RegSizePrefix!T~`dx},{`~x86RegSizePrefix!T~`ax},r`,
				a, b
			);
			return typeof(return)(t.v[0], t.v[1]);
		}
		else
		version (GNU)
		{
			T low = void, high = void;
			mixin(`
				asm
				{
					"`~x86SignedOpPrefix!T~`mul`~x86SizeOpSuffix!T~` %3"
					: "=a" low, "=d" high
					: "a" a, "rm" b;
				}
			`);
			return typeof(return)(low, high);
		}
		else
		{
			T low = void, high = void;
			mixin(`
				asm
				{
					mov `~x86RegSizePrefix!T~`AX, a;
					`~x86SignedOpPrefix!T~`mul b;
					mov low, `~x86RegSizePrefix!T~`AX;
					mov high, `~x86RegSizePrefix!T~`DX;
				}
			`);
			return typeof(return)(low, high);
		}
	}
	else
		static assert(false, "Not implemented on this architecture");
}

unittest
{
	assert(longMul(1, 1) == LongInt!int(1, 0));
	assert(longMul(1, 2) == LongInt!int(2, 0));
	assert(longMul(0x1_0000, 0x1_0000) == LongInt!int(0, 1));

	assert(longMul(short(1), short(1)) == LongInt!short(1, 0));
	assert(longMul(short(0x100), short(0x100)) == LongInt!short(0, 1));

	assert(longMul(short(1), short(-1)) == LongInt!short(cast(ushort)-1, -1));
	assert(longMul(ushort(1), cast(ushort)-1) == LongInt!ushort(cast(ushort)-1, 0));

	version(X86_64)
	{
		assert(longMul(1L, 1L) == LongInt!long(1, 0));
		assert(longMul(0x1_0000_0000L, 0x1_0000_0000L) == LongInt!long(0, 1));
	}
}

struct DivResult(T) { T quotient, remainder; }

DivResult!T longDiv(T, L)(L a, T b)
if (is(T : long) && T.sizeof >= 2 && is(L == LongInt!T))
{
	version (Intel)
	{
		version (LDC)
		{
			import ldc.llvmasm;
			auto t = __asmtuple!(T, T)(
				x86SignedOpPrefix!T~`div`~x86SizeOpSuffix!T~` $4`,
				// Technically, the last one should be "rm", but that generates suboptimal code in many cases
				`={`~x86RegSizePrefix!T~`ax},={`~x86RegSizePrefix!T~`dx},{`~x86RegSizePrefix!T~`ax},{`~x86RegSizePrefix!T~`dx},r`,
				a.low, a.high, b
			);
			return typeof(return)(t.v[0], t.v[1]);
		}
		else
		version (GNU)
		{
			T low = a.low, high = a.high;
			T quotient = void;
			T remainder = void;
			mixin(`
				asm
				{
					"`~x86SignedOpPrefix!T~`div`~x86SizeOpSuffix!T~` %4"
					: "=a" quotient, "=d" remainder
					: "a" low, "d" high, "rm" b;
				}
			`);
			return typeof(return)(quotient, remainder);
		}
		else
		{
			auto low = a.low;
			auto high = a.high;
			T quotient = void;
			T remainder = void;
			mixin(`
				asm
				{
					mov `~x86RegSizePrefix!T~`AX, low;
					mov `~x86RegSizePrefix!T~`DX, high;
					`~x86SignedOpPrefix!T~`div b;
					mov quotient, `~x86RegSizePrefix!T~`AX;
					mov remainder, `~x86RegSizePrefix!T~`DX;
				}
			`);
			return typeof(return)(quotient, remainder);
		}
	}
	else
		static assert(false, "Not implemented on this architecture");
}

unittest
{
	assert(longDiv(LongInt!int(1, 0), 1) == DivResult!int(1, 0));
	assert(longDiv(LongInt!int(5, 0), 2) == DivResult!int(2, 1));
	assert(longDiv(LongInt!int(0, 1), 0x1_0000) == DivResult!int(0x1_0000, 0));

	assert(longDiv(LongInt!short(1, 0), short(1)) == DivResult!short(1, 0));
	assert(longDiv(LongInt!short(0, 1), short(0x100)) == DivResult!short(0x100, 0));

	assert(longDiv(LongInt!short(cast(ushort)-1, -1), short(-1)) == DivResult!short(1));
	assert(longDiv(LongInt!ushort(cast(ushort)-1, 0), cast(ushort)-1) == DivResult!ushort(1));

	version(X86_64)
	{
		assert(longDiv(LongInt!long(1, 0), 1L) == DivResult!long(1));
		assert(longDiv(LongInt!long(0, 1), 0x1_0000_0000L) == DivResult!long(0x1_0000_0000));
	}
}
