/**
 * Utility code related to string and text processing.
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

module ae.utils.text;

import std.ascii;
import std.exception;
import std.string;
import std.typetuple;

import core.stdc.string;

import ae.utils.meta;
import ae.utils.textout;

// ************************************************************************

bool contains(in char[] str, in char[] what)
{
	return str.indexOf(what)>=0;
}

string fastReplace(string what, string from, string to)
{
//	debug scope(failure) std.stdio.writeln("fastReplace crashed: ", [what, from, to]);
	enum RAM = cast(char*)null;

	if (what.length < from.length || from.length==0)
		return what;

	if (from.length==1)
	{
		auto fromc = from[0];
		if (to.length==1)
		{
			auto p = cast(char*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto result = what.dup;
			auto delta = result.ptr - what.ptr;
			auto toChar = to[0];
			auto end = what.ptr + what.length;
			do
			{
				p[delta] = toChar; // zomg hax lol
				p++;
				p = cast(char*)memchr(p, fromc, end - p);
			} while (p);
			return assumeUnique(result);
		}
		else
		{
			auto p = cast(immutable(char)*)memchr(what.ptr, fromc, what.length);
			if (!p)
				return what;

			auto sb = StringBuilder(what.length);
			do
			{
				sb.put(what[0..p-what.ptr], to);
				what = what[p-what.ptr+1..$];
				p = cast(immutable(char)*)memchr(what.ptr, fromc, what.length);
			}
			while (p);

			sb.put(what);
			return sb.get();
		}
	}

	auto head = from[0];
	auto tail = from[1..$];

	auto p = cast(char*)what.ptr;
	auto end = p + what.length - tail.length;
	p = cast(char*)memchr(p, head, end-p);
	while (p)
	{
		p++;
		if (p[0..tail.length] == tail)
		{
			if (from.length == to.length)
			{
				auto result = what.dup;
				auto deltaMinusOne = (result.ptr - what.ptr) - 1;

				goto replaceA;
			dummyA: // compiler complains

				do
				{
					p++;
					if (p[0..tail.length] == tail)
					{
					replaceA:
						(p+deltaMinusOne)[0..to.length] = to;
					}
					p = cast(char*)memchr(p, head, end-p);
				}
				while (p);

				return assumeUnique(result);
			}
			else
			{
				auto start = cast(char*)what.ptr;
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
					p = cast(char*)memchr(what.ptr, head, what.length);
				}
				while (p);

				//sb.put(what);
				sb.put(RAM[cast(size_t)start..cast(size_t)(what.ptr+what.length)]);
				return sb.get();
			}

			assert(0);
		}
		p = cast(char*)memchr(p, head, end-p);
	}

	return what;
}

unittest
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

string[] fastSplit(string s, char d)
{
	if (!s.length)
		return null;

	auto p = cast(immutable(char)*) memchr(s.ptr, d, s.length);
	if (!p)
		return [s];

	size_t n;
	auto end = s.ptr + s.length;
	do
	{
		n++;
		p++;
		p = cast(immutable(char)*) memchr(p, d, end-p);
	}
	while (p);

	auto result = new string[n+1];
	n = 0;
	auto start = s.ptr;
	p = cast(immutable(char)*) memchr(start, d, s.length);
	do
	{
		result[n++] = start[0..p-start];
		start = ++p;
		p = cast(immutable(char)*) memchr(p, d, end-p);
	}
	while (p);
	result[n] = start[0..end-start];

	return result;
}

string[] splitAsciiLines(string text)
{
	auto lines = text.fastSplit('\n');
	foreach (ref line; lines)
		if (line.length && line[$-1]=='\r')
			line = line[0..$-1];
	return lines;
}

unittest
{
	assert(splitAsciiLines("a\nb\r\nc\r\rd\n\re\r\n\nf") == ["a", "b", "c\r\rd", "\re", "", "f"]);
	assert(splitAsciiLines(string.init) == splitLines(string.init));
}

string asciiStrip(string s)
{
	while (s.length && isWhite(s[0]))
		s = s[1..$];
	while (s.length && isWhite(s[$-1]))
		s = s[0..$-1];
	return s;
}

unittest
{
	string s = "Hello, world!";
	assert(asciiStrip(s) is s);
	assert(asciiStrip("\r\n\tHello ") == "Hello");
}

/// Covering slice-list of s with interleaved whitespace.
string[] segmentByWhitespace(string s)
{
	if (!s.length)
		return null;

	string[] segments;
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

string newlinesToSpaces(string s)
{
	auto slices = segmentByWhitespace(s);
	foreach (ref slice; slices)
		if (slice.contains("\n"))
			slice = " ";
	return slices.join();
}

string normalizeWhitespace(string s)
{
	auto slices = segmentByWhitespace(strip(s));
	foreach (i, ref slice; slices)
		if (i & 1) // odd
			slice = " ";
	return slices.join();
}

unittest
{
	assert(normalizeWhitespace(" Mary  had\ta\nlittle\r\n\tlamb") == "Mary had a little lamb");
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

void xlat(alias TABLE, T)(T[] buf)
{
	foreach (ref c; buf)
		c = TABLE[c];
}

alias xlat!(asciiLower, char) asciiToLower;
alias xlat!(asciiUpper, char) asciiToUpper;

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
string UTF8ToRaw(in char[] r)
{
	auto s = new char[r.length];
	size_t i = 0;
	foreach (dchar c; r)
	{
		assert(c < '\u0100');
		s[i++] = cast(char)c;
	}
	return assumeUnique(s[0..i]);
}

unittest
{
	char[1] c;
	for (int i=0; i<256; i++)
	{
		c[0] = cast(char)i;
		assert(UTF8ToRaw(rawToUTF8(c[])) == c[], format("%s -> %s -> %s", cast(ubyte[])c[], cast(ubyte[])rawToUTF8(c[]), cast(ubyte[])UTF8ToRaw(rawToUTF8(c[]))));
	}
}

/// Where a delegate with this signature is required.
string nullStringTransform(in char[] s) { return s.idup; }

string forceValidUTF8(string s)
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

/// Formats binary data as a hex dump (three-column layout consisting of hex
/// offset, byte values in hex, and printable low-ASCII characters).
string hexDump(const(void)[] b)
{
	auto data = cast(const(ubyte)[]) b;
	int i=0;
	string s;
	while (i<data.length)
	{
		s ~= format("%08X:  ", i);
		for (int x=0;x<16;x++)
		{
			if (i+x<data.length)
				s ~= format("%02X ", data[i+x]);
			else
				s ~= "   ";
			if (x==7)
				s ~= "| ";
		}
		s ~= "  ";
		for (int x=0;x<16;x++)
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

T fromHex(T : ulong = uint)(const(char)[] s)
{
	T result = parse!T(s, 16);
	enforce(s.length==0, new ConvException("Could not parse entire string"));
	return result;
}

const hexDigits = "0123456789abcdef";

ubyte[] arrayFromHex(string hex, ubyte[] buf = null)
{
	if (buf is null)
		buf = new ubyte[hex.length/2];
	else
		assert(buf.length == hex.length/2);
	for (int i=0; i<hex.length; i+=2)
		buf[i/2] = cast(ubyte)(
			hexDigits.indexOf(hex[i  ], CaseSensitive.no)*16 +
			hexDigits.indexOf(hex[i+1], CaseSensitive.no)
		);
	return buf;
}

string toHex()(ubyte[] data, char[] buf = null)
{
	if (buf is null)
		buf = new char[data.length*2];
	else
		assert(buf.length == data.length*2);
	foreach (i, b; data)
	{
		buf[i*2  ] = hexDigits[b>>4];
		buf[i*2+1] = hexDigits[b&15];
	}
	return assumeUnique(buf);
}

void toHex(T : ulong, size_t U = T.sizeof*2)(T n, ref char[U] buf)
{
	foreach (i; Reverse!(RangeTuple!(T.sizeof*2)))
	{
		buf[i] = hexDigits[n & 0xF];
		n >>= 4;
	}
}

unittest
{
	char[8] buf;
	toHex(0x01234567, buf);
	assert(buf == "01234567");
}

/// Get shortest string representation of a double that still converts to exactly the same number.
// TODO: generalize
string doubleToString(double v)
{
	string s = format("%.18g", v);

	/// Force IEEE double (bypass FPU register)
	static double forceDouble(double d) { static double n; n = d; return n; }

	if (s != "nan" && s != "inf" && s != "-inf")
	{
		foreach_reverse (i; 1..s.length)
			if (s[i]>='0' && s[i]<='8' && forceDouble(to!double(s[0..i] ~ cast(char)(s[i]+1)))==v)
				s = s[0..i] ~ cast(char)(s[i]+1);
		while (s.length>2 && s[$-1]!='.' && forceDouble(to!double(s[0..$-1]))==v)
			s = s[0..$-1];
	}
	return s;
}

// ************************************************************************

/// Take a string, and return a regular expression that matches that string
/// exactly (escape RE metacharacters).
string escapeRE(string s)
{
	// TODO: test

	string result;
	foreach (c; s)
		switch (c)
		{
		//	case '!':
		//	case '"':
		//	case '#':
			case '$':
		//	case '%':
		//	case '&':
			case '\'':
			case '(':
			case ')':
			case '*':
			case '+':
		//	case ',':
		//	case '-':
			case '.':
			case '/':
		//	case ':':
		//	case ';':
		//	case '<':
		//	case '=':
		//	case '>':
			case '?':
		//	case '@':
			case '[':
			case '\\':
			case ']':
			case '^':
		//	case '_':
		//	case '`':
			case '{':
			case '|':
			case '}':
		//	case '~':
				result ~= '\\';
				goto default;
			default:
				result ~= c;
		}
	return result;
}

// We only need to make sure that there are no unescaped forward slashes
// in the regex, which would mean the end of the search pattern part of the
// regex transform. All escaped forward slashes will be unescaped during
// parsing of the regex transform (which won't affect the regex, as forward
// slashes have no special meaning, escaped or unescaped).
private string escapeUnescapedSlashes(string s)
{
	bool escaped = false;
	string result;
	foreach (c; s)
	{
		if (escaped)
			escaped = false;
		else
		if (c == '\\')
			escaped = true;
		else
		if (c == '/')
			result ~= '\\';

		result ~= c;
	}
	assert(!escaped, "Regex ends with an escape");
	return result;
}

// For the replacement part, we just need to escape all forward and backslashes.
private string escapeSlashes(string s)
{
	return s.fastReplace(`\`, `\\`).fastReplace(`/`, `\/`);
}

// Reverse of the above
private string unescapeSlashes(string s)
{
	return s.fastReplace(`\/`, `/`).fastReplace(`\\`, `\`);
}

/// Build a RE search-and-replace transform (as used by applyRE).
string buildReplaceTransformation(string search, string replacement, string flags)
{
	return "s/" ~ escapeUnescapedSlashes(search) ~ "/" ~ escapeSlashes(replacement) ~ "/" ~ flags;
}

private string[] splitRETransformation(string t)
{
	enforce(t.length >= 2, "Bad transformation");
	string[] result = [t[0..1]];
	auto boundary = t[1];
	t = t[2..$];
	size_t start = 0;
	bool escaped = false;
	foreach (i, c; t)
		if (escaped)
			escaped = false;
		else
		if (c=='\\')
			escaped = true;
		else
		if (c == boundary)
		{
			result ~= t[start..i];
			start = i+1;
		}
	result ~= t[start..$];
	return result;
}

unittest
{
	assert(splitRETransformation("s/from/to/") == ["s", "from", "to", ""]);
}

/// Apply regex transformation (in the form of "s/FROM/TO/FLAGS") to a string.
string applyRE()(string str, string transformation)
{
	import std.regex;
	auto params = splitRETransformation(transformation);
	enforce(params[0] == "s", "Unsupported regex transformation");
	enforce(params.length == 4, "Wrong number of regex transformation parameters");
	auto r = regex(params[1], params[3]);
	return replace(str, r, unescapeSlashes(params[2]));
}

unittest
{
	auto transformation = buildReplaceTransformation(`(?<=\d)(?=(\d\d\d)+\b)`, `,`, "g");
	assert("12000 + 42100 = 54100".applyRE(transformation) == "12,000 + 42,100 = 54,100");

	void testSlashes(string s)
	{
		assert(s.applyRE(buildReplaceTransformation(`\/`, `\`, "g")) == s.fastReplace(`/`, `\`));
		assert(s.applyRE(buildReplaceTransformation(`\\`, `/`, "g")) == s.fastReplace(`\`, `/`));
	}
	testSlashes(`a/b\c`);
	testSlashes(`a//b\\c`);
	testSlashes(`a/\b\/c`);
	testSlashes(`a/\\b\//c`);
	testSlashes(`a//\b\\/c`);
}

// ************************************************************************

import std.random;

string randomString(int length=20, string chars="abcdefghijklmnopqrstuvwxyz")
{
	char[] result = new char[length];
	foreach (ref c; result)
		c = chars[uniform(0, $)];
	return assumeUnique(result);
}
