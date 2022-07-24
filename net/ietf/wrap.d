/**
 * RFC 2646. May be upgraded to RFC 3676 for international text.
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

module ae.net.ietf.wrap;

import std.algorithm;
import std.range;
import std.string;
import std.uni;

import ae.utils.text;

/// A plain-text paragraph.
struct Paragraph
{
	/// The leading part of the paragraph (identical for all lines in
	/// the encoded form). Generally some mix of `'>'` and space
	/// characters.
	string quotePrefix;

	/// The contents of the paragraph.
	string text;
}

/// Specifies the format for how line breaks and paragraphs are
/// encoded in a message.
enum WrapFormat
{
	fixed,       /// One paragraph per line
	flowed,      /// format=flowed
	flowedDelSp, /// format=flowed; delsp=yes
	heuristics,  /// Guess
	input,       /// As emitted by Rfc850Message.replyTemplate
	markdown,    /// Hard linebreak is 2 or more spaces
}

/// Parses a message body holding text in the
/// specified format, and returns parsed paragraphs.
Paragraph[] unwrapText(string text, WrapFormat wrapFormat)
{
	auto lines = text.splitAsciiLines();

	Paragraph[] paragraphs;

	string stripQuotePrefix(ref string line)
	{
		auto oline = line;

		while (line.startsWith(">"))
		{
			int l = 1;
			// This is against standard, but many clients
			// (incl. Web-News and M$ Outlook) don't give a damn:
			if (line.startsWith("> "))
				l = 2;

			line = line[l..$];
		}

		return oline[0..line.ptr - oline.ptr];
	}

	final switch (wrapFormat)
	{
		case WrapFormat.fixed:
			foreach (line; lines)
			{
				string quotePrefix = stripQuotePrefix(line);
				paragraphs ~= Paragraph(quotePrefix, line);
			}
			break;
		case WrapFormat.flowed:
		case WrapFormat.flowedDelSp:
		case WrapFormat.input:
			foreach (line; lines)
			{
				string quotePrefix = stripQuotePrefix(line);

				// Remove space-stuffing
				if (wrapFormat != WrapFormat.input && !quotePrefix.length && line.startsWith(" "))
					line = line[1..$];

				if (paragraphs.length>0
				 && paragraphs[$-1].quotePrefix==quotePrefix
				 && paragraphs[$-1].text.endsWith(" ")
				 && line.length
				 && line != "-- "
				 && paragraphs[$-1].text != "-- "
				 && (wrapFormat != WrapFormat.input || quotePrefix.length))
				{
					if (wrapFormat == WrapFormat.flowedDelSp)
						paragraphs[$-1].text = paragraphs[$-1].text[0..$-1];
					paragraphs[$-1].text ~= line;
				}
				else
					paragraphs ~= Paragraph(quotePrefix, line);
			}
			break;
		case WrapFormat.markdown:
			foreach (line; lines)
			{
				string quotePrefix = stripQuotePrefix(line);

				if (paragraphs.length>0
				 && paragraphs[$-1].quotePrefix==quotePrefix
				 && !paragraphs[$-1].text.endsWith("  ")
				 && line.length
				 && line != "-- "
				 && paragraphs[$-1].text != "-- ")
				{
					if (!paragraphs[$-1].text.endsWith(" "))
						paragraphs[$-1].text ~= " ";
					paragraphs[$-1].text ~= line;
				}
				else
					paragraphs ~= Paragraph(quotePrefix, line);
			}
			break;
		case WrapFormat.heuristics:
		{
			// Use heuristics for non-format=flowed text.

			static bool isWrapped(in string[] lines)
			{
				assert(lines.all!(line => line.length));

				// Heuristic checks (from most to least confidence):

				// Zero or one line - as-is
				if (lines.length < 2)
					return false;

				// If any line starts with whitespace or contains a tab,
				// consider pre-wrapped (code, likely).
				if (lines.any!(line => isWhite(line[0]) || line.canFind('\t')))
					return false;

				// Detect implicit format=flowed (trailing space)
				if (lines[0..$-1].all!(line => line[$-1] == ' '))
					return true;

				// Check if the set of lines can feasibly be the output
				// of a typical naive line-wrapping algorithm
				// (and calculate the possible range of line widths).
				size_t wrapMin = 1, wrapMax = 1000;
				foreach (i, line; lines[0..$-1])
				{
					auto lineMin = line.stripRight.length;
					auto nextWord = lines[i+1].findSplit(" ")[0];
					auto lineMax = lineMin + 1 + nextWord.length;
					// Are we outside of our current range?
					if (lineMin > wrapMax || lineMax < wrapMin)
						return false; // pre-wrapped
					// Now, narrow down the range accordingly
					wrapMin = max(wrapMin, lineMin);
					wrapMax = min(wrapMax, lineMax);
				}
				// Finally, test last line
				if (lines[$-1].length > wrapMax)
					return false;
				// Sanity checks.
				if (wrapMax < 60 || wrapMin > 120)
					return false;

				// Character frequency check.

				size_t[256] count;
				size_t total;
				foreach (line; lines)
					foreach (c; line)
						count[c]++, total++;

				// D code tends to contain a lot of parens.
				auto parenFreq = (count['('] + count[')']) * 100 / total;

				return parenFreq < 2;
			}

			void handleParagraph(string quotePrefix, in string[] lines)
			{
				if (isWrapped(lines))
					paragraphs ~= Paragraph(quotePrefix, lines.map!stripRight.join(" "));
				else
					paragraphs ~= lines.map!(line => Paragraph(quotePrefix, line.stripRight())).array;
			}

			sizediff_t start = -1;
			string lastQuotePrefix;

			foreach (i, ref line; lines)
			{
				auto oline = line;
				string quotePrefix = stripQuotePrefix(line);

				bool isDelim = !line.length
					|| line.strip() == "--" // signature
					|| line.startsWith("---") // Bugzilla
				;

				if (isDelim || quotePrefix != lastQuotePrefix)
				{
					if (start >= 0)
					{
						handleParagraph(lastQuotePrefix, lines[start..i]);
						start = -1;
					}
				}

				if (isDelim)
					paragraphs ~= Paragraph(quotePrefix, line);
				else
				if (start < 0)
					start = i;

				lastQuotePrefix = quotePrefix;
			}

			if (start >= 0)
				handleParagraph(lastQuotePrefix, lines[start..$]);
		}
	}

	return paragraphs;
}

/// The default value of `wrapText`'s `margin` parameter.
enum DEFAULT_WRAP_LENGTH = 66;

/// Returns wrapped text in the `WrapFormat.flowed` format.
string wrapText(Paragraph[] paragraphs, int margin = DEFAULT_WRAP_LENGTH)
{
	string[] lines;

	void addLine(string quotePrefix, string line)
	{
		line = quotePrefix ~ line;
		// Add space-stuffing
		if (line.startsWith(" ") ||
			line.startsWith("From ") ||
			(line.startsWith(">") && quotePrefix.length==0))
		{
			line = " " ~ line;
		}
		lines ~= line;
	}

	foreach (paragraph; paragraphs)
	{
		string line = paragraph.text;

		while (line.length && line[$-1] == ' ')
			line = line[0..$-1];

		if (!line.length)
		{
			addLine(paragraph.quotePrefix, null);
			continue;
		}

		while (line.length)
		{
			size_t lastIndex = 0;
			size_t lastLength = paragraph.quotePrefix.length;
			foreach (i, c; line)
				if (c == ' ' || i == line.length-1)
				{
					auto length = lastLength + line[lastIndex..i+1].byGrapheme.walkLength;
					if (length > margin)
						break;
					lastIndex = i+1;
					lastLength = length;
				}

			if (lastIndex == 0)
			{
				// Couldn't wrap. Wrap whole line
				lastIndex = line.length;
			}

			addLine(paragraph.quotePrefix, line[0..lastIndex]);
			line = line[lastIndex..$];
		}
	}

	return lines.join("\n");
}

unittest
{
	// Space-stuffing
	assert(wrapText(unwrapText(" Hello", WrapFormat.fixed)) == "  Hello");

	// Don't rewrap user input
	assert(wrapText(unwrapText("Line 1 \nLine 2 ", WrapFormat.input)) == "Line 1\nLine 2");
	// ...but rewrap quoted text
	assert(wrapText(unwrapText("> Line 1 \n> Line 2 ", WrapFormat.input)) == "> Line 1 Line 2");
	// Wrap long lines
	import std.array : replicate;
	assert(wrapText(unwrapText(replicate("abcde ", 20), WrapFormat.fixed)).split("\n").length > 1);

	// Wrap by character count, not UTF-8 code-unit count. TODO: take into account surrogates and composite characters.
	enum str = "Это очень очень очень очень очень очень очень длинная строка";
	import std.utf;
	static assert(str.toUTF32().length < DEFAULT_WRAP_LENGTH);
	static assert(str.length > DEFAULT_WRAP_LENGTH);
	assert(wrapText(unwrapText(str, WrapFormat.fixed)).split("\n").length == 1);

	// Allow wrapping and correctly unwrapping long sequences of spaces
	assert(unwrapText("|  \n  |", WrapFormat.flowed) == [Paragraph("", "|   |")]);
}
