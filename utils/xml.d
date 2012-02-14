/**
 * Light read-only XML library
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.utils.xml;

import std.stream;
import std.string;
import std.ascii;
import std.exception;

enum XmlNodeType
{
	Root,
	Node,
	Comment,
	Meta,
	DocType,
	Text
}

class XmlNode
{
	string tag;
	string[string] attributes;
	XmlNode[] children;
	XmlNodeType type;
	ulong startPos, endPos;

	this(Stream s)
	{
		startPos = s.position;
		char c;
		do
			s.read(c);
		while (isWhite(c));

		if (c!='<')  // text node
		{
			type = XmlNodeType.Text;
			string text;
			while (c!='<')
			{
				// TODO: check for EOF
				text ~= c;
				s.read(c);
			}
			s.seekCur(-1); // rewind to '<'
			tag = decodeEntities(text);
			//tag = tag.strip();
		}
		else
		{
			s.read(c);
			if (c=='!')
			{
				s.read(c);
				if (c == '-') // comment
				{
					expect(s, '-');
					type = XmlNodeType.Comment;
					do
					{
						s.read(c);
						tag ~= c;
					} while (tag.length<3 || tag[$-3..$] != "-->");
					tag = tag[0..$-3];
				}
				else // doctype, etc.
				{
					type = XmlNodeType.DocType;
					while (c != '>')
					{
						tag ~= c;
						s.read(c);
					}
				}
			}
			else
			if (c=='?')
			{
				type = XmlNodeType.Meta;
				tag=readWord(s);
				if (tag.length==0) throw new Exception("Invalid tag");
				while (true)
				{
					skipWhitespace(s);
					if (peek(s)=='?')
						break;
					readAttribute(s);
				}
				s.read(c);
				expect(s, '>');
			}
			else
			if (c=='/')
				throw new Exception("Unexpected close tag");
			else
			{
				type = XmlNodeType.Node;
				tag = c~readWord(s);
				while (true)
				{
					skipWhitespace(s);
					c = peek(s);
					if (c=='>' || c=='/')
						break;
					readAttribute(s);
				}
				s.read(c);
				if (c=='>')
				{
					while (true)
					{
						skipWhitespace(s);
						if (peek(s)=='<' && peek(s, 2)=='/')
							break;
						try
							children ~= new XmlNode(s);
						catch (Exception e)
							throw new Exception("Error while processing child of "~tag, e);
					}
					expect(s, '<');
					expect(s, '/');
					foreach (tc; tag)
						expect(s, tc);
					expect(s, '>');
				}
				else
					expect(s, '>');
			}
		}
		endPos = s.position;
	}

	this(XmlNodeType type, string tag = null)
	{
		this.type = type;
		this.tag = tag;
	}

	XmlNode addAttribute(string name, string value)
	{
		attributes[name] = value;
		return this;
	}

	XmlNode addChild(XmlNode child)
	{
		children ~= child;
		return this;
	}

	override string toString()
	{
		string childrenText()
		{
			string result;
			foreach (child; children)
				result ~= child.toString();
			return result;
		}

		string attrText()
		{
			string result;
			foreach (key, value; attributes)
				result ~= ' ' ~ key ~ `="` ~ encodeEntities(value) ~ '"';
			return result;
		}

		switch(type)
		{
			case XmlNodeType.Root:
				return childrenText();
			case XmlNodeType.Node:
				return '<' ~ tag ~ attrText() ~ '>' ~ childrenText() ~ "</" ~ tag ~ '>';
			case XmlNodeType.Meta:
				assert(children.length == 0);
				return "<?" ~ tag ~ attrText() ~ "?>";
			case XmlNodeType.DocType:
				assert(children.length == 0);
				return "<!" ~ tag ~ attrText() ~ ">";
			case XmlNodeType.Text:
				return encodeEntities(tag);
			default:
				return null;
		}
	}

	string text()
	{
		switch(type)
		{
			case XmlNodeType.Text:
				return tag;
			case XmlNodeType.Node:
			case XmlNodeType.Root:
				string childrenText;
				foreach (child; children)
					childrenText ~= child.text();
				return childrenText;
			default:
				return null;
		}
	}

	final XmlNode findChild(string tag)
	{
		foreach (child; children)
			if (child.type == XmlNodeType.Node && child.tag == tag)
				return child;
		return null;
	}

	final XmlNode[] findChildren(string tag)
	{
		XmlNode[] result;
		foreach (child; children)
			if (child.type == XmlNodeType.Node && child.tag == tag)
				result ~= child;
		return result;
	}

	final XmlNode opIndex(string tag)
	{
		auto node = findChild(tag);
		if (node is null)
			throw new Exception("No such child: " ~ tag);
		return node;
	}

	final XmlNode opIndex(string tag, int index)
	{
		auto nodes = findChildren(tag);
		if (index >= nodes.length)
			throw new Exception(format("Can't get node with tag %s and index %d, there are only %d children with that tag", tag, index, nodes.length));
		return nodes[index];
	}

	final XmlNode opIndex(int index)
	{
		return children[index];
	}

	int opApply(int delegate(ref XmlNode) dg)
	{
		int result = 0;

		for (int i = 0; i < children.length; i++)
		{
			result = dg(children[i]);
			if (result)
				break;
		}
		return result;
	}

private:
	final void readAttribute(Stream s)
	{
		string name = readWord(s);
		if (name.length==0) throw new Exception("Invalid attribute");
		skipWhitespace(s);
		expect(s, '=');
		skipWhitespace(s);
		char delim;
		s.read(delim);
		if (delim != '\'' && delim != '"')
			throw new Exception("Expected ' or \'");
		string value;
		while (true)
		{
			char c;
			s.read(c);
			if (c==delim) break;
			value ~= c;
		}
		attributes[name] = decodeEntities(value);
	}
}

class XmlDocument : XmlNode
{
	this()
	{
		super(XmlNodeType.Root);
		tag = "<Root>";
	}

	this(Stream s)
	{
		this();
		skipWhitespace(s);
		while (s.position < s.size)
			try
			{
				children ~= new XmlNode(s);
				skipWhitespace(s);
			}
			catch (Exception e)
				throw new Exception(format("Error at %d", s.position), e);
	}
}

private:

char peek(Stream s, int n=1)
{
	char c;
	for (int i=0; i<n; i++)
		s.read(c);
	s.seekCur(-n);
	return c;
}

void skipWhitespace(Stream s)
{
	char c;
	do
	{
		if (s.position==s.size)
			return;
		s.read(c);
	}
	while (isWhite(c));
	s.seekCur(-1);
}

bool isWord(char c)
{
	return c=='-' || c=='_' || c==':' || isAlphaNum(c);
}

string readWord(Stream s)
{
	char c;
	string result;
	while (true)
	{
		s.read(c);
		if (!isWord(c))
			break;
		result ~= c;
	}
	s.seekCur(-1);
	return result;
}

void expect(Stream s, char c)
{
	char c2;
	s.read(c2);
	if (c!=c2)
		throw new Exception("Expected " ~ c ~ ", got " ~ c2);
}

const dchar[string] entities;
/*const*/ string[dchar] entityNames;
static this()
{
	entities =
	[
		"quot"[]: '\&quot;'  ,
		"amp"   : '\&amp;'   ,
		"lt"    : '\&lt;'    ,
		"gt"    : '\&gt;'    ,
		"circ"  : '\&circ;'  ,
		"tilde" : '\&tilde;' ,
		"nbsp"  : '\&nbsp;'  ,
		"ensp"  : '\&ensp;'  ,
		"emsp"  : '\&emsp;'  ,
		"thinsp": '\&thinsp;',
		"ndash" : '\&ndash;' ,
		"mdash" : '\&mdash;' ,
		"lsquo" : '\&lsquo;' ,
		"rsquo" : '\&rsquo;' ,
		"sbquo" : '\&sbquo;' ,
		"ldquo" : '\&ldquo;' ,
		"rdquo" : '\&rdquo;' ,
		"bdquo" : '\&bdquo;' ,
		"dagger": '\&dagger;',
		"Dagger": '\&Dagger;',
		"permil": '\&permil;',
		"lsaquo": '\&lsaquo;',
		"rsaquo": '\&rsaquo;',
		"euro"  : '\&euro;'  ,
		"copy"  : '\&copy;'  ,
		"apos"  : '\''
	];
	foreach (name, c; entities)
		entityNames[c] = name;
}

import std.utf;
import std.c.stdio;

public string encodeEntities(string str)
{
	foreach_reverse (i, c; str)
		if (c=='<' || c=='>' || c=='"' || c=='\'' || c=='&')
			str = str[0..i] ~ '&' ~ entityNames[c] ~ ';' ~ str[i+1..$];
	return str;
}

public string encodeAllEntities(string str)
{
	foreach_reverse (i, dchar c; str)
	{
		auto name = c in entityNames;
		if (name)
			str = str[0..i] ~ '&' ~ *name ~ ';' ~ str[i+stride(str,i)..$];
	}
	return str;
}

public string decodeEntities(string str)
{
	sizediff_t i=0, p;
	while ((p=str[i..$].indexOf('&'))>=0)
	{
		i += p;
		if ((p=str[i..$].indexOf(';'))>=0)
		{
			auto j = i+p;
			string entity = str[i+1..j];
			if (entity.length>0)
			{
				if (entity[0]=='#')
					if (entity.length>1 && entity[1]=='x')
					{
						dchar c;
						enforce(sscanf(toStringz(entity[2..$]), "%x", &c)==1, "Invalid entity hex code");
						str = str[0..i] ~ toUTF8([c]) ~ str[j+1..$];
					}
					else
					{
						dchar c;
						enforce(sscanf(toStringz(entity[1..$]), "%d", &c)==1, "Invalid entity code");
						str = str[0..i] ~ toUTF8([c]) ~ str[j+1..$];
					}
				else
				{
					auto c = entity in entities;
					if (c)
						str = str[0..i] ~ toUTF8([*c]) ~ str[j+1..$];
				}
			}
		}
		i++;
	}
	return str;
}

deprecated alias decodeEntities convertEntities;

unittest
{
	assert(encodeAllEntities("©,€") == "&copy;,&euro;");
	assert(decodeEntities("&copy;,&euro;") == "©,€");
}
