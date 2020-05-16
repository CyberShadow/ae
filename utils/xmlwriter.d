/**
 * An XML writer written for speed
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

module ae.utils.xmlwriter;

import ae.utils.textout;

struct NullXmlFormatter
{
	@property bool enabled() { return false; }
	@property void enabled(bool value) {}

	mixin template Mixin(alias formatter)
	{
		void newLine() {}
		void startLine() {}
		void indent() {}
		void outdent() {}
	}
}

struct CustomXmlFormatter(char indentCharP, uint indentSizeP)
{
	enum indentChar = indentCharP;
	enum indentSize = indentSizeP;

	bool enabled = true;

	mixin template Mixin(alias formatter)
	{
		uint indentLevel = 0;

		void newLine()
		{
			if (formatter.enabled)
				output.put('\n');
		}

		void startLine()
		{
			if (formatter.enabled)
				output.allocate(indentLevel * formatter.indentSize)[] = formatter.indentChar;
		}

		void indent () {                      indentLevel++; }
		void outdent() { assert(indentLevel); indentLevel--; }
	}
}

alias DefaultXmlFormatter = CustomXmlFormatter!('\t', 1);

struct CustomXmlWriter(WRITER, Formatter)
{
	/// You can set this to something to e.g. write to another buffer.
	WRITER output;

	Formatter formatter;
	mixin Formatter.Mixin!formatter;

	debug // verify well-formedness
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

	void startDocument()
	{
		output.put(`<?xml version="1.0" encoding="UTF-8"?>`);
		newLine();
		debug assert(tagStack.length==0);
	}

	deprecated alias text putText;

	void text(in char[] s)
	{
		escapedText!(EscapeScope.text)(s);
	}

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

	void startTag(string name)() { enum STATIC = true;  mixin(mixStartTag); }
	void startTag()(string name) { enum STATIC = false; mixin(mixStartTag); }

	// startTagWithAttributes

	void startTagWithAttributes(string name)() { enum STATIC = true;  enum OPEN = '<'; mixin(mixStartWithAttributesGeneric); }
	void startTagWithAttributes()(string name) { enum STATIC = false; enum OPEN = '<'; mixin(mixStartWithAttributesGeneric); }

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

	void addAttribute(string name)(string value)   { enum STATIC = true;  mixin(mixAddAttribute); }
	void addAttribute()(string name, string value) { enum STATIC = false; mixin(mixAddAttribute); }

	// endAttributes[AndTag]

	void endAttributes()
	{
		debug assert(inAttributes, "Tag attributes not started");
		output.put('>');
		newLine();
		indent();
		debug inAttributes = false;
	}

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

	void endTag(string name)() { enum STATIC = true;  mixin(mixEndTag); }
	void endTag()(string name) { enum STATIC = false; mixin(mixEndTag); }

	// Processing instructions

	void startPI(string name)() { enum STATIC = true;  enum OPEN = "<?"; mixin(mixStartWithAttributesGeneric); }
	void startPI()(string name) { enum STATIC = false; enum OPEN = "<?"; mixin(mixStartWithAttributesGeneric); }
	void endPI() { enum CLOSE = "?>"; mixin(mixEndAttributesAndTagGeneric); }

	// Doctypes

	deprecated alias doctype putDoctype;

	void doctype(string text)
	{
		debug assert(!inAttributes, "Tag attributes not ended");
		output.put("<!", text, ">");
		newLine();
	}

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

alias CustomXmlWriter!(StringBuilder, NullXmlFormatter   ) XmlWriter;
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
