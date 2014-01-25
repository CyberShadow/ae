/**
 * SAX-like XML parser
 * WORK IN PROGRESS.
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

module ae.utils.xmlparser;

import std.exception;
import std.functional;
import std.range;
import std.string;
import std.typecons;

import ae.utils.range;

/// Does not allocate (except for exceptions).
/// No XML nesting state.
/// Does not check for premature stream end, paired tags, etc.
///
/// INPUT is an input range which needs to support the following
/// additional properties:
///   .ptr - returns a type usable with ptrSlice (used to save
///          the position in INPUT, then later take a slice
///          from that position until an end position).
/// WARNING: Using a narrow D string type for INPUT will result
/// in wasteful UTF decoding (due to std.array.front returning a
/// dchar).
///
/// OUTPUT accepts strings with the XML entities still encoded,
/// to allow for lazy decoding.

// TODO: namespaces, CDATA

struct XmlParser(INPUT, OUTPUT)
{
	INPUT input;
	OUTPUT output;

	alias typeof(input.front) C;
	alias std.typecons.Unqual!C U;

	void run()
	{
		output.startDocument();
		skipWhitespace();

		while (!input.empty)
		{
			if (input.front != '<')  // text node
				output.text(xmlString(readWhile!q{c != '<'}()));
			else
			{
				input.popFront();
				if (input.front=='!')
				{
					input.popFront();
					if (input.front == '-') // comment
					{
						input.popFront();
						expect('-');
						U c0, c1, c2;
						do
						{
							c0=c1; c1=c2; c2=input.front;
							input.popFront();
						} while (c0 != '-' || c1 != '-' || c2 != '>');
					}
					else // doctype, etc.
						output.directive(xmlString(readWhile!q{c != '>'}()));
				}
				else
				if (input.front=='?')
				{
					input.popFront();
					output.startProcessingInstruction(readWord());
					while (!input.empty)
					{
						skipWhitespace();
						if (input.front=='?')
							break;
						readAttribute();
					}
					input.popFront(); // '?'
					expect('>');
					output.endProcessingInstruction();
				}
				else
				if (input.front=='/')
				{
					input.popFront();
					output.endTag(readWord());
					expect('>');
				}
				else
				{
					output.startTag(readWord());
					while (!input.empty)
					{
						skipWhitespace();
						if (input.front=='>' || input.front=='/')
							break;
						readAttribute();
					}
					output.endAttributes();
					if (input.front == '/')
					{
						input.popFront();
						output.endAttributesAndTag();
						expect('>');
					}
					else
						input.popFront(); // '>'
				}
			}
			skipWhitespace();
		}

		output.endDocument();
	}

private:
	void readAttribute()
	{
		auto name = readWord();
		skipWhitespace();
		expect('=');
		skipWhitespace();
		auto delim = input.front;
		enforce(delim == '\'' || delim == '"', format("Bad attribute delimiter. Expected ' or \", got %s", delim));
		auto value = delim == '"' ? readWhile!q{c != '"'}() : readWhile!q{c != '\''}();
		output.attribute(name, xmlString(value));
	}

	void expect(C c)
	{
		enforce(input.front == c, format("Expected %s, got %s", c, input.front));
		input.popFront();
	}

	auto readWhile(alias COND)()
	{
		auto start = input.ptr;
		skipWhile!COND();
		return ptrSlice(start, input.ptr);
	}

	void skipWhile(alias COND)()
	{
		alias unaryFun!(COND, false, "c") cond;
		while (!input.empty && cond(input.front))
			input.popFront();
	}

	alias skipWhile!xmlIsWhite skipWhitespace;
	alias readWhile!xmlIsWord  readWord;
}

/// The type of a slice (using ptrSlice) of an input range used in XmlParser
template SliceType(INPUT)
{
	alias typeof(ptrSlice(T.init.ptr, T.init.ptr)) SliceType;
}

unittest
{
	// Just test compilation with a dummy receiver
	static struct DummyOutput
	{
		void opDispatch(string S, T...)(T args) { }
	}

	// Note: don't use string! This will do UTF-8 decoding.
	XmlParser!(string, DummyOutput) stringParser;

	// An example with more sensible performance
	XmlParser!(FastArrayRange!(immutable(char)), DummyOutput) fastParser;
}

// ***************************************************************************

/// Represents a string (slice of XmlParser input stream) which still contains
/// encoded XML entities.
struct XmlString(S)
{
	S encoded;
}

XmlString!S xmlString(S)(S s) { return XmlString!S(s); }

/+
import std.traits;

static import ae.utils.xmllite;

XmlString!S getXmlEncodedString(S)(S s)
	if (isSomeString!S)
{
	XmlString!S xmls;
	xmls.encoded = ae.utils.xmllite.encodeEntities(s);
	return xmls;
}

X getXmlEncodedString(X)(X x)
	if (is(X S : XmlString!S))
{
	return x;
}

auto getXmlDecodedString(X)(X x)
	if (is(X S : XmlString!S))
{
	return ae.utils.xmllite.decodeEntities(x.encoded);
}

S getXmlDecodedString(S)(S s)
	if (isSomeString!S)
{
	return s;
}

unittest
{
	auto s0 = "<";
	auto s1 = s0.getXmlDecodedString();
	assert(s0 is s1);
	auto x0 = s0.getXmlEncodedString();
	assert(x0.encoded == "&lt;");
	auto x1 = x0.getXmlEncodedString();
	assert(x0.encoded is x1.encoded);
	auto s2 = x0.getXmlDecodedString();
	assert(s0 == s2);
}
+/

// ***************************************************************************

/// Generate a fast table lookup function, which compiles to a single lookup
/// for small index types and an additional check + default value for larger
/// index types.
private template fastLookup(alias TABLE, bool DEFAULT)
{
	bool fastLookup(C)(C c) @trusted pure nothrow
	{
		static if (cast(size_t)C.max > TABLE.length)
			if (cast(size_t)c >= TABLE.length)
				return DEFAULT;
		return TABLE.ptr[cast(size_t)c];
	}
}

alias fastLookup!(xmlWhiteChars, false) xmlIsWhite;
alias fastLookup!(xmlWordChars , true ) xmlIsWord ; /// ditto

bool[256] genTable(string COND)()
{
	import std.ascii;
	bool[256] table;
	foreach (uint c, ref b; table) b = mixin(COND);
	return table;
}

immutable bool[256] xmlWhiteChars = genTable!q{isWhite   (c)                              }();
immutable bool[256] xmlWordChars  = genTable!q{isAlphaNum(c) || c=='-' || c=='_' || c==':'}();

unittest
{
	assert( xmlIsWhite(' '));
	assert(!xmlIsWhite('a'));
	assert(!xmlIsWhite('я'));
	assert(!xmlIsWord (' '));
	assert( xmlIsWord ('a'));
	assert( xmlIsWord ('я'));
}
