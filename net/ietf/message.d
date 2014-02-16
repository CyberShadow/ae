/**
 * Parses and handles Internet mail/news messages.
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

module ae.net.ietf.message;

import std.algorithm;
import std.array;
import std.base64;
import std.conv;
import std.datetime;
import std.exception;
import std.regex;
import std.string;
import std.uri;
import std.utf;

// TODO: Replace with logging?
debug(RFC850) import std.stdio : stderr;

import ae.net.ietf.headers;
import ae.utils.array;
import ae.utils.iconv;
import ae.utils.mime;
import ae.utils.text;
import ae.utils.time;

import ae.net.ietf.wrap;

alias ae.utils.iconv.ascii ascii; // https://d.puremagic.com/issues/show_bug.cgi?id=12156
alias std.string.indexOf indexOf;

struct Xref
{
	string group;
	int num;
}

class Rfc850Message
{
	/// The raw message (as passed in a constructor).
	ascii message;

	/// The message ID, as specified at creation or in the Message-ID field.
	/// Includes the usual angular brackets.
	string id;

	/// Cross-references - for newsgroups posts, list of groups where it was
	/// posted, and article number in said group.
	Xref[] xref;

	/// The thread subject, with the leading "Re: " and list ID stripped.
	string subject;

	/// The original message subject, as it appears in the message.
	string rawSubject;

	/// The author's name, in UTF-8, stripped of quotes (no email address).
	string author;

	/// The author's email address, stripped of angular brackets.
	string authorEmail;

	/// Message date/time.
	SysTime time;

	/// A list of Message-IDs that this post is in reply to.
	/// The most recent message (and direct parent) comes last.
	string[] references;

	/// Whether this post is a reply.
	bool reply;

	/// This message's headers.
	Headers headers;

	/// The text contents of this message (UTF-8).
	/// "null" in case of an error.
	string content;

	/// The contents of this message (depends on mimeType).
	ubyte[] data;

	/// Explanation for null content.
	string error;

	/// Reflow options (RFC 2646).
	bool flowed, delsp;

	/// For a multipart message, contains the child parts.
	/// May nest more than one level.
	Rfc850Message[] parts;

	/// Properties of a multipart message's part.
	string name, fileName, description, mimeType;

	/// Parses a message string and creates a Rfc850Message.
	this(ascii message)
	{
		this.message = message;
		debug(RFC850) scope(failure) stderr.writeln("Failure while parsing message: ", id);

		// Split headers from message, parse headers

		// TODO: this breaks binary encodings, FIXME
		auto text = message.fastReplace("\r\n", "\n");
		auto headerEnd = text.indexOf("\n\n");
		if (headerEnd < 0) headerEnd = text.length;
		auto header = text[0..headerEnd];
		header = header.fastReplace("\n\t", " ").fastReplace("\n ", " ");

		// TODO: Use a proper spec-conforming header parser
		foreach (s; header.fastSplit('\n'))
		{
			if (s == "") break;

			auto p = s.indexOf(": ");
			if (p<0) continue;
			//assert(p>0, "Bad header line: " ~ s);
			headers[s[0..p]] = s[p+2..$];
		}

		// Decode international characters in headers

		string defaultEncoding = guessDefaultEncoding(headers.get("User-Agent", null));

		foreach (string key, ref string value; headers)
			if (hasHighAsciiChars(value))
				value = decodeEncodedText(value, defaultEncoding);

		// Decode transfer encoding

		ascii rawContent = text[min(headerEnd+2, $)..$];

		if ("Content-Transfer-Encoding" in headers)
			try
				rawContent = decodeTransferEncoding(rawContent, headers["Content-Transfer-Encoding"]);
			catch (Exception e)
			{
				rawContent = null;
				error = "Error decoding " ~ headers["Content-Transfer-Encoding"] ~ " message: " ~ e.msg;
			}

		// Decode message

		data = cast(ubyte[])rawContent;

		TokenHeader contentType, contentDisposition;
		if ("Content-Type" in headers)
			contentType = decodeTokenHeader(headers["Content-Type"]);
		if ("Content-Disposition" in headers)
			contentDisposition = decodeTokenHeader(headers["Content-Disposition"]);
		mimeType = toLower(contentType.value);
		flowed = contentType.properties.get("format", "fixed") == "flowed";
		delsp = contentType.properties.get("delsp", "no") == "yes";

		if (rawContent)
		{
			if (!mimeType || mimeType == "text/plain")
			{
				if ("charset" in contentType.properties)
					content = decodeEncodedText(rawContent, contentType.properties["charset"]);
				else
					content = decodeEncodedText(rawContent, defaultEncoding);
			}
			else
			if (mimeType.startsWith("multipart/") && "boundary" in contentType.properties)
			{
				string boundary = contentType.properties["boundary"];
				auto end = rawContent.indexOf("--" ~ boundary ~ "--");
				if (end < 0)
					end = rawContent.length;
				rawContent = rawContent[0..end];

				auto rawParts = rawContent.split("--" ~ boundary ~ "\n");
				foreach (rawPart; rawParts[1..$])
				{
					auto part = new Rfc850Message(rawPart);
					if (part.content && !content)
						content = part.content;
					parts ~= part;
				}

				if (!content)
				{
					if (rawParts.length && rawParts[0].asciiStrip().length)
						content = rawParts[0]; // default content to multipart stub
					else
						error = "Couldn't find text part in this " ~ mimeType ~ " message";
				}
			}
			else
				error = "Don't know how parse " ~ mimeType ~ " message";
		}

		// Strip PGP signature away to a separate "attachment"

		enum PGP_START = "-----BEGIN PGP SIGNED MESSAGE-----\n";
		enum PGP_DELIM = "\n-----BEGIN PGP SIGNATURE-----\n";
		enum PGP_END   = "\n-----END PGP SIGNATURE-----";
		if (content.startsWith(PGP_START) &&
		    content.contains(PGP_DELIM) &&
		    content.asciiStrip().endsWith(PGP_END))
		{
			// Don't attempt to create meaningful signature files... just get the clutter out of the way
			content = content.asciiStrip();
			auto p = content.indexOf(PGP_DELIM);
			auto part = new Rfc850Message(content[p+PGP_DELIM.length..$-PGP_END.length]);
			content = content[PGP_START.length..p];
			p = content.indexOf("\n\n");
			if (p >= 0)
				content = content[p+2..$];
			part.fileName = "pgp.sig";
			parts ~= part;
		}

		// Decode UU-encoded attachments

		if (content.contains("\nbegin "))
		{
			auto r = regex(`^begin [0-7]+ \S+$`);
			auto lines = content.split("\n");
			size_t start;
			bool started;
			string fn;

			for (size_t i=0; i<lines.length; i++)
				if (!started && !match(lines[i], r).empty)
				{
					start = i;
					fn = lines[i].split(" ")[2];
					started = true;
				}
				else
				if (started && lines[i] == "end" && lines[i-1]=="`")
				{
					started = false;
					try
					{
						auto data = uudecode(lines[start+1..i]);

						auto part = new Rfc850Message();
						part.fileName = fn;
						part.mimeType = guessMime(fn);
						part.data = data;
						parts ~= part;

						lines = lines[0..start] ~ lines[i+1..$];
						i = start-1;
					}
					catch (Exception e)
						debug(RFC850) stderr.writeln(e);
				}

			content = lines.join("\n");
		}

		// Parse message-part properties

		name = contentType.properties.get("name", string.init);
		fileName = contentDisposition.properties.get("filename", string.init);
		description = headers.get("Content-Description", string.init);
		if (name == fileName)
			name = null;

		// Decode references

		if ("References" in headers)
		{
			reply = true;
			auto refs = asciiStrip(headers["References"]);
			while (refs.startsWith("<"))
			{
				auto p = refs.indexOf(">");
				if (p < 0)
					break;
				references ~= refs[0..p+1];
				refs = asciiStrip(refs[p+1..$]);
			}
		}
		else
		if ("In-Reply-To" in headers)
			references = [headers["In-Reply-To"]];

		// Decode subject

		subject = rawSubject = "Subject" in headers ? decodeRfc1522(headers["Subject"]) : null;
		if (subject.startsWith("Re: "))
		{
			subject = subject[4..$];
			reply = true;
		}

		// Decode author

		author = authorEmail = "From" in headers ? decodeRfc1522(headers["From"]) : null;
		if ((author.indexOf('@') < 0 && author.indexOf(" at ") >= 0)
		 || (author.indexOf("<") < 0 && author.indexOf(">") < 0 && author.indexOf(" (") > 0 && author.endsWith(")")))
		{
			// Mailing list archive format
			assert(author == authorEmail);
			if (author.indexOf(" (") > 0 && author.endsWith(")"))
			{
				authorEmail = author[0 .. author.lastIndexOf(" (")].replace(" at ", "@");
				author      = author[author.lastIndexOf(" (")+2 .. $-1].decodeRfc1522();
			}
			else
			{
				authorEmail = author.replace(" at ", "@");
				author = author[0 .. author.lastIndexOf(" at ")];
			}
		}
		if (author.indexOf('<')>=0 && author.endsWith('>'))
		{
			auto p = author.indexOf('<');
			authorEmail = author[p+1..$-1];
			author = decodeRfc1522(asciiStrip(author[0..p]));
		}
		if (author.length>2 && author[0]=='"' && author[$-1]=='"')
			author = decodeRfc1522(asciiStrip(author[1..$-1]));
		if ((author == authorEmail || author == "") && authorEmail.indexOf("@") > 0)
			author = authorEmail[0..authorEmail.indexOf("@")];

		// Decode cross-references

		if ("Xref" in headers)
		{
			auto xrefStrings = split(headers["Xref"], " ")[1..$];
			foreach (str; xrefStrings)
			{
				auto segs = str.split(":");
				xref ~= Xref(segs[0], to!int(segs[1]));
			}
		}

		if ("List-ID" in headers && subject.startsWith("[") && !xref.length)
		{
			auto p = subject.indexOf("] ");
			xref = [Xref(subject[1..p])];
			subject = subject[p+2..$];
		}

		// Decode message ID

		if ("Message-ID" in headers && !id)
			id = headers["Message-ID"];

		// Decode post time

		time = Clock.currTime; // default value

		if ("NNTP-Posting-Date" in headers)
			time = parseTime!`D, j M Y H:i:s O \(\U\T\C\)`(headers["NNTP-Posting-Date"]);
		else
		if ("Date" in headers)
		{
			auto str = headers["Date"];
			try
				time = parseTime!(TimeFormats.RFC850)(str);
			catch (Exception e)
			try
				time = parseTime!(`D, j M Y H:i:s O`)(str);
			catch (Exception e)
			try
				time = parseTime!(`D, j M Y H:i:s e`)(str);
			catch (Exception e)
			try
				time = parseTime!(`D, j M Y H:i O`)(str);
			catch (Exception e)
			try
				time = parseTime!(`D, j M Y H:i e`)(str);
			catch (Exception e)
			{
				// fall-back to default (class creation time)
				// TODO: better behavior?
			}
		}
	}

	private this() {} // for attachments and templates

	/// Create a template Rfc850Message for a new posting to the specified groups.
	static Rfc850Message newPostTemplate(string groups)
	{
		auto post = new Rfc850Message();
		foreach (group; groups.split(","))
			post.xref ~= Xref(group);
		return post;
	}

	/// Create a template Rfc850Message for a reply to this message.
	Rfc850Message replyTemplate()
	{
		auto post = new Rfc850Message();
		post.reply = true;
		post.xref = this.xref;
		post.references = this.references ~ this.id;
		post.subject = this.rawSubject;
		if (!post.subject.startsWith("Re:"))
			post.subject = "Re: " ~ post.subject;

		auto paragraphs = unwrapText(this.content, this.flowed, this.delsp);
		foreach (i, ref paragraph; paragraphs)
			if (paragraph.quotePrefix.length)
				paragraph.quotePrefix = ">" ~ paragraph.quotePrefix;
			else
			{
				if (paragraph.text == "-- ")
				{
					paragraphs = paragraphs[0..i];
					break;
				}
				paragraph.quotePrefix = paragraph.text.length ? "> " : ">";
			}
		while (paragraphs.length && paragraphs[$-1].text.length==0)
			paragraphs = paragraphs[0..$-1];

		auto replyTime = time;
		replyTime.timezone = UTC();
		post.content =
			"On " ~ replyTime.format!`l, j F Y \a\t H:i:s e`() ~ ", " ~ this.author ~ " wrote:\n" ~
			wrapText(paragraphs) ~
			"\n\n";
		post.flowed = true;
		post.delsp = false;

		return post;
	}

	/// Set the message text.
	/// Rewraps as necessary.
	void setText(string text)
	{
		this.content = wrapText(unwrapText(text, false, false));
		this.flowed = true;
		this.delsp = false;
	}

	/// Construct the headers and message fields.
	void compile()
	{
		assert(id);

		headers["Message-ID"] = id;
		headers["From"] = format(`"%s" <%s>`, author, authorEmail);
		headers["Subject"] = subject;
		headers["Newsgroups"] = xref.map!(x => x.group)().join(",");
		headers["Content-Type"] = format("text/plain; charset=utf-8; format=%s; delsp=%s", flowed ? "flowed" : "fixed", delsp ? "yes" : "no");
		headers["Content-Transfer-Encoding"] = "8bit";
		if (references.length)
		{
			headers["References"] = references.join(" ");
			headers["In-Reply-To"] = references[$-1];
		}
		headers["Date"] = time.format!(TimeFormats.RFC2822);
		headers["User-Agent"] = "ae.net.ietf.message";

		string[] lines;
		foreach (name, value; headers)
		{
			if (value.hasHighAsciiChars())
				value = value.encodeRfc1522();
			auto line = name ~ ": " ~ value;
			auto lineStart = name.length + 2;

			foreach (c; line)
				enforce(c >= 32, "Control characters in headers");

			while (line.length >= 80)
			{
				auto p = line[0..80].lastIndexOf(' ');
				if (p < lineStart)
				{
					p = 80 + line[80..$].indexOf(' ');
					if (p < 80)
						break;
				}
				lines ~= line[0..p];
				line = line[p..$];
				lineStart = 1;
			}
			lines ~= line;
		}

		message =
			lines.join("\r\n") ~
			"\r\n\r\n" ~
			splitAsciiLines(content).join("\r\n");
	}

	/// Get the Message-ID that this message is in reply to.
	@property string parentID()
	{
		return references.length ? references[$-1] : null;
	}

	/// Return the oldest known ancestor of this post, possibly
	/// this post's ID if it is the first one in the thread.
	/// May not be the thread ID - some UAs/services
	/// cut off or strip the "References" header.
	@property string firstAncestorID()
	{
		return references.length ? references[0] : id;
	}
}

unittest
{
	auto post = new Rfc850Message("From: msonke at example.org (=?ISO-8859-1?Q?S=F6nke_Martin?=)\n\nText");
	assert(post.author == "Sönke Martin");
	assert(post.authorEmail == "msonke@example.org");

	post = new Rfc850Message("Date: Tue, 06 Sep 2011 14:52 -0700\n\nText");
	assert(post.time.year == 2011);
}

private:

/// Decode headers with international characters in them.
string decodeRfc1522(string str)
{
	auto words = str.split(" ");
	bool[] encoded = new bool[words.length];

	foreach (wordIndex, ref word; words)
		if (word.length > 6 && word.startsWith("=?") && word.endsWith("?="))
		{
			auto parts = split(word[2..$-2], "?");
			if (parts.length != 3)
				continue;
			auto charset = parts[0];
			auto encoding = parts[1];
			auto text = parts[2];

			switch (toUpper(encoding))
			{
			case "Q":
				text = decodeQuotedPrintable(text, true);
				break;
			case "B":
				text = cast(ascii)Base64.decode(text);
				break;
			default:
				continue /*foreach*/;
			}

			word = decodeEncodedText(text, charset);
			encoded[wordIndex] = true;
		}

	string result;
	foreach (wordIndex, word; words)
	{
		if (wordIndex > 0 && !(encoded[wordIndex-1] && encoded[wordIndex]))
			result ~= ' ';
		result ~= word;
	}

	try
	{
		import std.utf;
		validate(result);
	}
	catch (Exception e)
		result = toUtf8(cast(ascii)result, "ISO-8859-1", true);

	return result;
}

/// Encodes an UTF-8 string to be used in headers.
string encodeRfc1522(string str)
{
	if (!str.hasHighAsciiChars())
		return str;

	string[] words;
	bool wasIntl = false;
	foreach (word; str.split(" "))
	{
		bool isIntl = word.hasHighAsciiChars();
		if (wasIntl && isIntl)
			words[$-1] ~= " " ~ word;
		else
			words ~= word;
		wasIntl = isIntl;
	}

	enum CHUNK_LENGTH_THRESHOLD = 20;

	foreach (ref word; words)
	{
		if (!word.hasHighAsciiChars())
			continue;
		string[] output;
		string s = word;
		while (s.length)
		{
			size_t ptr = 0;
			while (ptr < s.length && ptr < CHUNK_LENGTH_THRESHOLD)
				ptr += stride(s, ptr);
			output ~= encodeRfc1522Chunk(s[0..ptr]);
			s = s[ptr..$];
		}
		word = output.join(" ");
	}
	return words.join(" ");
}

string encodeRfc1522Chunk(string str)
{
	auto result = "=?UTF-8?B?" ~ Base64.encode(cast(ubyte[])str) ~ "?=";
	return assumeUnique(result);
}

unittest
{
	auto text = "В лесу родилась ёлочка";
	assert(decodeRfc1522(encodeRfc1522(text)) == text);

	// Make sure email address isn't mangled
	assert(encodeRfc1522("Sönke Martin <msonke@example.org>").endsWith(" <msonke@example.org>"));
}

string decodeQuotedPrintable(string s, bool inHeaders)
{
	auto r = appender!string();
	for (int i=0; i<s.length; )
		if (s[i]=='=')
		{
			if (i+1 >= s.length || s[i+1] == '\n')
				i+=2; // escape newline
			else
				r.put(cast(char)to!ubyte(s[i+1..i+3], 16)), i+=3;
		}
		else
		if (s[i]=='_' && inHeaders)
			r.put(' '), i++;
		else
			r.put(s[i++]);
	return r.data;
}

string guessDefaultEncoding(string userAgent)
{
	switch (userAgent)
	{
		case "DFeed":
			// Early DFeed versions did not specify the encoding
			return "utf8";
		default:
			return "windows1252";
	}
}

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
static import ae.sys.cmd;

string decodeEncodedText(ascii s, string textEncoding)
{
	try
		return toUtf8(s, textEncoding, false);
	catch (Exception e)
	{
		debug(RFC850) stderr.writefln("iconv fallback for %s (%s)", textEncoding, e.msg);
		try
		{
			import ae.sys.cmd;
			return iconv(s, textEncoding);
		}
		catch (Exception e)
		{
			debug(RFC850) stderr.writefln("ISO-8859-1 fallback (%s)", e.msg);
			return toUtf8(s, "ISO-8859-1", false);
		}
	}
}

struct TokenHeader
{
	string value;
	string[string] properties;
}

TokenHeader decodeTokenHeader(string s)
{
	string take(char until)
	{
		string result;
		auto p = s.indexOf(until);
		if (p < 0)
			result = s,
			s = null;
		else
			result = s[0..p],
			s = asciiStrip(s[p+1..$]);
		return result;
	}

	TokenHeader result;
	result.value = take(';');

	while (s.length)
	{
		string name = take('=');
		string value;
		if (s.length && s[0] == '"')
		{
			s = s[1..$];
			value = take('"');
			take(';');
		}
		else
			value = take(';');
		result.properties[name] = value;
	}

	return result;
}

string decodeTransferEncoding(string data, string encoding)
{
	switch (toLower(encoding))
	{
	case "7bit":
		return data;
	case "quoted-printable":
		return decodeQuotedPrintable(data, false);
	case "base64":
		//return cast(string)Base64.decode(data.replace("\n", ""));
	{
		auto s = data.fastReplace("\n", "");
		scope(failure) debug(RFC850) stderr.writeln(s);
		return cast(string)Base64.decode(s);
	}
	default:
		return data;
	}
}

ubyte[] uudecode(string[] lines)
{
	// TODO: optimize
	//auto data = appender!(ubyte[]);  // OPTLINK says no
	ubyte[] data;
	foreach (line; lines)
	{
		if (!line.length || line.startsWith("`"))
			continue;
		ubyte len = to!ubyte(line[0] - 32);
		line = line[1..$];
		while (line.length % 4)
			line ~= 32;
		ubyte[] lineData;
		while (line.length)
		{
			uint v = 0;
			foreach (c; line[0..4])
				if (c == '`') // same as space
					v <<= 6;
				else
				{
					enforce(c >= 32 && c < 96, [c]);
					v = (v<<6) | (c - 32);
				}

			auto a = cast(ubyte[])((&v)[0..1]);
			lineData ~= a[2];
			lineData ~= a[1];
			lineData ~= a[0];

			line = line[4..$];
		}
		while (len > lineData.length)
			lineData ~= 0;
		data ~= lineData[0..len];
	}
	return data;
}
