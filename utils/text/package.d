﻿/**
 * Utility code related to string and text processing.
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

module ae.utils.text;

import core.stdc.stdio : snprintf, sscanf;
import core.stdc.string;

import std.algorithm;
import std.ascii;
import std.exception;
import std.conv;
import std.format;
import std.range.primitives;
import std.string;
import std.traits;
import std.typetuple;

import ae.utils.array;
import ae.utils.meta : rangeTuple;
import ae.utils.text.parsefp;
import ae.utils.textout;

private alias indexOf = std.string.indexOf;

public import ae.utils.array : contains;
public import ae.utils.text.ascii : ascii, decimalSize, toDec, toDecFixed, asciiToLower, asciiToUpper;
public import ae.utils.text.functor : formatted;

deprecated("legacy transitive import - please `import ae.utils.text.ascii;`.")
public import ae.utils.text.ascii : DecimalSize;

// ************************************************************************

/// UFCS helper
string formatAs(T)(auto ref T obj, string fmt)
{
	return format(fmt, obj);
}

///
debug(ae_unittest) unittest
{
	assert(5.formatAs("%03d") == "005");
}

// ************************************************************************

/// Consume a LF or CRLF terminated line from s.
/// Sets s to null and returns the remainder
/// if there is no line terminator in s.
T[] eatLine(T)(ref T[] s, bool eatIncompleteLines = true)
{
	return s.skipUntil([T('\n')], eatIncompleteLines).chomp();
}

deprecated template eatLine(OnEof onEof)
{
	T[] eatLine(T)(ref T[] s)
	{
		return s.eatUntil!onEof([T('\n')]).chomp();
	}
}

debug(ae_unittest) unittest
{
	string s = "Hello\nworld";
	assert(s.eatLine() == "Hello");
	assert(s.eatLine() == "world");
	assert(s is null);
	assert(s.eatLine() is null);
}

// Uses memchr (not Boyer-Moore), best for short strings.
/// An implementation of `replace` optimized for common cases (short strings).
T[] fastReplace(T)(T[] what, T[] from, T[] to)
	if (T.sizeof == 1) // TODO (uses memchr)
{
	alias Unqual!T U;

//	debug scope(failure) std.stdio.writeln("fastReplace crashed: ", [what, from, to]);
	enum RAM = cast(U*)null;

	if (what.length < from.length || from.length==0)
		return what;

	if (from.length==1)
	{
		auto fromc = from[0];
		if (to.length==1)
		{
			auto p = cast(T*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			T[] result = what.dup;
			auto delta = result.ptr - what.ptr;
			auto toChar = to[0];
			auto end = what.ptr + what.length;
			do
			{
				(cast(U*)p)[delta] = toChar; // zomg hax lol
				p++;
				p = cast(T*)memchr(p, fromc, end - p);
			} while (p);
			return result;
		}
		else
		{
			auto p = cast(immutable(T)*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto sb = StringBuilder(what.length);
			do
			{
				sb.put(what[0..p-what.ptr], to);
				what = what[p-what.ptr+1..$];
				p = cast(immutable(T)*)memchr(what.ptr, fromc, what.length);
			}
			while (p);

			sb.put(what);
			return sb.get();
		}
	}

	auto head = from[0];
	auto tail = from[1..$];

	auto p = cast(T*)what.ptr;
	auto end = p + what.length - tail.length;
	p = cast(T*)memchr(p, head, end-p);
	while (p)
	{
		p++;
		if (p[0..tail.length] == tail)
		{
			if (from.length == to.length)
			{
				T[] result = what.dup;
				auto deltaMinusOne = (result.ptr - what.ptr) - 1;

				goto replaceA;
			dummyA: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceA:
						(cast(U*)p+deltaMinusOne)[0..to.length] = to[];
					}
					p = cast(T*)memchr(p, head, end-p);
				}
				while (p);

				return result;
			}
			else
			{
				auto start = cast(T*)what.ptr;
				auto sb = StringBuilder(what.length);
				goto replaceB;
			dummyB: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceB:
						sb.put(RAM[cast(size_t)start .. cast(size_t)p-1], to);
						start = p + tail.length;
						what = what[start-what.ptr..$];
					}
					else
					{
						what = what[p-what.ptr..$];
					}
					p = cast(T*)memchr(what.ptr, head, what.length);
				}
				while (p);

				//sb.put(what);
				sb.put(RAM[cast(size_t)start..cast(size_t)(what.ptr+what.length)]);
				return sb.get();
			}

			assert(0);
		}
		p = cast(T*)memchr(p, head, end-p);
	}

	return what;
}

debug(ae_unittest) unittest
{
	import std.array;
	void test(string haystack, string from, string to)
	{
		auto description = `("` ~ haystack ~ `", "` ~ from ~ `", "` ~ to ~ `")`;

		auto r1 = fastReplace(haystack, from, to);
		auto r2 =     replace(haystack, from, to);
		assert(r1 == r2, `Bad replace: ` ~ description ~ ` == "` ~ r1 ~ `"`);

		if (r1 == haystack)
			assert(r1 is haystack, `Pointless reallocation: ` ~ description);
	}

	test("Mary had a little lamb", "a", "b");
	test("Mary had a little lamb", "a", "aaa");
	test("Mary had a little lamb", "Mary", "Lucy");
	test("Mary had a little lamb", "Mary", "Jimmy");
	test("Mary had a little lamb", "lamb", "goat");
	test("Mary had a little lamb", "lamb", "sheep");
	test("Mary had a little lamb", " l", " x");
	test("Mary had a little lamb", " l", " xx");

	test("Mary had a little lamb", "X" , "Y" );
	test("Mary had a little lamb", "XX", "Y" );
	test("Mary had a little lamb", "X" , "YY");
	test("Mary had a little lamb", "XX", "YY");
	test("Mary had a little lamb", "aX", "Y" );
	test("Mary had a little lamb", "aX", "YY");

	test("foo", "foobar", "bar");
}

/// An implementation of `split` optimized for common cases. Allocates only once.
T[][] fastSplit(T, U)(T[] s, U d)
	if (is(Unqual!T == Unqual!U))
{
	if (!s.length)
		return null;

	auto p = cast(T*)memchr(s.ptr, d, s.length);
	if (!p)
		return [s];

	size_t n;
	auto end = s.ptr + s.length;
	do
	{
		n++;
		p++;
		p = cast(T*) memchr(p, d, end-p);
	}
	while (p);

	auto result = new T[][n+1];
	n = 0;
	auto start = s.ptr;
	p = cast(T*) memchr(start, d, s.length);
	do
	{
		result[n++] = start[0..p-start];
		start = ++p;
		p = cast(T*) memchr(p, d, end-p);
	}
	while (p);
	result[n] = start[0..end-start];

	return result;
}

/// Like `splitLines`, but does not attempt to split on Unicode line endings.
/// Only splits on `"\r"`, `"\n"`, and `"\r\n"`.
T[][] splitAsciiLines(T)(T[] text)
	if (is(Unqual!T == char))
{
	auto lines = text.fastSplit('\n');
	foreach (ref line; lines)
		if (line.length && line[$-1]=='\r')
			line = line[0..$-1];
	return lines;
}

debug(ae_unittest) unittest
{
	assert(splitAsciiLines("a\nb\r\nc\r\rd\n\re\r\n\nf") == ["a", "b", "c\r\rd", "\re", "", "f"]);
	assert(splitAsciiLines(string.init) == splitLines(string.init));
}

/// Like std.string.split (one argument version, which splits by
/// whitespace), but only splits by ASCII and does not autodecode.
T[][] asciiSplit(T)(T[] text)
	if (is(Unqual!T == char))
{
	bool inWhitespace = true;
	size_t wordStart;
	T[][] result;

	void endWord(size_t p)
	{
		if (!inWhitespace)
		{
			result ~= text[wordStart..p];
			inWhitespace = true;
		}
	}

	foreach (p, c; text)
		if (std.ascii.isWhite(c))
			endWord(p);
		else
			if (inWhitespace)
			{
				inWhitespace = false;
				wordStart = p;
			}
	endWord(text.length);
	return result;
}

debug(ae_unittest) unittest
{
	foreach (s; ["", " ", "a", " a", "a ", "a b", " a b", "a b ", " a b ",
			"  ", "  a", "a  ", "a  b", "a  b  ", "a b  c"])
		assert(s.split == s.asciiSplit, format("Got %s, expected %s", s.asciiSplit, s.split));
}

/// Like `strip`, but only removes ASCII whitespace.
T[] asciiStrip(T)(T[] s)
	if (is(Unqual!T == char))
{
	while (s.length && isWhite(s[0]))
		s = s[1..$];
	while (s.length && isWhite(s[$-1]))
		s = s[0..$-1];
	return s;
}

///
debug(ae_unittest) unittest
{
	string s = "Hello, world!";
	assert(asciiStrip(s) is s);
	assert(asciiStrip("\r\n\tHello ".dup) == "Hello");
}

/// Covering slice-list of s with interleaved whitespace.
T[][] segmentByWhitespace(T)(T[] s)
	if (is(Unqual!T == char))
{
	if (!s.length)
		return null;

	T[][] segments;
	bool wasWhite = isWhite(s[0]);
	size_t start = 0;
	foreach (p, char c; s)
	{
		bool isWhite = isWhite(c);
		if (isWhite != wasWhite)
			segments ~= s[start..p],
			start = p;
		wasWhite = isWhite;
	}
	segments ~= s[start..$];

	return segments;
}

/// Replaces runs of ASCII whitespace which contain a newline (`'\n'`) into a single space.
T[] newlinesToSpaces(T)(T[] s)
	if (is(Unqual!T == char))
{
	auto slices = segmentByWhitespace(s);
	foreach (ref slice; slices)
		if (slice.contains("\n"))
			slice = " ";
	return slices.join();
}

/// Replaces all runs of ASCII whitespace with a single space.
ascii normalizeWhitespace(ascii s)
{
	auto slices = segmentByWhitespace(strip(s));
	foreach (i, ref slice; slices)
		if (i & 1) // odd
			slice = " ";
	return slices.join();
}

///
debug(ae_unittest) unittest
{
	assert(normalizeWhitespace(" Mary  had\ta\nlittle\r\n\tlamb") == "Mary had a little lamb");
}

/// Splits out words from a camel-cased string.
/// All-uppercase words are returned as a single word.
string[] splitByCamelCase(string s)
{
	string[] result;
	size_t start = 0;
	foreach (i; 1..s.length+1)
		if (i == s.length
		 || (isLower(s[i-1]) && isUpper(s[i]))
		 || (i+1 < s.length && isUpper(s[i-1]) && isUpper(s[i]) && isLower(s[i+1]))
		)
		{
			result ~= s[start..i];
			start = i;
		}
	return result;
}

///
debug(ae_unittest) unittest
{
	assert(splitByCamelCase("parseIPString") == ["parse", "IP", "String"]);
	assert(splitByCamelCase("IPString") == ["IP", "String"]);
}

/// Join an array of words into a camel-cased string.
string camelCaseJoin(string[] arr)
{
	if (!arr.length)
		return null;
	string result = arr[0];
	foreach (s; arr[1..$])
		result ~= std.ascii.toUpper(s[0]) ~ s[1..$];
	return result;
}

debug(ae_unittest) unittest
{
	assert("parse-IP-string".split('-').camelCaseJoin() == "parseIPString");
}

// ************************************************************************

/// Like std.string.wrap, but preserves whitespace at line start and
/// between (non-wrapped) words.
string verbatimWrap(
	string s,
	size_t columns = 80,
	string firstIndent = null,
	string indent = null,
	size_t tabWidth = 8,
)
{
	if (!s.length)
		return s;

	import std.uni : isWhite;
	import std.range;

	// Result buffer. Append-only (contains only text which has been wrapped).
	string result;
	// Index in `s` corresponding to the end of `result`
	size_t start;
	// Index in `s` corresponding to after the last newline in `result`
	size_t lineStart;
	// Current column
	size_t col;
	// Was the previous character we looked at whitespace?
	bool wasWhite;
	// We need to add an indent at the next (non-newline) character.
	bool needIndent;

	result = firstIndent;
	col = firstIndent.walkLength;
	auto indentWidth = indent.walkLength;

	void flush(size_t pos)
	{
		if (col > columns && start > lineStart)
		{
			result ~= "\n" ~ indent;
			col = indentWidth + (pos - start);

			// Consume whitespace at line break
			size_t numWhite;
			foreach (i, c; s[start .. $])
				if (isWhite(c))
					numWhite = i;
				else
					break;
			start += numWhite;
			lineStart = start;
		}
		result ~= s[start .. pos];
		start = pos;
	}

	foreach (pos, dchar c; s)
	{
		auto atWhite = isWhite(c);
		if (atWhite && !wasWhite)
			flush(pos);
		if (c == '\n')
		{
			flush(pos);
			result ~= "\n";
			start++; // past newline
			lineStart = start;
			needIndent = true;
			col = 0;
		}
		else
		{
			if (needIndent)
			{
				assert(col == 0);
				result ~= indent;
				col += indentWidth;
				needIndent = false;
			}
			if (c == '\t')
				col += tabWidth;
			else
				col++;
		}
		wasWhite = atWhite;
	}
	flush(s.length);
	if (col)
		result ~= "\n"; // trailing newline

	return result;
}

// ************************************************************************

/// Case-insensitive ASCII string.
alias CIAsciiString = NormalizedArray!(immutable(char), s => s.byCodeUnit.map!(std.ascii.toLower));

///
debug(ae_unittest) unittest
{
	CIAsciiString s = "test";
	assert(s == "TEST");
	assert(s >= "Test" && s <= "Test");
	assert(CIAsciiString("a") == CIAsciiString("A"));
	assert(CIAsciiString("a") != CIAsciiString("B"));
	assert(CIAsciiString("a") <  CIAsciiString("B"));
	assert(CIAsciiString("A") <  CIAsciiString("b"));
	assert(CIAsciiString("я") != CIAsciiString("Я"));
}

import std.uni : toLower;

/// Case-insensitive Unicode string.
alias CIUniString = NormalizedArray!(immutable(char), s => s.map!(toLower));

///
debug(ae_unittest) unittest
{
	CIUniString s = "привет";
	assert(s == "ПРИВЕТ");
	assert(s >= "Привет" && s <= "Привет");
	assert(CIUniString("я") == CIUniString("Я"));
	assert(CIUniString("а") != CIUniString("Б"));
	assert(CIUniString("а") <  CIUniString("Б"));
	assert(CIUniString("А") <  CIUniString("б"));
}

// ************************************************************************

import std.utf;

/// Convert any data to a valid UTF-8 bytestream, so D's string functions can
/// properly work on it.
string rawToUTF8(in char[] s)
{
	auto d = new dchar[s.length];
	foreach (i, char c; s)
		d[i] = c;
	return toUTF8(d);
}

/// Undo rawToUTF8.
ascii UTF8ToRaw(in char[] r) pure
{
	auto s = new char[r.length];
	size_t i = 0;
	foreach (dchar c; r)
	{
		assert(c < '\u0100');
		s[i++] = cast(char)c;
	}
	return s[0..i];
}

debug(ae_unittest) unittest
{
	char[1] c;
	for (int i=0; i<256; i++)
	{
		c[0] = cast(char)i;
		assert(UTF8ToRaw(rawToUTF8(c[])) == c[], format("%s -> %s -> %s", cast(ubyte[])c[], cast(ubyte[])rawToUTF8(c[]), cast(ubyte[])UTF8ToRaw(rawToUTF8(c[]))));
	}
}

/// Where a delegate with this signature is required.
string nullStringTransform(in char[] s) { return to!string(s); }

/// Like readText, but with in-memory data.
/// Reverse of ae.utils.array.bytes (for strings).
inout(char)[] asText(inout(ubyte)[] bytes)
{
	auto s = cast(inout(char)[]) bytes;
	validate(s);
	return s;
}

/// Lossily convert arbitrary data into a valid UTF-8 string.
string forceValidUTF8(ascii s)
{
	try
	{
		validate(s);
		return s;
	}
	catch (UTFException)
		return rawToUTF8(s);
}

// ************************************************************************

/// Return the slice up to the first NUL character,
/// or of the whole array if none is found.
C[] fromZArray(C, n)(ref C[n] arr)
{
	auto p = arr.representation.countUntil(0);
	return arr[0 .. p<0 ? $ : p];
}

/// ditto
C[] fromZArray(C)(C[] arr)
{
	auto p = arr.representation.countUntil(0);
	return arr[0 .. p<0 ? $ : p];
}

debug(ae_unittest) unittest
{
	char[4] arr = "ab\0d";
	assert(arr.fromZArray == "ab");
	arr[] = "abcd";
	assert(arr.fromZArray == "abcd");
}

debug(ae_unittest) unittest
{
	string arr = "ab\0d";
	assert(arr.fromZArray == "ab");
	arr = "abcd";
	assert(arr.fromZArray == "abcd");
}

// ************************************************************************

/// Formats binary data as a hex dump (three-column layout consisting of hex
/// offset, byte values in hex, and printable low-ASCII characters).
string hexDump(const(void)[] b)
{
	auto data = cast(const(ubyte)[]) b;
	assert(data.length);
	size_t i=0;
	string s;
	while (i<data.length)
	{
		s ~= format("%08X:  ", i);
		foreach (x; 0..16)
		{
			if (i+x<data.length)
				s ~= format("%02X ", data[i+x]);
			else
				s ~= "   ";
			if (x==7)
				s ~= "| ";
		}
		s ~= "  ";
		foreach (x; 0..16)
		{
			if (i+x<data.length)
				if (data[i+x]==0)
					s ~= ' ';
				else
				if (data[i+x]<32 || data[i+x]>=128)
					s ~= '.';
				else
					s ~= cast(char)data[i+x];
			else
				s ~= ' ';
		}
		s ~= "\n";
		i += 16;
	}
	return s;
}

import std.conv;

/// Parses `s` as a hexadecimal number into an integer of type `T`.
T fromHex(T : ulong = uint, C)(const(C)[] s)
{
	T result = parse!T(s, 16);
	enforce(s.length==0, new ConvException("Could not parse entire string"));
	return result;
}

/// Parses `hex` into an array of bytes.
/// `hex.length` should be even.
ubyte[] arrayFromHex(in char[] hex)
{
	auto buf = new ubyte[hex.length/2];
	arrayFromHex(hex, buf);
	return buf;
}

/// Policy for `parseHexDigit`.
struct HexParseConfig
{
	bool checked = true; /// Throw on invalid digits.
	bool lower   = true; /// Accept lower-case digits.
	bool upper   = true; /// Accept upper-case digits.
}

/// Parse a single hexadecimal digit according to the policy in `config`.
ubyte parseHexDigit(HexParseConfig config = HexParseConfig.init)(char c)
{
	static assert(config.lower || config.upper,
		"Must parse at least either lower or upper case digits");
	static if (config.checked)
	{
		switch (c)
		{
			case '0': .. case '9': return cast(ubyte)(c - '0');
			case 'a': .. case 'f': return cast(ubyte)(c - 'a' + 10);
			case 'A': .. case 'F': return cast(ubyte)(c - 'A' + 10);
			default: throw new Exception("Bad hex digit: " ~ c);
		}
	}
	else
	{
		if (c <= '9')
			return cast(ubyte)(c - '0');
		static if (config.lower && config.upper)
		{
			if (c < 'a')
				return cast(ubyte)(c - 'A' + 10);
			else
				return cast(ubyte)(c - 'a' + 10);
		}
		else
			static if (config.lower)
				return cast(ubyte)(c - 'a' + 10);
			else
				return cast(ubyte)(c - 'A' + 10);
	}
}

/// Parses `hex` into the given array `buf`.
void arrayFromHex(HexParseConfig config = HexParseConfig.init)(in char[] hex, ubyte[] buf)
{
	assert(buf.length == hex.length/2, "Wrong buffer size for arrayFromHex");
	for (int i=0; i<hex.length; i+=2)
		buf[i/2] = cast(ubyte)(
			parseHexDigit!config(hex[i  ])*16 +
			parseHexDigit!config(hex[i+1])
		);
}

/// Parses `hex` into the given array `buf`.
/// Fast version for static arrays of known length.
void sarrayFromHex(HexParseConfig config = HexParseConfig.init, size_t N, Hex)(ref const Hex hex, ref ubyte[N] buf)
if (is(Hex == char[N*2]))
{
	foreach (i; 0..N/4)
	{
		ulong chars = (cast(ulong*)hex.ptr)[i];
		uint res =
			(parseHexDigit!config((chars >> (8*0)) & 0xFF) << (4*1)) |
			(parseHexDigit!config((chars >> (8*1)) & 0xFF) << (4*0)) |
			(parseHexDigit!config((chars >> (8*2)) & 0xFF) << (4*3)) |
			(parseHexDigit!config((chars >> (8*3)) & 0xFF) << (4*2)) |
			(parseHexDigit!config((chars >> (8*4)) & 0xFF) << (4*5)) |
			(parseHexDigit!config((chars >> (8*5)) & 0xFF) << (4*4)) |
			(parseHexDigit!config((chars >> (8*6)) & 0xFF) << (4*7)) |
			(parseHexDigit!config((chars >> (8*7)) & 0xFF) << (4*6));
		(cast(uint*)buf.ptr)[i] = res;
	}
	foreach (i; N/4*4..N)
		buf[i] = cast(ubyte)(
			parseHexDigit!config(hex[i*2  ])*16 +
			parseHexDigit!config(hex[i*2+1])
		);
}

debug(ae_unittest) unittest
{
	foreach (checked; TypeTuple!(false, true))
		foreach (lower; TypeTuple!(false, true))
			foreach (upper; TypeTuple!(false, true))
				static if (lower || upper)
				{
					enum config = HexParseConfig(checked, lower, upper);
					char[18] buf;
					foreach (n; 0..18)
						if (lower && upper ? n & 1 : upper)
							buf[n] = hexDigits[n % 16];
						else
							buf[n] = lowerHexDigits[n % 16];
					ubyte[9] res;
					sarrayFromHex!config(buf, res);
					assert(res == [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01], text(res));
				}
}

/// Conversion from bytes to hexadecimal strings.
template toHex(alias digits = hexDigits)
{
	// Note: using template constraints instead of overloads due to
	// https://issues.dlang.org/show_bug.cgi?id=21504

	enum isHexifiable(T) =
		is(T : ulong) || // number
		is(T : const(ubyte)[]) || // dynamic array of bytes
		is(T : const(ubyte)[n], size_t n); // static array of bytes

	enum isBuffer(T) =
		(is(T : C[], C) && isSomeChar!C) || // dynamic array of chars
		(is(T : C[n], n, C) && isSomeChar!C); // static array of chars

	auto toHex(T, B)(auto ref T value, auto ref B buf)
	if (isHexifiable!T && isBuffer!B)
	{
		// Get result length
		static if (is(T : ulong))
			enum resultLength = T.sizeof * 2;
		else
		static if (is(T : const(ubyte)[n], size_t n))
			enum resultLength = T.length * 2;
		else
			auto resultLength = value.length * 2;

		enum fixedResultLength = !is(typeof(&resultLength));

		// Ensure buffer size
		{
			enum fixedBufferLength = !is(T : C[], C);
			static if (!fixedBufferLength && __traits(isRef, buf))
			{
				if (buf.length < resultLength)
					buf.length = resultLength;
			}
			else
			{
				static if (fixedResultLength && fixedBufferLength)
					static assert(resultLength <= buf.length, "Buffer size is insufficient");
				else
					assert(resultLength <= buf.length, "Buffer size is insufficient");
			}
		}

		static if (is(T : ulong))
		{
			Unqual!T x = value;
			foreach (i; Reverse!(rangeTuple!(T.sizeof*2)))
			{
				buf[i] = hexDigits[x & 0xF];
				x >>= 4;
			}
		}
		else
		{
			foreach (i, b; value)
			{
				buf[i*2  ] = digits[b>>4];
				buf[i*2+1] = digits[b&15];
			}
		}

		alias C = typeof(buf[0]);

		static if (fixedResultLength)
			C[resultLength] result;
		else
			C[] result;
		result = buf[0 .. resultLength];
		return result;
	}

	auto toHex(C = char, T)(auto ref T value)
	if (isSomeChar!C && isHexifiable!T)
	{
		static if (is(T : const(ubyte)[]))
			C[] buf;
		else
			C[T.sizeof * 2] buf;
		return toHex(value, buf);
	}
}

alias toLowerHex = toHex!lowerHexDigits; /// ditto

debug(ae_unittest) unittest
{
	ubyte[] bytes = [0x12, 0x34];
	assert(toHex(bytes) == "1234");
}

debug(ae_unittest) unittest
{
	ubyte[] bytes = [0x12, 0x34];
	char[] buf = new char[4];
	toHex(bytes, buf);
	assert(buf == "1234");
}

debug(ae_unittest) unittest
{
	char[8] buf;
	toHex(0x01234567, buf);
	assert(buf == "01234567");
}

debug(ae_unittest) unittest
{
	assert(toHex(0x01234567) == "01234567");
}

debug(ae_unittest) unittest
{
	ubyte[2] bytes = [0x12, 0x34];
	auto buf = bytes.toLowerHex();
	static assert(buf.length == 4);
	assert(buf == "1234");
}

debug(ae_unittest) unittest
{
	import core.exception : AssertError;

	ubyte[] a = new ubyte[10];
	char[] b = new char[10];
	toHex(a[0..1], b[0..2]);
	assertThrown!AssertError(toHex(a[0..1], b[0..1]));
}

/// How many significant decimal digits does a FP type have
/// (determined empirically - valid for all D FP types on x86/64)
enum significantDigits(T : real) = 2 + 2 * T.sizeof;

/// Format string for a FP type which includes all necessary
/// significant digits
enum fpFormatString(T) = "%." ~ text(significantDigits!T) ~ "g";
private template cWidthString(T)
{
	static if (is(Unqual!T == float))
		enum cWidthString = "";
	else
	static if (is(Unqual!T == double))
		enum cWidthString = "l";
	else
	static if (is(Unqual!T == real))
		enum cWidthString = "L";
}
/// C format string to exactly format a floating-point type `T`.
enum fpCFormatString(T) = "%." ~ text(significantDigits!T) ~ cWidthString!T ~ "g";
/// C format string to scan a floating-point type `T`.
enum fpCScanString(T) = "%" ~ cWidthString!T ~ "f";

private auto safeSprintf(size_t N, Args...)(ref char[N] buf, auto ref Args args) @trusted @nogc
{
	return snprintf(buf.ptr, N, args);
}

/// Parse a floating-point number using the C standard library.
/// Note: might produce slightly different results than e.g. `to!double`.
bool fpTryParse(F, C)(ref const(C)[] s, ref F f) @trusted @nogc nothrow
if (isFloatingPoint!F && isSomeChar!C)
{
	// Parity with glibc:
	version (Windows)
	{
		// https://issues.dlang.org/show_bug.cgi?id=22302
		if (s.representation.startsWith("nan".representation)) { s = s[3..$]; f = F.nan; return true; }
		if (s.representation.startsWith("inf".representation)) { s = s[3..$]; f = F.infinity; return true; }
		if (s.representation.startsWith("-inf".representation)) { s = s[4..$]; f = -F.infinity; return true; }
	}

	import core.stdc.stdlib : malloc, free;
	char[64] sbuf = void;
	auto buf = s.length >= sbuf.length ? cast(char*)malloc(s.length + 1) : sbuf.ptr;
	if (!buf)
		assert(false, "Memory allocation failed");
	scope(exit) if (buf != sbuf.ptr) free(buf);

	foreach (i, c; s)
	{
		if (c >= 0x100)
			return false; // Non-ASCII
		buf[i] = cast(char)c;
	}
	buf[s.length] = 0;

	static immutable fmt = fpCScanString!F ~ "%n\0";
	int read;
	if (!sscanf(buf, fmt.ptr, &f, &read))
		return false;
	s = s[read .. $];
	return true;
}

/// ditto
F fpParse(F, C)(const(C)[] s)
if (isFloatingPoint!F && isSomeChar!C)
{
	F f;
	fpTryParse(s, f).enforce("Failed to parse " ~ F.stringof);
	enforce(s.length == 0, "Failed to completely parse " ~ F.stringof);
	return f;
}

private F fpParseAssumeValid(F)(const(char)[] s) @nogc
{
	F f;
	auto res = fpTryParse(s, f);
	assert(res, "Failed to parse number we created");
	assert(!s.length, "Failed to completely parse number we created");
	return f;
}

private auto fpToBuf(Q)(Q val) @safe nothrow @nogc
{
	alias F = Unqual!Q;

	/// Bypass FPU register, which may contain a different precision
	static F forceType(F d) { static F n; n = d; return n; }

	enum isReal = is(F == real);

	StaticBuf!(char, 64) buf = void;

	// MSVC workaround from std.format:
	version (CRuntime_Microsoft)
	{
		import std.math : isNaN, isInfinity;
		immutable double v = val; // convert early to get "inf" in case of overflow
		{
			string s;
			if (isNaN(v))
				s = "nan"; // snprintf writes 1.#QNAN
			else if (isInfinity(v))
				s = val >= 0 ? "inf" : "-inf"; // snprintf writes 1.#INF
			else
				goto L1;
			buf.buf[0..s.length] = s;
			buf.pos = s.length;
			return buf;
		L1:
		}
	}
	else
		alias v = val;

	buf.pos = safeSprintf(buf.buf, &fpCFormatString!F[0], forceType(v));
	char[] s = buf.data();

	F parse(char[] s)
	{
		auto f = fpParseAssumeValid!F(s);
		return f;
	}

	if (s != "nan" && s != "-nan" && s != "inf" && s != "-inf")
	{
		if (forceType(parse(s)) != v)
		{
			static if (isReal)
			{
				// Something funny with DM libc real parsing... e.g. 0.6885036635121051783
				return buf;
			}
			else
			//	assert(false, "Initial conversion fails: " ~ format(fpFormatString!F, parse(s)) ~ " / " ~ s);
				assert(false, "Initial conversion fails");
		}

		auto suffixPos = s.length;
		foreach (i, c; s)
			if (c == 'e' || c == 'E')
			{
				suffixPos = i;
				break;
			}
		auto suffix = s[suffixPos .. $];
		s = s[0 .. suffixPos];

		StaticBuf!(char, 64) testBuf;
		void render(char[] prefix)
		{
			testBuf.pos = 0;
			testBuf.put(prefix);
			testBuf.put(suffix);
		}
		F tryPrefix(char[] prefix)
		{
			render(prefix);
			return forceType(parse(testBuf.data));
		}

		foreach_reverse (i; 1..s.length)
			if (s[i]>='0' && s[i]<='8')
			{
				s[i]++;
				if (tryPrefix(s[0..i+1])==v)
					s = s[0..i+1];
				else
					s[i]--;
			}
		while (s.length>2 && s[$-1]!='.' && tryPrefix(s[0..$-1])==v)
			s = s[0..$-1];

		render(s);
		return testBuf;
	}
	buf.pos = s.length;
	return buf;
}

/// Get shortest string representation of a FP type that still converts to exactly the same number.
template fpToString(F)
{
	string fpToString(F v) @safe nothrow
	{
		return fpToBuf(v).data.idup;
	}

	static if (!is(Unqual!F == real))
	debug(ae_unittest) unittest
	{
		union U
		{
			ubyte[F.sizeof] bytes;
			Unqual!F d;
			string toString() const { return (fpFormatString!F ~ " %a [%(%02X %)]").format(d, d, bytes[]); }
		}
		import std.random : Xorshift, uniform;
		import std.stdio : stderr;
		Xorshift rng;
		foreach (n; 0..10000)
		{
			U u;
			foreach (ref b; u.bytes[])
				b = uniform!ubyte(rng);
			static if (is(Unqual!F == real))
				u.bytes[7] |= 0x80; // require normalized value
			scope(failure) stderr.writeln("Input:\t", u);
			auto s = fpToString(u.d);
			scope(failure) stderr.writeln("Result:\t", s);
			if (s == "nan" || s == "-nan")
				continue; // there are many NaNs...
			U r;
			//r.d = to!F(s);
			r.d = fpParse!F(s);
			assert(r.bytes == u.bytes,
				"fpToString mismatch:\nOutput:\t%s".format(r));
		}
	}
}

alias doubleToString = fpToString!double; ///

debug(ae_unittest) unittest
{
	alias floatToString = fpToString!float;
	alias realToString = fpToString!real;
	alias crealToString = fpToString!(const(real));
}

debug(ae_unittest) unittest
{
	assert(2.3841857910156251e-07.doubleToString == "2.384185791015625e-07");
	assert(1.3e-07.doubleToString == "1.3e-07");
}

/// Like `fpToString`, but writes the result to a sink.
void putFP(Writer, F)(auto ref Writer writer, F v)
{
	writer.put(fpToBuf(v).data);
}


/// Wraps the result of `fpToString` in a non-allocating stringifiable struct.
struct FPAsString(T)
{
	private typeof(fpToBuf(T.init)) buf;

	this(T f)
	{
		buf = fpToBuf(f);
	} ///

	string toString() const pure nothrow
	{
		return buf.data.idup;
	} ///

	void toString(W)(ref W w) const
	{
		static if (is(typeof(w.put(buf.data))))
			w.put(buf.data);
		else
			foreach (c; buf.data)
				w.put(c);
	} ///
}
FPAsString!T fpAsString(T)(T f) { return FPAsString!T(f); } /// ditto

@safe //nothrow @nogc
debug(ae_unittest) unittest
{
	StaticBuf!(char, 1024) buf;
	buf.formattedWrite!"%s"(fpAsString(0.1));
	assert(buf.data == "0.1", buf.data.idup);
}

/// Get shortest string representation of a numeric
/// type that still converts to exactly the same number.
string numberToString(T)(T v)
	if (isNumeric!T)
{
	static if (is(T : ulong))
		return toDec(v);
	else
		return fpToString(v);
}

// ************************************************************************

/// Simpler implementation of Levenshtein string distance
int stringDistance(string s, string t)
{
	int n = cast(int)s.length;
	int m = cast(int)t.length;
	if (n == 0) return m;
	if (m == 0) return n;
	int[][] distance = new int[][](n+1, m+1); // matrix
	int cost=0;
	//init1
	foreach (i; 0..n+1) distance[i][0]=i;
	foreach (j; 0..m+1) distance[0][j]=j;
	//find min distance
	foreach (i; 1..n+1)
		foreach (j; 1..m+1)
		{
			cost = t[j-1] == s[i-1] ? 0 : 1;
			distance[i][j] = min(
				distance[i-1][j  ] + 1,
				distance[i  ][j-1] + 1,
				distance[i-1][j-1] + cost
			);
		}
	return distance[n][m];
}

/// Return a number between 0.0 and 1.0 indicating how similar two strings are
/// (1.0 if identical)
float stringSimilarity(string string1, string string2)
{
	float dis = stringDistance(string1, string2);
	float maxLen = string1.length;
	if (maxLen < string2.length)
		maxLen = string2.length;
	if (maxLen == 0)
		return 1;
	else
		return 1f - dis/maxLen;
}

/// Select best match from a list of items.
/// Returns -1 if none are above the threshold.
sizediff_t findBestMatch(in string[] items, string target, float threshold = 0.7)
{
	sizediff_t found = -1;
	float best = 0;

	foreach (i, item; items)
	{
		float match = stringSimilarity(toLower(item),toLower(target));
		if (match>threshold && match>=best)
		{
			best = match;
			found = i;
		}
	}

	return found;
}

/// Select best match from a list of items.
/// Returns null if none are above the threshold.
string selectBestFrom(in string[] items, string target, float threshold = 0.7)
{
	auto index = findBestMatch(items, target, threshold);
	return index < 0 ? null : items[index];
}

// ************************************************************************

/// Generate a random string with the given parameters.
/// `std.random` is used as the source of randomness.
/// Not cryptographically secure.
string randomString()(int length=20, string chars="abcdefghijklmnopqrstuvwxyz")
{
	import std.random;
	import std.range;

	return length.iota.map!(n => chars[uniform(0, $)]).array;
}
