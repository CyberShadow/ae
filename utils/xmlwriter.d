﻿/**
 * An XML writer written for speed
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

module ae.utils.xmlwriter;

import ae.utils.textout;

/// Null formatter.
struct NullXmlFormatter
{
	/// Implementation of formatter interface.
	@property bool enabled() { return false; }
	@property void enabled(bool value) {} /// ditto

	mixin template Mixin(alias formatter)
	{
		/// Stubs.
		void newLine() {}
		void startLine() {} /// ditto
		void indent() {} /// ditto
		void outdent() {} /// ditto
	} /// ditto
}

/// Customizable formatter.
struct CustomXmlFormatter(char indentCharP, uint indentSizeP)
{
	enum indentChar = indentCharP; ///
	enum indentSize = indentSizeP; ///

	/// Implementation of formatter interface.
	bool enabled = true;

	mixin template Mixin(alias formatter)
	{
		private uint indentLevel = 0;

		/// Implementation of formatter interface.
		void newLine()
		{
			if (formatter.enabled)
				output.put('\n');
		}

		void startLine()
		{
			if (formatter.enabled)
				output.allocate(indentLevel * formatter.indentSize)[] = formatter.indentChar;
		} /// ditto

		void indent () {                      indentLevel++; } /// ditto
		void outdent() { assert(indentLevel); indentLevel--; } /// ditto
	} /// ditto
}

/// Default formatter, configured with indentation consisting of one tab character.
alias DefaultXmlFormatter = CustomXmlFormatter!('\t', 1);

/// Customizable XML writer.
struct CustomXmlWriter(WRITER, Formatter)
{
	/// You can set this to something to e.g. write to another buffer.
	WRITER output;

	/// Formatter instance.
	Formatter formatter;
	mixin Formatter.Mixin!formatter;

	private debug // verify well-formedness
	{
		string[] tagStack;
		void pushTag(string tag) { tagStack ~= tag; }
		void popTag ()
		{
			assert(tagStack.length, "No tag to close");
			tagStack = tagStack[0..$-1];
		}
		void popTag (string tag)
		{
			assert(tagStack.length, "No tag to close");
			assert(tagStack[$-1] == tag, "Closing wrong tag (" ~ tag ~ " instead of " ~ tagStack[$-1] ~ ")");
			tagStack = tagStack[0..$-1];
		}

		bool inAttributes;
	}

	/// Write the beginning of an XML document.
	void startDocument()
	{
		output.put(`<?xml version="1.0" encoding="UTF-8"?>`);
		newLine();
		debug assert(tagStack.length==0);
	}

	deprecated alias text putText;

	/// Write plain text (escaping entities).
	void text(in char[] s)
	{
		escapedText!(EscapeScope.text)(s);
	}

	/// Write attribute contents.
	alias attrText = escapedText!(EscapeScope.attribute);

	private void escapedText(EscapeScope escapeScope)(in char[] s)
	{
		// https://gist.github.com/2192846

		auto start = s.ptr, p = start, end = start+s.length;

		alias E = Escapes!escapeScope;

		while (p < end)
		{
			auto c = *p++;
			if (E.escaped[c])
				output.put(start[0..p-start-1], E.chars[c]),
				start = p;
		}

		output.put(start[0..p-start]);
	}

	// Common

	private enum mixStartWithAttributesGeneric =
	q{
		debug assert(!inAttributes, "Tag attributes not ended");
		startLine();

		static if (STATIC)
			output.put(OPEN ~ name);
		else
			output.put(OPEN, name);

		debug inAttributes = true;
		debug pushTag(name);
	};

	private enum mixEndAttributesAndTagGeneric =
	q{
		debug assert(inAttributes, "Tag attributes not started");
		output.put(CLOSE);
		newLine();
		debug inAttributes = false;
		debug popTag();
	};

	// startTag

	private enum mixStartTag =
	q{
		debug assert(!inAttributes, "Tag attributes not ended");
		startLine();

		static if (STATIC)
			output.put('<' ~ name ~ '>');
		else
			output.put('<', name, '>');

		newLine();
		indent();
		debug pushTag(name);
	};

	/// Write opening a tag (no attributes).
	void startTag(string name)() { enum STATIC = true;  mixin(mixStartTag); }
	void startTag()(string name) { enum STATIC = false; mixin(mixStartTag); } /// ditto

	// startTagWithAttributes

	/// Write opening a tag (attributes follow).
	void startTagWithAttributes(string name)() { enum STATIC = true;  enum OPEN = '<'; mixin(mixStartWithAttributesGeneric); }
	void startTagWithAttributes()(string name) { enum STATIC = false; enum OPEN = '<'; mixin(mixStartWithAttributesGeneric); } /// ditto

	// addAttribute

	private enum mixAddAttribute =
	q{
		debug assert(inAttributes, "Tag attributes not started");

		static if (STATIC)
			output.put(' ' ~ name ~ `="`);
		else
			output.put(' ', name, `="`);

		attrText(value);
		output.put('"');
	};

	/// Write tag attribute.
	void addAttribute(string name)(string value)   { enum STATIC = true;  mixin(mixAddAttribute); }
	void addAttribute()(string name, string value) { enum STATIC = false; mixin(mixAddAttribute); } /// ditto

	// endAttributes[AndTag]

	/// Write end of attributes and begin tag contents.
	void endAttributes()
	{
		debug assert(inAttributes, "Tag attributes not started");
		output.put('>');
		newLine();
		indent();
		debug inAttributes = false;
	}

	/// Write end of attributes and tag.
	void endAttributesAndTag() { enum CLOSE = "/>"; mixin(mixEndAttributesAndTagGeneric); }

	// endTag

	private enum mixEndTag =
	q{
		debug assert(!inAttributes, "Tag attributes not ended");
		outdent();
		startLine();

		static if (STATIC)
			output.put("</" ~ name ~ ">");
		else
			output.put("</", name, ">");

		newLine();
		debug popTag(name);
	};

	/// Write end of tag.
	void endTag(string name)() { enum STATIC = true;  mixin(mixEndTag); }
	void endTag()(string name) { enum STATIC = false; mixin(mixEndTag); } /// ditto

	// Processing instructions

	/// Write a processing instruction.
	void startPI(string name)() { enum STATIC = true;  enum OPEN = "<?"; mixin(mixStartWithAttributesGeneric); }
	void startPI()(string name) { enum STATIC = false; enum OPEN = "<?"; mixin(mixStartWithAttributesGeneric); } /// ditto
	void endPI() { enum CLOSE = "?>"; mixin(mixEndAttributesAndTagGeneric); } /// ditto

	// Doctypes

	deprecated alias doctype putDoctype;

	/// Write a DOCTYPE declaration.
	void doctype(string text)
	{
		debug assert(!inAttributes, "Tag attributes not ended");
		output.put("<!", text, ">");
		newLine();
	}

	/// Write an XML comment.
	void comment(string text)
	{
		debug assert(!inAttributes, "Tag attributes not ended");
		output.put("<!--", text, "-->");
		newLine();
	}
}

deprecated template CustomXmlWriter(Writer, bool pretty)
{
	static if (pretty)
		alias CustomXmlWriter = CustomXmlWriter!(Writer, DefaultXmlFormatter);
	else
		alias CustomXmlWriter = CustomXmlWriter!(Writer, NullXmlFormatter);
}

/// XML writer with no formatting.
alias CustomXmlWriter!(StringBuilder, NullXmlFormatter   ) XmlWriter;
/// XML writer with formatting.
alias CustomXmlWriter!(StringBuilder, DefaultXmlFormatter) PrettyXmlWriter;

private:

enum EscapeScope
{
	text,
	attribute,
}

private struct Escapes(EscapeScope escapeScope)
{
	static __gshared string[256] chars;
	static __gshared bool[256] escaped;

	shared static this()
	{
		import std.string;

		escaped[] = true;
		foreach (c; 0..256)
			if (c=='<')
				chars[c] = "&lt;";
			else
			if (c=='>')
				chars[c] = "&gt;";
			else
			if (c=='&')
				chars[c] = "&amp;";
			else
			if (escapeScope == EscapeScope.attribute &&
				c=='"')
				chars[c] = "&quot;";
			else
			if (c < 0x20 && c != 0x0D && c != 0x0A && c != 0x09)
				chars[c] = format("&#x%02X;", c);
			else
				chars[c] = [cast(char)c],
				escaped[c] = false;
	}
}

unittest
{
	string[string] quotes;
	quotes["Alan Perlis"] = "When someone says, \"I want a programming language in which I need only say what I want done,\" give him a lollipop.";

	XmlWriter xml;
	xml.startDocument();
	xml.startTag!"quotes"();
	foreach (author, text; quotes)
	{
		xml.startTagWithAttributes!"quote"();
		xml.addAttribute!"author"(author);
		xml.endAttributes();
		xml.text(text);
		xml.endTag!"quote"();
	}
	xml.endTag!"quotes"();

	auto str = xml.output.get();
	assert(str ==
		`<?xml version="1.0" encoding="UTF-8"?>` ~
		`<quotes>` ~
			`<quote author="Alan Perlis">` ~
				`When someone says, "I want a programming language in which I need only say what I want done," give him a lollipop.` ~
			`</quote>` ~
		`</quotes>`);
}

// TODO: StringBuilder-compatible XML-encoding string sink/filter?
// e.g. to allow putTime to write directly to an XML node contents
