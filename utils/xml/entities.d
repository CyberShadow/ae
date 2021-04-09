/**
 * XML/HTML entity encoding/decoding.
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

module ae.utils.xml.entities;

import ae.utils.xml.common;

/// A mapping from HTML entity names to `dchar`.
const dchar[string] entities;

/// A mapping from `dchar` to the corresponding HTML entity name.
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
import std.array;
import std.exception;
import std.string : indexOf;
import std.utf;
import ae.utils.textout;

/*private*/ public string _encodeEntitiesImpl(bool unicode, alias pred)(string str)
{
	size_t i = 0;
	while (i < str.length)
	{
		size_t o = i;
		static if (unicode)
			dchar c = decode(str, i);
		else
			char c = str[i++];

		if (pred(c))
		{
			StringBuilder sb;
			sb.preallocate(str.length * 11 / 10);
			sb.put(str[0..o]);
			sb._putEncodedEntitiesImpl!(unicode, pred)(str[o..$]);
			return sb.get();
		}
	}
	return str;
}

/*private*/ public template _putEncodedEntitiesImpl(bool unicode, alias pred)
{
	void _putEncodedEntitiesImpl(Sink, S)(ref Sink sink, S str)
	{
		size_t start = 0, i = 0;
		while (i < str.length)
		{
			size_t o = i;
			static if (unicode)
				dchar c = decode(str, i);
			else
				char c = str[i++];

			if (pred(c))
			{
				sink.put(str[start..o], '&', entityNames[c], ';');
				start = i;
			}
		}
		sink.put(str[start..$]);
	}
}

/// Encode HTML entities and return the resulting string.
public alias encodeEntities = _encodeEntitiesImpl!(false, (char c) => c=='<' || c=='>' || c=='"' || c=='\'' || c=='&');

/// Write a string to a sink, encoding HTML entities.
public alias putEncodedEntities = _putEncodedEntitiesImpl!(false, (char c) => c=='<' || c=='>' || c=='"' || c=='\'' || c=='&');

/// Encode all known characters as HTML entities.
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

/// Decode HTML entities and return the resulting string.
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
