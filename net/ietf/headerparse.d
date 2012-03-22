/**
 * Header parsing
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

module ae.net.ietf.headerparse;

import std.string;
import std.array;

import ae.net.ietf.headers;
import ae.sys.data;
import ae.utils.text;

/**
 * Check if the passed data contains a full set of headers
 * (that is, contain a \r\n\r\n sequence), and if so -
 * parses them, removes them from data (so that it contains
 * only the message body), and returns true; otherwise
 * returns false.
 * The header string data is duplicated to the managed
 * heap.
 */
bool parseHeaders(ref Data[] data, out Headers headers)
{
	string dummy;
	return parseHeadersImpl!false(data, dummy, headers);
}

/// As above, but treat the first line differently, and
/// return it in firstLine.
bool parseHeaders(ref Data[] data, out string firstLine, out Headers headers)
{
	return parseHeadersImpl!true(data, firstLine, headers);
}

private:

bool parseHeadersImpl(bool FIRST_LINE)(ref Data[] data, out string firstLine, out Headers headers)
{
	if (!data.length)
		return false;

	static const DELIM1 = "\r\n\r\n";
	static const DELIM2 = "\n\n";

	size_t startFrom = 0;
	string delim;
searchAgain:
	string data0 = cast(string)data[0].contents;
	sizediff_t headersEnd;
	delim = DELIM1; headersEnd = data0[startFrom..$].indexOf(delim);
	if (headersEnd < 0)
	{
		delim = DELIM2; headersEnd = data0[startFrom..$].indexOf(delim);
	}
	if (headersEnd < 0)
	{
		if (data.length > 1)
		{
			// coagulate first two blocks
			startFrom = data0.length > delim.length ? data0.length - (delim.length-1) : 0;
			data = [data[0] ~ data[1]] ~ data[2..$];
			goto searchAgain;
		}
		else
			return false;
	}
	headersEnd += startFrom;

	auto headerData = data0[0..headersEnd].idup; // copy Data slice to heap
	data[0] = data[0][headersEnd + delim.length .. data[0].length];

	headers = parseHeadersImpl!FIRST_LINE(headerData, firstLine);
	return true;
}

Headers parseHeadersImpl(bool FIRST_LINE)(string headerData, out string firstLine)
{
	headerData = headerData.replace("\r\n", "\n").replace("\n\t", " ").replace("\n ", " ");
	string[] lines = splitAsciiLines(headerData);
	static if (FIRST_LINE)
	{
		firstLine = lines[0];
		lines = lines[1 .. lines.length];
	}

	Headers headers;
	foreach (line; lines)
	{
		auto valueStart = line.indexOf(':');
		if (valueStart > 0)
			headers.add(line[0..valueStart].strip(), line[valueStart+1..$].strip());
	}

	return headers;
}

unittest
{
	void test(string message)
	{
		auto data = [Data(message)];
		Headers headers;
		assert(parseHeaders(data, headers));
		assert(headers["From"] == "John Smith <john@smith.net>");
		assert(headers["To"] == "Mary Smith <john@smith.net>");
		assert(headers["Subject"] == "Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.");
		assert(cast(string)data.joinToHeap() == "Message body goes here");
	}

	string message = q"EOS
From : John Smith <john@smith.net>
to:Mary Smith <john@smith.net> 
Subject: Lorem ipsum dolor sit amet, consectetur
 adipisicing elit, sed do eiusmod tempor
	incididunt ut labore et dolore magna aliqua.

Message body goes here
EOS".strip();

	message = message.replace("\r\n", "\n");
	test(message);
	message = message.replace("\n", "\r\n");
	test(message);
}
