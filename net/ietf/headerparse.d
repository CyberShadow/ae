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

	static const END_OF_HEADERS = "\r\n\r\n";

	size_t startFrom = 0;
searchAgain:
	string data0 = cast(string)data[0].contents;
	auto headersEnd = data0[startFrom..$].indexOf(END_OF_HEADERS);
	if (headersEnd < 0)
	{
		if (data.length > 1)
		{
			// coagulate first two blocks
			startFrom = data0.length > END_OF_HEADERS.length ? data0.length - (END_OF_HEADERS.length-1) : 0;
			data = [data[0] ~ data[1]] ~ data[2..$];
			goto searchAgain;
		}
		else
			return false;
	}
	headersEnd += startFrom;

	auto headerData = data0[0..headersEnd].idup; // copy Data slice to heap
	data[0] = data[0][headersEnd + END_OF_HEADERS.length .. data[0].length];

	headers = parseHeadersImpl!FIRST_LINE(headerData, firstLine);
	return true;
}

Headers parseHeadersImpl(bool FIRST_LINE)(string headerData, out string firstLine)
{
	headerData = headerData.replace("\n\t", " ").replace("\n ", " ");
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
