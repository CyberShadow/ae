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

	void putText(string s)
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

	// TODO: Dynamic tag and attribute names

	void startTag(string name)()
	{
		debug assert(!inAttributes, "no endAttributes");
		static if (PRETTY) startLine();
		output.put('<' ~ name ~ '>');
		static if (PRETTY) { newLine(); indent(); }
		debug pushTag(name);
	}

	void startTagWithAttributes(string name)()
	{
		debug assert(!inAttributes, "no endAttributes");
		static if (PRETTY) startLine();
		output.put('<' ~ name);
		debug inAttributes = true;
		debug pushTag(name);
	}

	void addAttribute(string name)(string value)
	{
		debug assert(inAttributes, "addAttribute without startTagWithAttributes");
		output.put(' ' ~ name ~ `="`);
		putText(value);
		output.put('"');
	}

	void endAttributes()
	{
		debug assert(inAttributes, "endAttributes without startTagWithAttributes");
		output.put('>');
		static if (PRETTY) { newLine(); indent(); }
		debug inAttributes = false;
	}

	void endAttributesAndTag()
	{
		debug assert(inAttributes, "endAttributes without startTagWithAttributes");
		output.put(" />");
		static if (PRETTY) newLine();
		debug inAttributes = false;
		debug popTag();
	}

	void endTag(string name)()
	{
		debug assert(!inAttributes, "no endAttributes");
		static if (PRETTY) { outdent(); startLine(); }
		output.put("</" ~ name ~ ">");
		static if (PRETTY) newLine();
		debug popTag(name);
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
		xml.putText(text);
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
