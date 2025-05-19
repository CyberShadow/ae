/**
 * Simple (ASCII-only) text-processing functions,
 * for speed and CTFE.
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

module ae.utils.text.ascii;

import std.ascii;
import std.algorithm : max;
import std.traits : Unqual, isSigned;

import ae.utils.array : contains;

// ************************************************************************

/// Semantic alias for an array of immutable bytes containing some
/// ASCII-based 8-bit character encoding. Might be UTF-8, but not
/// necessarily - thus, is a semantic superset of the D "string" alias.
alias string ascii;

// ************************************************************************

/// Maximum number of characters needed to fit the decimal
/// representation of any number of this basic integer type.
template decimalSize(T : ulong)
{
	alias _U = Unqual!T;
	///
	static if (is(_U == ubyte))
		enum decimalSize = 3;
	else
	static if (is(_U == byte))
		enum decimalSize = 4;
	else
	static if (is(_U == ushort))
		enum decimalSize = 5;
	else
	static if (is(_U == short))
		enum decimalSize = 6;
	else
	static if (is(_U == uint))
		enum decimalSize = 10;
	else
	static if (is(_U == int))
		enum decimalSize = 11;
	else
	static if (is(_U == ulong))
		enum decimalSize = 20;
	else
	static if (is(_U == long))
		enum decimalSize = 20;
	else
		static assert(false, "Unknown type for decimalSize");
}

deprecated alias DecimalSize = decimalSize;

debug(ae_unittest) unittest
{
	template decimalSize2(T : ulong)
	{
		import std.conv : text;
		enum decimalSize2 = max(text(T.min).length, text(T.max).length);
	}

	static assert(decimalSize!ubyte == decimalSize2!ubyte);
	static assert(decimalSize!byte == decimalSize2!byte);
	static assert(decimalSize!ushort == decimalSize2!ushort);
	static assert(decimalSize!short == decimalSize2!short);
	static assert(decimalSize!uint == decimalSize2!uint);
	static assert(decimalSize!int == decimalSize2!int);
	static assert(decimalSize!ulong == decimalSize2!ulong);
	static assert(decimalSize!long == decimalSize2!long);

	static assert(decimalSize!(const(long)) == decimalSize!long);
}

/// Writes n as decimal number to buf (right-aligned), returns slice of buf containing result.
char[] toDec(N : ulong, size_t U)(N o, ref char[U] buf) pure @trusted
{
	static assert(U >= decimalSize!N, "Buffer too small to fit any " ~ N.stringof ~ " value");

	Unqual!N n = o;
	char* p = buf.ptr + buf.length;

	if (isSigned!N && n < 0)
	{
		do
		{
			*--p = '0' - n%10;
			n = n/10;
		} while (n);
		*--p = '-';
	}
	else
		do
		{
			*--p = '0' + n%10;
			n = n/10;
		} while (n);

	return p[0 .. buf.ptr + buf.length - p];
}

/// CTFE-friendly variant.
char[] toDecCTFE(N : ulong, size_t U)(N o, ref char[U] buf)
{
	static assert(U >= decimalSize!N, "Buffer too small to fit any " ~ N.stringof ~ " value");

	Unqual!N n = o;
	size_t p = buf.length;

	if (isSigned!N && n<0)
	{
		do
		{
			buf[--p] = '0' - n%10;
			n = n/10;
		} while (n);
		buf[--p] = '-';
	}
	else
		do
		{
			buf[--p] = '0' + n%10;
			n = n/10;
		} while (n);

	return buf[p..$];
}

/// Basic integer-to-string conversion.
string toDec(T : ulong)(T n)
{
	if (__ctfe)
	{
		char[decimalSize!T] buf;
		return toDecCTFE(n, buf).idup;
	}
	else
	{
		static struct Buf { char[decimalSize!T] buf; } // Can't put static array on heap, use struct
		return toDec(n, (new Buf).buf);
	}
}

debug(ae_unittest) @safe unittest
{
	import std.conv : to;
	assert(toDec(42) == "42");
	assert(toDec(int.min) == int.min.to!string());
	static assert(toDec(42) == "42", toDec(42));
}

/// Print an unsigned integer as a zero-padded, right-aligned decimal number into a buffer
void toDecFixed(N : ulong, size_t U)(N n, ref char[U] buf)
	if (!isSigned!N)
{
	import std.meta : Reverse;
	import ae.utils.meta : rangeTuple;

	enum limit = 10^^U;
	assert(n < limit, "Number too large");

	foreach (i; Reverse!(rangeTuple!U))
	{
		buf[i] = cast(char)('0' + (n % 10));
		n /= 10;
	}
}

/// ditto
char[U] toDecFixed(size_t U, N : ulong)(N n)
	if (!isSigned!N)
{
	char[U] buf;
	toDecFixed(n, buf);
	return buf;
}

debug(ae_unittest) unittest
{
	assert(toDecFixed!6(12345u) == "012345");
}

// ************************************************************************

/// Basic string-to-integer conversion.
/// Doesn't check for overflows.
T fromDec(T)(string s)
{
	static if (isSigned!T)
	{
		bool neg;
		if (s.length && s[0] == '-')
		{
			neg = true;
			s = s[1..$];
		}
	}

	T n;
	foreach (i, c; s)
	{
		if (c < '0' || c > '9')
			throw new Exception("Bad digit");
		n = n * 10 + cast(T)(c - '0');
	}
	static if (isSigned!T)
		if (neg)
			n = -n;
	return n;
}

debug(ae_unittest) unittest
{
	assert(fromDec!int("456") == 456);
	assert(fromDec!int("-42") == -42);
}

// ************************************************************************

/// Returns `true` if `s` does not contain any characters which are not in `chars`.
bool containsOnlyChars(string s, string chars)
{
	foreach (c; s)
		if (!chars.contains(c))
			return false;
	return true;
}

/// Returns `true` if `s` contains only digits and is non-empty.
bool isUnsignedInteger(string s)
{
	foreach (c; s)
		if (c < '0' || c > '9')
			return false;
	return s.length > 0;
}

/// Returns `true` if `s` contains only digits
/// (excluding an optional leading '-') and is non-empty.
bool isSignedInteger(string s)
{
	return s.length && isUnsignedInteger(s[0] == '-' ? s[1..$] : s);
}

// ************************************************************************

private __gshared char[256] asciiLower, asciiUpper;

shared static this()
{
	foreach (c; 0..256)
	{
		asciiLower[c] = cast(char)std.ascii.toLower(c);
		asciiUpper[c] = cast(char)std.ascii.toUpper(c);
	}
}

void _xlat(alias TABLE, T)(T[] buf)
{
	foreach (ref c; buf)
		c = TABLE[c];
}

/// Lowercases or uppercases a string in-place.
alias _xlat!(asciiLower, char) asciiToLower;
alias _xlat!(asciiUpper, char) asciiToUpper; /// ditto
