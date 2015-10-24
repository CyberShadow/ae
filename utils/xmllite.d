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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.utils.xmllite;

// TODO: better/safer handling of malformed XML

import std.string;
import std.ascii;
import std.exception;

import ae.utils.exception;
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

	void read(out char c) { c = s[position++]; }
	void seekCur(sizediff_t offset) { position += offset; }
	@property size_t size() { return s.length; }
}

// ************************************************************************

mixin DeclareException!q{XmlParseException};

enum XmlNodeType
{
	None,
	Root,
	Node,
	Comment,
	Meta,
	DocType,
	CData,
	Text
}

class XmlNode
{
	string tag;
	string[string] attributes;
	XmlNode parent;
	XmlNode[] children;
	XmlNodeType type;
	ulong startPos, endPos;

	this(ref StringStream s) { parse(this, s); }
	this(string s) { auto ss = StringStream(s); this(ss); }

	this(XmlNodeType type = XmlNodeType.None, string tag = null)
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
		child.parent = this;
		children ~= child;
		return this;
	}

	override string toString() const
	{
		XmlWriter writer;
		writeTo(writer);
		return writer.output.get();
	}

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
				output.endAttributes();
				writeChildren();
				output.endTag(tag);
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
				output.text(tag);
				return;
			case XmlNodeType.Comment:
				// TODO
				return;
			case XmlNodeType.CData:
				output.text(tag);
				return;
		}
	}

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
			throw new XmlParseException("No such child: " ~ tag);
		return node;
	}

	final XmlNode opIndex(string tag, size_t index)
	{
		auto nodes = findChildren(tag);
		if (index >= nodes.length)
			throw new XmlParseException(format("Can't get node with tag %s and index %d, there are only %d children with that tag", tag, index, nodes.length));
		return nodes[index];
	}

	final XmlNode opIndex(size_t index)
	{
		return children[index];
	}

	final @property size_t length() { return children.length; }

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

class XmlDocument : XmlNode
{
	this()
	{
		super(XmlNodeType.Root);
		tag = "<Root>";
	}

	this(ref StringStream s) { this(); parse(s); }
	this(string s) { auto ss = StringStream(s); this(ss); }

	private final void parse(ref StringStream s)
	{
		skipWhitespace(s);
		while (s.position < s.size)
			try
			{
				addChild(new XmlNode(s));
				skipWhitespace(s);
			}
			catch (XmlParseException e)
			{
				import std.algorithm.searching;
				import std.range : retro;
				throw new XmlParseException("Error at %d (%d:%d)".format(
					s.position,
					s.s[0..s.position].representation.count('\n') + 1,
					s.s[0..s.position].representation.retro.countUntil('\n'),
				), e);
			}
	}
}

XmlDocument xmlParse(T)(T source) { return new XmlDocument(source); }

private:

/// Parse an SGML-ish string into an XmlNode
XmlNode parse(string s)
{
	auto n = new XmlNode;
	auto ss = StringStream(s);
	parse(n, ss);
	return n;
}

/// Parse an SGML-ish StringStream into an XmlNode
void parse(XmlNode node, ref StringStream s)
{
	node.startPos = s.position;
	char c;
	do
		s.read(c);
	while (isWhiteChar[c]);

	if (c!='<')  // text node
	{
		node.type = XmlNodeType.Text;
		string text;
		while (c!='<')
		{
			// TODO: check for EOF
			text ~= c;
			s.read(c);
		}
		s.seekCur(-1); // rewind to '<'
		node.tag = decodeEntities(text);
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
				node.type = XmlNodeType.Comment;
				string tag;
				do
				{
					s.read(c);
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
					s.read(c);
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
					s.read(c);
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
				readAttribute(node, s);
			}
			s.read(c);
			expect(s, '>');
		}
		else
		if (c=='/')
			throw new XmlParseException("Unexpected close tag");
		else
		{
			node.type = XmlNodeType.Node;
			node.tag = c~readWord(s);
			while (true)
			{
				skipWhitespace(s);
				c = peek(s);
				if (c=='>' || c=='/')
					break;
				readAttribute(node, s);
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
						node.addChild(new XmlNode(s));
					catch (XmlParseException e)
						throw new XmlParseException("Error while processing child of "~node.tag, e);
				}
				expect(s, '<');
				expect(s, '/');
				auto word = readWord(s);
				enforce!XmlParseException(word == node.tag, "Expected </%s>, not </%s>".format(node.tag, word));
				expect(s, '>');
			}
			else
				expect(s, '>');
		}
	}
	node.endPos = s.position;
}

private:

void readAttribute(XmlNode node, ref StringStream s)
{
	string name = readWord(s);
	if (name.length==0) throw new XmlParseException("Invalid attribute");
	skipWhitespace(s);
	expect(s, '=');
	skipWhitespace(s);
	char delim;
	s.read(delim);
	if (delim != '\'' && delim != '"')
		throw new XmlParseException("Expected ' or \"");
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
	s.read(c2);
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
		`<?xml version="1.0" encoding="UTF-8"?>`
		`<quotes>`
			`<quote author="Alan Perlis">`
				`When someone says, &quot;I want a programming language in which I need only say what I want done,&quot; give him a lollipop.`
			`</quote>`
		`</quotes>`;
	auto doc = new XmlDocument(xmlText);
	assert(doc.toString() == xmlText);
}

const dchar[string] entities;
/*const*/ string[dchar] entityNames;
shared static this()
{
	entities =
	[
		"quot" : '\&quot;',
		"amp" : '\&amp;',
		"lt" : '\&lt;',
		"gt" : '\&gt;',

		"OElig" : '\&OElig;',
		"oelig" : '\&oelig;',
		"Scaron" : '\&Scaron;',
		"scaron" : '\&scaron;',
		"Yuml" : '\&Yuml;',
		"circ" : '\&circ;',
		"tilde" : '\&tilde;',
		"ensp" : '\&ensp;',
		"emsp" : '\&emsp;',
		"thinsp" : '\&thinsp;',
		"zwnj" : '\&zwnj;',
		"zwj" : '\&zwj;',
		"lrm" : '\&lrm;',
		"rlm" : '\&rlm;',
		"ndash" : '\&ndash;',
		"mdash" : '\&mdash;',
		"lsquo" : '\&lsquo;',
		"rsquo" : '\&rsquo;',
		"sbquo" : '\&sbquo;',
		"ldquo" : '\&ldquo;',
		"rdquo" : '\&rdquo;',
		"bdquo" : '\&bdquo;',
		"dagger" : '\&dagger;',
		"Dagger" : '\&Dagger;',
		"permil" : '\&permil;',
		"lsaquo" : '\&lsaquo;',
		"rsaquo" : '\&rsaquo;',
		"euro" : '\&euro;',

		"nbsp" : '\&nbsp;',
		"iexcl" : '\&iexcl;',
		"cent" : '\&cent;',
		"pound" : '\&pound;',
		"curren" : '\&curren;',
		"yen" : '\&yen;',
		"brvbar" : '\&brvbar;',
		"sect" : '\&sect;',
		"uml" : '\&uml;',
		"copy" : '\&copy;',
		"ordf" : '\&ordf;',
		"laquo" : '\&laquo;',
		"not" : '\&not;',
		"shy" : '\&shy;',
		"reg" : '\&reg;',
		"macr" : '\&macr;',
		"deg" : '\&deg;',
		"plusmn" : '\&plusmn;',
		"sup2" : '\&sup2;',
		"sup3" : '\&sup3;',
		"acute" : '\&acute;',
		"micro" : '\&micro;',
		"para" : '\&para;',
		"middot" : '\&middot;',
		"cedil" : '\&cedil;',
		"sup1" : '\&sup1;',
		"ordm" : '\&ordm;',
		"raquo" : '\&raquo;',
		"frac14" : '\&frac14;',
		"frac12" : '\&frac12;',
		"frac34" : '\&frac34;',
		"iquest" : '\&iquest;',
		"Agrave" : '\&Agrave;',
		"Aacute" : '\&Aacute;',
		"Acirc" : '\&Acirc;',
		"Atilde" : '\&Atilde;',
		"Auml" : '\&Auml;',
		"Aring" : '\&Aring;',
		"AElig" : '\&AElig;',
		"Ccedil" : '\&Ccedil;',
		"Egrave" : '\&Egrave;',
		"Eacute" : '\&Eacute;',
		"Ecirc" : '\&Ecirc;',
		"Euml" : '\&Euml;',
		"Igrave" : '\&Igrave;',
		"Iacute" : '\&Iacute;',
		"Icirc" : '\&Icirc;',
		"Iuml" : '\&Iuml;',
		"ETH" : '\&ETH;',
		"Ntilde" : '\&Ntilde;',
		"Ograve" : '\&Ograve;',
		"Oacute" : '\&Oacute;',
		"Ocirc" : '\&Ocirc;',
		"Otilde" : '\&Otilde;',
		"Ouml" : '\&Ouml;',
		"times" : '\&times;',
		"Oslash" : '\&Oslash;',
		"Ugrave" : '\&Ugrave;',
		"Uacute" : '\&Uacute;',
		"Ucirc" : '\&Ucirc;',
		"Uuml" : '\&Uuml;',
		"Yacute" : '\&Yacute;',
		"THORN" : '\&THORN;',
		"szlig" : '\&szlig;',
		"agrave" : '\&agrave;',
		"aacute" : '\&aacute;',
		"acirc" : '\&acirc;',
		"atilde" : '\&atilde;',
		"auml" : '\&auml;',
		"aring" : '\&aring;',
		"aelig" : '\&aelig;',
		"ccedil" : '\&ccedil;',
		"egrave" : '\&egrave;',
		"eacute" : '\&eacute;',
		"ecirc" : '\&ecirc;',
		"euml" : '\&euml;',
		"igrave" : '\&igrave;',
		"iacute" : '\&iacute;',
		"icirc" : '\&icirc;',
		"iuml" : '\&iuml;',
		"eth" : '\&eth;',
		"ntilde" : '\&ntilde;',
		"ograve" : '\&ograve;',
		"oacute" : '\&oacute;',
		"ocirc" : '\&ocirc;',
		"otilde" : '\&otilde;',
		"ouml" : '\&ouml;',
		"divide" : '\&divide;',
		"oslash" : '\&oslash;',
		"ugrave" : '\&ugrave;',
		"uacute" : '\&uacute;',
		"ucirc" : '\&ucirc;',
		"uuml" : '\&uuml;',
		"yacute" : '\&yacute;',
		"thorn" : '\&thorn;',
		"yuml" : '\&yuml;',

		"fnof" : '\&fnof;',
		"Alpha" : '\&Alpha;',
		"Beta" : '\&Beta;',
		"Gamma" : '\&Gamma;',
		"Delta" : '\&Delta;',
		"Epsilon" : '\&Epsilon;',
		"Zeta" : '\&Zeta;',
		"Eta" : '\&Eta;',
		"Theta" : '\&Theta;',
		"Iota" : '\&Iota;',
		"Kappa" : '\&Kappa;',
		"Lambda" : '\&Lambda;',
		"Mu" : '\&Mu;',
		"Nu" : '\&Nu;',
		"Xi" : '\&Xi;',
		"Omicron" : '\&Omicron;',
		"Pi" : '\&Pi;',
		"Rho" : '\&Rho;',
		"Sigma" : '\&Sigma;',
		"Tau" : '\&Tau;',
		"Upsilon" : '\&Upsilon;',
		"Phi" : '\&Phi;',
		"Chi" : '\&Chi;',
		"Psi" : '\&Psi;',
		"Omega" : '\&Omega;',
		"alpha" : '\&alpha;',
		"beta" : '\&beta;',
		"gamma" : '\&gamma;',
		"delta" : '\&delta;',
		"epsilon" : '\&epsilon;',
		"zeta" : '\&zeta;',
		"eta" : '\&eta;',
		"theta" : '\&theta;',
		"iota" : '\&iota;',
		"kappa" : '\&kappa;',
		"lambda" : '\&lambda;',
		"mu" : '\&mu;',
		"nu" : '\&nu;',
		"xi" : '\&xi;',
		"omicron" : '\&omicron;',
		"pi" : '\&pi;',
		"rho" : '\&rho;',
		"sigmaf" : '\&sigmaf;',
		"sigma" : '\&sigma;',
		"tau" : '\&tau;',
		"upsilon" : '\&upsilon;',
		"phi" : '\&phi;',
		"chi" : '\&chi;',
		"psi" : '\&psi;',
		"omega" : '\&omega;',
		"thetasym" : '\&thetasym;',
		"upsih" : '\&upsih;',
		"piv" : '\&piv;',
		"bull" : '\&bull;',
		"hellip" : '\&hellip;',
		"prime" : '\&prime;',
		"Prime" : '\&Prime;',
		"oline" : '\&oline;',
		"frasl" : '\&frasl;',
		"weierp" : '\&weierp;',
		"image" : '\&image;',
		"real" : '\&real;',
		"trade" : '\&trade;',
		"alefsym" : '\&alefsym;',
		"larr" : '\&larr;',
		"uarr" : '\&uarr;',
		"rarr" : '\&rarr;',
		"darr" : '\&darr;',
		"harr" : '\&harr;',
		"crarr" : '\&crarr;',
		"lArr" : '\&lArr;',
		"uArr" : '\&uArr;',
		"rArr" : '\&rArr;',
		"dArr" : '\&dArr;',
		"hArr" : '\&hArr;',
		"forall" : '\&forall;',
		"part" : '\&part;',
		"exist" : '\&exist;',
		"empty" : '\&empty;',
		"nabla" : '\&nabla;',
		"isin" : '\&isin;',
		"notin" : '\&notin;',
		"ni" : '\&ni;',
		"prod" : '\&prod;',
		"sum" : '\&sum;',
		"minus" : '\&minus;',
		"lowast" : '\&lowast;',
		"radic" : '\&radic;',
		"prop" : '\&prop;',
		"infin" : '\&infin;',
		"ang" : '\&ang;',
		"and" : '\&and;',
		"or" : '\&or;',
		"cap" : '\&cap;',
		"cup" : '\&cup;',
		"int" : '\&int;',
		"there4" : '\&there4;',
		"sim" : '\&sim;',
		"cong" : '\&cong;',
		"asymp" : '\&asymp;',
		"ne" : '\&ne;',
		"equiv" : '\&equiv;',
		"le" : '\&le;',
		"ge" : '\&ge;',
		"sub" : '\&sub;',
		"sup" : '\&sup;',
		"nsub" : '\&nsub;',
		"sube" : '\&sube;',
		"supe" : '\&supe;',
		"oplus" : '\&oplus;',
		"otimes" : '\&otimes;',
		"perp" : '\&perp;',
		"sdot" : '\&sdot;',
		"lceil" : '\&lceil;',
		"rceil" : '\&rceil;',
		"lfloor" : '\&lfloor;',
		"rfloor" : '\&rfloor;',
		"loz" : '\&loz;',
		"spades" : '\&spades;',
		"clubs" : '\&clubs;',
		"hearts" : '\&hearts;',
		"diams" : '\&diams;',
		"lang" : '\&lang;',
		"rang" : '\&rang;',

		"apos"  : '\''
	];
	foreach (name, c; entities)
		entityNames[c] = name;
}

import core.stdc.stdio;
import std.utf;
import ae.utils.textout;

public string encodeEntities(string str)
{
	foreach (i, c; str)
		if (c=='<' || c=='>' || c=='"' || c=='\'' || c=='&')
		{
			StringBuilder sb;
			sb.preallocate(str.length * 11 / 10);
			sb.put(str[0..i]);
			sb.putEncodedEntities(str[i..$]);
			return sb.get();
		}
	return str;
}

public void putEncodedEntities(Sink, S)(ref Sink sink, S str)
{
	size_t start = 0;
	foreach (i, c; str)
		if (c=='<' || c=='>' || c=='"' || c=='\'' || c=='&')
		{
			sink.put(str[start..i], '&', entityNames[c], ';');
			start = i+1;
		}
	sink.put(str[start..$]);
}

public string encodeAllEntities(string str)
{
	// TODO: optimize
	foreach_reverse (i, dchar c; str)
	{
		auto name = c in entityNames;
		if (name)
			str = str[0..i] ~ '&' ~ *name ~ ';' ~ str[i+stride(str,i)..$];
	}
	return str;
}

import ae.utils.text;
import std.conv;

public string decodeEntities(string str)
{
	auto fragments = str.fastSplit('&');
	if (fragments.length <= 1)
		return str;

	auto interleaved = new string[fragments.length*2 - 1];
	auto buffers = new char[4][fragments.length-1];
	interleaved[0] = fragments[0];

	foreach (n, fragment; fragments[1..$])
	{
		auto p = fragment.indexOf(';');
		enforce!XmlParseException(p>0, "Invalid entity (unescaped ampersand?)");

		dchar c;
		if (fragment[0]=='#')
		{
			if (fragment[1]=='x')
				c = fromHex!uint(fragment[2..p]);
			else
				c = to!uint(fragment[1..p]);
		}
		else
		{
			auto pentity = fragment[0..p] in entities;
			enforce!XmlParseException(pentity, "Unknown entity: " ~ fragment[0..p]);
			c = *pentity;
		}

		interleaved[1+n*2] = cast(string) buffers[n][0..std.utf.encode(buffers[n], c)];
		interleaved[2+n*2] = fragment[p+1..$];
	}

	return interleaved.join();
}

deprecated alias decodeEntities convertEntities;

unittest
{
	assert(encodeEntities(`The <Smith & Wesson> "lock'n'load"`) == `The &lt;Smith &amp; Wesson&gt; &quot;lock&apos;n&apos;load&quot;`);
	assert(encodeAllEntities("©,€") == "&copy;,&euro;");
	assert(decodeEntities("&copy;,&euro;") == "©,€");
}
