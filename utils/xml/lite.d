/**
 * Light read-only XML library
 * May be deprecated in the future.
 * See other XML modules for better implementations.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.utils.xml.lite;

// TODO: better/safer handling of malformed XML

import std.string;
import std.ascii;
import std.exception;

import ae.utils.array;
import ae.utils.xml.common;
import ae.utils.xml.entities;
import ae.utils.xmlwriter;

// ************************************************************************

/// std.stream.Stream-like type with bonus speed
private struct StringStream
{
	string s;
	size_t position;

	@disable this();
	@disable this(this);
	this(string s)
	{
		enum ditch = "'\">\0\0\0\0\0"; // Dirty precaution
		this.s = (s ~ ditch)[0..$-ditch.length];
	}

	char read() { return s[position++]; }
	@property size_t size() { return s.length; }
}

// ************************************************************************

/// The type of an `XmlNode`.
enum XmlNodeType
{
	None    , /// Initial value. Never created during parsing.
	Root    , /// The root node. Contains top-level nodes as children.
	Node    , /// XML tag.
	Comment , /// XML comment.
	Meta    , /// XML processing instruction.
	DocType , /// XML doctype declaration.
	CData   , /// CDATA node.
	Text    , /// Text node.
	Raw     , /// Never created during parsing. Programs can put raw XML fragments in `Raw` nodes to emit it as-is.
}

/// Type used to hold a tag node's attributes.
alias XmlAttributes = OrderedMap!(string, string);

/// An XML node.
class XmlNode
{
	string tag; /// The tag name, or the contents for text / comment / CDATA nodes.
	XmlAttributes attributes; /// Tag attributes.
	XmlNode parent; /// Parent node.
	XmlNode[] children; /// Children nodes.
	XmlNodeType type; /// Node type.
	/// Start and end offset within the input.
	ulong startPos, endPos;

	this(ref StringStream s) { parseInto!XmlParseConfig(this, s, null); }
	/// Create and parse from input.
	this(string s) { auto ss = StringStream(s); this(ss); }

	/// Create a new node.
	this(XmlNodeType type = XmlNodeType.None, string tag = null)
	{
		this.type = type;
		this.tag = tag;
	}

	/// Set an attribute with the given value.
	XmlNode addAttribute(string name, string value)
	{
		attributes[name] = value;
		return this;
	}

	/// Add a child node, making this node its parent.
	XmlNode addChild(XmlNode child)
	{
		child.parent = this;
		children ~= child;
		return this;
	}

	/// Return XML string.
	override string toString() const
	{
		XmlWriter writer;
		writeTo(writer);
		return writer.output.get();
	}

	/// Return pretty-printed XML string (with indentation).
	string toPrettyString() const
	{
		PrettyXmlWriter writer;
		writeTo(writer);
		return writer.output.get();
	}

	/// Write to an `XmlWriter`.
	final void writeTo(XmlWriter)(ref XmlWriter output) const
	{
		void writeChildren()
		{
			foreach (child; children)
				child.writeTo(output);
		}

		void writeAttributes()
		{
			foreach (key, value; attributes)
				output.addAttribute(key, value);
		}

		final switch (type)
		{
			case XmlNodeType.None:
				assert(false);
			case XmlNodeType.Root:
				writeChildren();
				return;
			case XmlNodeType.Node:
				output.startTagWithAttributes(tag);
				writeAttributes();
				if (children.length)
				{
					bool oneLine = children.length == 1 && children[0].type == XmlNodeType.Text;
					if (oneLine)
						output.formatter.enabled = false;
					output.endAttributes();
					writeChildren();
					output.endTag(tag);
					if (oneLine)
					{
						output.formatter.enabled = true;
						output.newLine();
					}
				}
				else
					output.endAttributesAndTag();
				return;
			case XmlNodeType.Meta:
				assert(children.length == 0);
				output.startPI(tag);
				writeAttributes();
				output.endPI();
				return;
			case XmlNodeType.DocType:
				assert(children.length == 0);
				output.doctype(tag);
				return;
			case XmlNodeType.Text:
				output.startLine();
				output.text(tag);
				output.newLine();
				return;
			case XmlNodeType.Comment:
				output.startLine();
				output.comment(tag);
				return;
			case XmlNodeType.CData:
				output.text(tag);
				return;
			case XmlNodeType.Raw:
				output.startLine();
				output.output.put(tag);
				output.newLine();
				return;
		}
	}

	/// Attempts to retrieve the text contents of this node.
	/// `<br>` tags are converted to newlines.
	@property string text()
	{
		final switch (type)
		{
			case XmlNodeType.None:
				assert(false);
			case XmlNodeType.Text:
			case XmlNodeType.CData:
				return tag;
			case XmlNodeType.Node:
			case XmlNodeType.Root:
				string result;
				if (tag == "br")
					result = "\n";
				foreach (child; children)
					result ~= child.text();
				return result;
			case XmlNodeType.Comment:
			case XmlNodeType.Meta:
			case XmlNodeType.DocType:
				return null;
			case XmlNodeType.Raw:
				assert(false, "Can't extract text from Raw nodes");
		}
	}

	/// Returns the first immediate child which is a tag and has the tag name `tag`.
	final XmlNode findChild(string tag)
	{
		foreach (child; children)
			if (child.type == XmlNodeType.Node && child.tag == tag)
				return child;
		return null;
	}

	/// Returns all immediate children which are a tag and have the tag name `tag`.
	final XmlNode[] findChildren(string tag)
	{
		XmlNode[] result;
		foreach (child; children)
			if (child.type == XmlNodeType.Node && child.tag == tag)
				result ~= child;
		return result;
	}

	/// Like `findChild`, but throws an exception if no such node is found.
	final XmlNode opIndex(string tag)
	{
		auto node = findChild(tag);
		if (node is null)
			throw new XmlParseException("No such child: " ~ tag);
		return node;
	}

	/// Like `findChildren[index]`, but throws an
	/// exception if there are not enough such nodes.
	final XmlNode opIndex(string tag, size_t index)
	{
		auto nodes = findChildren(tag);
		if (index >= nodes.length)
			throw new XmlParseException(format("Can't get node with tag %s and index %d, there are only %d children with that tag", tag, index, nodes.length));
		return nodes[index];
	}

	/// Returns the immediate child with the given index.
	final ref XmlNode opIndex(size_t index)
	{
		return children[index];
	}

	/// Returns the number of children nodes.
	final @property size_t length() { return children.length; }
	alias opDollar = length; /// ditto

	/// Iterates over immediate children.
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

	/// Creates a deep copy of this node.
	final @property XmlNode dup()
	{
		auto result = new XmlNode(type, tag);
		result.attributes = attributes.dup;
		result.children.reserve(children.length);
		foreach (child; children)
			result.addChild(child.dup);
		return result;
	}
}

/// Root node representing a parsed XML document.
class XmlDocument : XmlNode
{
	this()
	{
		super(XmlNodeType.Root);
		tag = "<Root>";
	} ///

	this(ref StringStream s) { this(); parseInto!XmlParseConfig(this, s); }

	/// Create and parse from input.
	this(string s) { auto ss = StringStream(s); this(ss); }

	/// Creates a deep copy of this document.
	final @property XmlDocument dup()
	{
		auto result = new XmlDocument();
		result.children = super.dup().children;
		return result;
	}
}

/// The logic for how to handle a node's closing tags.
enum NodeCloseMode
{
	/// This element must always have an explicit closing tag
	/// (or a self-closing tag). An unclosed tag will lead to
	/// a parse error.
	/// In XML, all tags are "always".
	always,
/*
	/// Close tags are optional. When an element with a tag is
	/// encountered directly under an element with the same tag,
	/// it is assumed that the first element is closed before
	/// the second, so the two are siblings, not parent/child.
	/// Thus, `<p>a<p>b</p>` is parsed as `<p>a</p><p>b</p>`,
	/// not `<p>a<p>b</p></p>`, however `<p>a<div><p>b</div>` is
	/// still parsed as `<p>a<div><p>b</p></div></p>`.
	/// This mode can be used for relaxed HTML parsing.
	optional,
*/
	/// Close tags are optional, but are implied when absent.
	/// As a result, these elements cannot have any content,
	/// and any close tags must be adjacent to the open tag.
	implicit,

	/// This element is void and must never have a closing tag.
	/// It is always implicitly closed right after opening.
	/// A close tag is always an error.
	/// This mode can be used for strict parsing of HTML5 void
	/// elements.
	never,
}

/// Configuration for parsing XML.
struct XmlParseConfig
{
static:
	NodeCloseMode nodeCloseMode(string tag) { return NodeCloseMode.always; } ///
	bool preserveWhitespace(string tag) { return false; } ///
	enum optionalParameterValues = false; ///
}

/// Configuration for strict parsing of HTML5.
/// All void tags must never be closed, and all
/// non-void tags must always be explicitly closed.
/// Attributes must still be quoted like in XML.
struct Html5StrictParseConfig
{
static:
	immutable voidElements = [
		"area"   , "base"  , "br"   , "col" ,
		"command", "embed" , "hr"   , "img" ,
		"input"  , "keygen", "link" , "meta",
		"param"  , "source", "track", "wbr" ,
	]; ///

	NodeCloseMode nodeCloseMode(string tag)
	{
		return tag.isOneOf(voidElements)
			? NodeCloseMode.never
			: NodeCloseMode.always
		;
	} ///

	enum optionalParameterValues = true; ///
	bool preserveWhitespace(string tag) { return false; /*TODO*/ } ///
}

/// Parse an SGML-ish string into an XmlNode
alias parse = parseString!XmlNode;

/// Parse an SGML-ish string into an XmlDocument
alias parseDocument = parseString!XmlDocument;

/// Parse an XML string into an XmlDocument.
alias xmlParse = parseDocument!XmlParseConfig;

private:

public // alias
template parseString(Node)
{
	Node parseString(Config)(string s)
	{
		auto ss = StringStream(s);
		alias f = parseStream!Node;
		return f!Config(ss);
	}
}

template parseStream(Node)
{
	Node parseStream(Config)(ref StringStream s)
	{
		auto n = new Node;
		parseInto!Config(n, s);
		return n;
	}
}

alias parseNode = parseStream!XmlNode;

/// Parse an SGML-ish StringStream into an XmlDocument
void parseInto(Config)(XmlDocument d, ref StringStream s)
{
	skipWhitespace(s);
	while (s.position < s.size)
		try
		{
			auto n = new XmlNode;
			parseInto!Config(n, s, null);
			d.addChild(n);
			skipWhitespace(s);
		}
		catch (XmlParseException e)
		{
			import std.algorithm.searching;
			import std.range : retro;

			auto head = s.s[0..s.position];
			auto row    = head.representation.count('\n');
			auto column = head.representation.retro.countUntil('\n');
			if (column < 0)
				column = head.length;
			throw new XmlParseException("Error at %d:%d (offset %d)".format(
				1 + row,
				1 + column,
				head.length,
			), e);
		}
}

/// Parse an SGML-ish StringStream into an XmlNode
void parseInto(Config)(XmlNode node, ref StringStream s, string parentTag = null, bool preserveWhitespace = false)
{
	char c;

	preserveWhitespace |= Config.preserveWhitespace(parentTag);
	if (preserveWhitespace)
		c = s.read();
	else
		do
			c = s.read();
		while (isWhiteChar[c]);

	node.startPos = s.position;
	if (c!='<')  // text node
	{
		node.type = XmlNodeType.Text;
		string text;
		while (c!='<')
		{
			// TODO: check for EOF
			text ~= c;
			c = s.read();
		}
		s.position--; // rewind to '<'
		if (!preserveWhitespace)
			while (text.length && isWhiteChar[text[$-1]])
				text = text[0..$-1];
		node.tag = decodeEntities(text);
		//tag = tag.strip();
	}
	else
	{
		c = s.read();
		if (c=='!')
		{
			c = s.read();
			if (c == '-') // comment
			{
				expect(s, '-');
				node.type = XmlNodeType.Comment;
				string tag;
				do
				{
					c = s.read();
					tag ~= c;
				} while (tag.length<3 || tag[$-3..$] != "-->");
				tag = tag[0..$-3];
				node.tag = tag;
			}
			else
			if (c == '[') // CDATA
			{
				foreach (x; "CDATA[")
					expect(s, x);
				node.type = XmlNodeType.CData;
				string tag;
				do
				{
					c = s.read();
					tag ~= c;
				} while (tag.length<3 || tag[$-3..$] != "]]>");
				tag = tag[0..$-3];
				node.tag = tag;
			}
			else // doctype, etc.
			{
				node.type = XmlNodeType.DocType;
				while (c != '>')
				{
					node.tag ~= c;
					c = s.read();
				}
			}
		}
		else
		if (c=='?')
		{
			node.type = XmlNodeType.Meta;
			node.tag = readWord(s);
			if (node.tag.length==0) throw new XmlParseException("Invalid tag");
			while (true)
			{
				skipWhitespace(s);
				if (peek(s)=='?')
					break;
				readAttribute!Config(node, s);
			}
			c = s.read();
			expect(s, '>');
		}
		else
		if (c=='/')
			throw new XmlParseException("Unexpected close tag");
		else
		{
			node.type = XmlNodeType.Node;
			s.position--;
			node.tag = readWord(s);
			while (true)
			{
				skipWhitespace(s);
				c = peek(s);
				if (c=='>' || c=='/')
					break;
				readAttribute!Config(node, s);
			}
			c = s.read();

			auto closeMode = Config.nodeCloseMode(node.tag);
			if (closeMode == NodeCloseMode.never)
				enforce!XmlParseException(c=='>', "Self-closing void tag <%s>".format(node.tag));
			else
			if (closeMode == NodeCloseMode.implicit)
			{
				if (c == '/')
					expect(s, '>');
			}
			else
			{
				if (c=='>')
				{
					while (true)
					{
						while (true)
						{
							if (!preserveWhitespace && !Config.preserveWhitespace(node.tag))
								skipWhitespace(s);
							if (peek(s)=='<' && peek(s, 2)=='/')
								break;
							try
							{
								auto child = new XmlNode;
								parseInto!Config(child, s, node.tag, preserveWhitespace);
								node.addChild(child);
							}
							catch (XmlParseException e)
								throw new XmlParseException("Error while processing child of "~node.tag, e);
						}
						expect(s, '<');
						expect(s, '/');
						auto word = readWord(s);
						if (word != node.tag)
						{
							auto closeMode2 = Config.nodeCloseMode(word);
							if (closeMode2 == NodeCloseMode.implicit)
							{
								auto parent = node.parent;
								enforce!XmlParseException(parent, "Top-level close tag for implicitly-closed node </%s>".format(word));
								enforce!XmlParseException(parent.children.length, "First-child close tag for implicitly-closed node </%s>".format(word));
								enforce!XmlParseException(parent.children[$-1].tag == word, "Non-empty implicitly-closed node <%s>".format(word));
								continue;
							}
							else
								enforce!XmlParseException(word == node.tag, "Expected </%s>, not </%s>".format(node.tag, word));
						}
						expect(s, '>');
						break;
					}
				}
				else // '/'
					expect(s, '>');
			}
		}
	}
	node.endPos = s.position;
}

private:

void readAttribute(Config)(XmlNode node, ref StringStream s)
{
	string name = readWord(s);
	if (name.length==0) throw new XmlParseException("Invalid attribute");
	skipWhitespace(s);

	static if (Config.optionalParameterValues)
	{
		if (peek(s) != '=')
		{
			node.attributes[name] = null;
			return;
		}
	}

	expect(s, '=');
	skipWhitespace(s);
	char delim;
	delim = s.read();
	if (delim != '\'' && delim != '"')
		throw new XmlParseException("Expected ' or \", not %s".format(delim));
	string value = readUntil(s, delim);
	node.attributes[name] = decodeEntities(value);
}

char peek(ref StringStream s, int n=1)
{
	return s.s[s.position + n - 1];
}

void skipWhitespace(ref StringStream s)
{
	while (isWhiteChar[s.s.ptr[s.position]])
		s.position++;
}

__gshared bool[256] isWhiteChar, isWordChar;

shared static this()
{
	foreach (c; 0..256)
	{
		isWhiteChar[c] = isWhite(c);
		isWordChar[c] = c=='-' || c=='_' || c==':' || isAlphaNum(c);
	}
}

string readWord(ref StringStream stream)
{
	auto start = stream.s.ptr + stream.position;
	auto end = stream.s.ptr + stream.s.length;
	auto p = start;
	while (p < end && isWordChar[*p])
		p++;
	auto len = p-start;
	stream.position += len;
	return start[0..len];
}

void expect(ref StringStream s, char c)
{
	char c2;
	c2 = s.read();
	enforce!XmlParseException(c==c2, "Expected " ~ c ~ ", got " ~ c2);
}

string readUntil(ref StringStream s, char until)
{
	auto start = s.s.ptr + s.position;
	auto p = start;
	while (*p != until) p++;
	auto len = p-start;
	s.position += len + 1;
	return start[0..len];
}

unittest
{
	enum xmlText =
		`<?xml version="1.0" encoding="UTF-8"?>` ~
		`<quotes>` ~
			`<quote author="Alan Perlis">` ~
				`When someone says, "I want a programming language in which I need only say what I want done," give him a lollipop.` ~
			`</quote>` ~
		`</quotes>`;
	auto doc = new XmlDocument(xmlText);
	assert(doc.toString() == xmlText, doc.toString());
}

unittest
{
	string testOne(bool preserve)(string s)
	{
		static struct ParseConfig
		{
		static:
			NodeCloseMode nodeCloseMode(string tag) { return XmlParseConfig.nodeCloseMode(tag); }
			bool preserveWhitespace(string tag) { return preserve; }
			enum optionalParameterValues = XmlParseConfig.optionalParameterValues;
		}
		auto node = new XmlNode;
		auto str = StringStream("<tag>" ~ s ~ "</tag>");
		parseInto!ParseConfig(node, str, null);
		// import std.stdio; writeln(preserve, ": ", str.s, " -> ", node.toString);
		return node.children.length ? node.children[0].tag : null;
	}

	foreach (tag; ["a", " a", "a ", " a ", " a  a ", " ", ""])
	{
		assert(testOne!false(tag) == strip(tag),
			"Parsing <tag>" ~ tag ~ "</tag> while not preserving whitespace, expecting '" ~ strip(tag) ~ "', got '" ~ testOne!false(tag) ~ "'");
		assert(testOne!true(tag) == tag,
			"Parsing <tag>" ~ tag ~ "</tag> while preserving whitespace, expecting '" ~ tag ~ "', got '" ~ testOne!true(tag) ~ "'");
	}
}

unittest
{
	static struct ParseConfig
	{
	static:
		NodeCloseMode nodeCloseMode(string tag) { return XmlParseConfig.nodeCloseMode(tag); }
		bool preserveWhitespace(string tag) { return tag == "a"; }
		enum optionalParameterValues = XmlParseConfig.optionalParameterValues;
	}
	auto node = new XmlNode;
	auto str = StringStream("<a><b> foo </b></a>");
	parseInto!ParseConfig(node, str, null);
	assert(node.children[0].children[0].tag == " foo ");
}
