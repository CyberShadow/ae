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

struct CustomXmlWriter(WRITER, bool PRETTY)
{
	/// You can set this to something to e.g. write to another buffer.
	WRITER output;

	static if (PRETTY)
	{
		uint indentLevel = 0;

		void newLine()
		{
			output.put('\n');
		}

		void startLine()
		{
			output.allocate(indentLevel)[] = '\t';
		}

		void indent () {                      indentLevel++; }
		void outdent() { assert(indentLevel); indentLevel--; }
	}

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
		static if (PRETTY) newLine();
		debug assert(tagStack.length==0);
	}

	deprecated alias text putText;

	void text(string s)
	{
		// https://gist.github.com/2192846

		auto start = s.ptr, p = start, end = start+s.length;

		while (p < end)
		{
			auto c = *p++;
			if (Escapes.escaped[c])
				output.put(start[0..p-start-1], Escapes.chars[c]),
				start = p;
		}

		output.put(start[0..p-start]);
	}

	// Common

	private enum mixStartWithAttributesGeneric =
	q{
		debug assert(!inAttributes, "Tag attributes not ended");
		static if (PRETTY) startLine();

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
		static if (PRETTY) newLine();
		debug inAttributes = false;
		debug popTag();
	};

	// startTag

	private enum mixStartTag =
	q{
		debug assert(!inAttributes, "Tag attributes not ended");
		static if (PRETTY) startLine();

		static if (STATIC)
			output.put('<' ~ name ~ '>');
		else
			output.put('<', name, '>');

		static if (PRETTY) { newLine(); indent(); }
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

		text(value);
		output.put('"');
	};

	void addAttribute(string name)(string value)   { enum STATIC = true;  mixin(mixAddAttribute); }
	void addAttribute()(string name, string value) { enum STATIC = false; mixin(mixAddAttribute); }

	// endAttributes[AndTag]

	void endAttributes()
	{
		debug assert(inAttributes, "Tag attributes not started");
		output.put('>');
		static if (PRETTY) { newLine(); indent(); }
		debug inAttributes = false;
	}

	void endAttributesAndTag() { enum CLOSE = " />"; mixin(mixEndAttributesAndTagGeneric); }

	// endTag

	private enum mixEndTag =
	q{
		debug assert(!inAttributes, "Tag attributes not ended");
		static if (PRETTY) { outdent(); startLine(); }

		static if (STATIC)
			output.put("</" ~ name ~ ">");
		else
			output.put("</", name, ">");

		static if (PRETTY) newLine();
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
		static if (PRETTY) newLine();
	}
}

alias CustomXmlWriter!(StringBuilder, false) XmlWriter;
alias CustomXmlWriter!(StringBuilder, true ) PrettyXmlWriter;

private:

private struct Escapes
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
			if (c=='"')
				chars[c] = "&quot;";
			else
			if (c < 0x20 && c != 0x0D && c != 0x0A)
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
		`<?xml version="1.0" encoding="UTF-8"?>`
		`<quotes>`
			`<quote author="Alan Perlis">`
				`When someone says, &quot;I want a programming language in which I need only say what I want done,&quot; give him a lollipop.`
			`</quote>`
		`</quotes>`);
}

// TODO: StringBuilder-compatible XML-encoding string sink/filter?
// e.g. to allow putTime to write directly to an XML node contents
