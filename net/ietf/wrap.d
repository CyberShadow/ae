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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.net.ietf.wrap;

import std.range;
import std.string;
import std.uni;

import ae.utils.text;

struct Paragraph
{
	string quotePrefix, text;
}

Paragraph[] unwrapText(string text, bool flowed, bool delsp)
{
	auto lines = text.splitAsciiLines();

	Paragraph[] paragraphs;

	foreach (line; lines)
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

		string quotePrefix = oline[0..line.ptr - oline.ptr];

		// Remove space-stuffing
		if (flowed && line.startsWith(" "))
			line = line[1..$];

		if (paragraphs.length>0
		 && paragraphs[$-1].quotePrefix==quotePrefix
		 && paragraphs[$-1].text.endsWith(" ")
		 && !line.startsWith(" ")
		 && line.length
		 && line != "-- "
		 && paragraphs[$-1].text != "-- "
		 && (flowed || quotePrefix.length))
		{
			if (delsp)
				paragraphs[$-1].text = paragraphs[$-1].text[0..$-1];
			paragraphs[$-1].text ~= line;
		}
		else
			paragraphs ~= Paragraph(quotePrefix, line);
	}

	return paragraphs;
}

enum DEFAULT_WRAP_LENGTH = 66;

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
	assert(wrapText(unwrapText(" Hello", false, false)) == "  Hello");

	// Don't rewrap user input
	assert(wrapText(unwrapText("Line 1 \nLine 2 ", false, false)) == "Line 1\nLine 2");
	// ...but rewrap quoted text
	assert(wrapText(unwrapText("> Line 1 \n> Line 2 ", false, false)) == "> Line 1 Line 2");
	// Wrap long lines
	import std.array : replicate;
	assert(wrapText(unwrapText(replicate("abcde ", 20), false, false)).split("\n").length > 1);

	// Wrap by character count, not UTF-8 code-unit count. TODO: take into account surrogates and composite characters.
	enum str = "Это очень очень очень очень очень очень очень длинная строка";
	import std.utf;
	static assert(str.toUTF32().length < DEFAULT_WRAP_LENGTH);
	static assert(str.length > DEFAULT_WRAP_LENGTH);
	assert(wrapText(unwrapText(str, false, false)).split("\n").length == 1);
}
