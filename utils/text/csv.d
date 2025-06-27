/**
 * CSV writing / formatting.
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

module ae.utils.text.csv;

import std.algorithm.searching;
import std.array;
import std.exception;
import std.utf;

import ae.utils.aa;

void putCSVCell(Output)(ref Output output, string value)
{
	if (value.empty || value.byChar.any!(c => c == '"' || c == '\'' || c == '\n' || c == '\r' || c == ',' || c == ';' || c == ' ' || c == '\t'))
	{
		output.put('"');
		foreach (c; value)
		{
			if (c == '"')
				output.put('"');
			output.put(c);
		}
		output.put('"');
	}
	else
		output.put(value);
}

void putCSVRow(Output, Row)(ref Output output, Row row)
{
	bool first = true;
	foreach (value; row)
	{
		if (first)
			first = false;
		else
			output.put(',');
		output.putCSVCell(value);
	}
	output.put("\r\n");
}

void putCSV(Output)(Output output, string[] headers, string[][] rows)
{
	output.putCSVRow(headers);
	foreach (row; rows)
		output.putCSVRow(row);
}
		
string toCSV(string[] headers, string[][] rows)
{
	auto buffer = appender!string;
	buffer.putCSV(headers, rows);
	return buffer.data;
}

debug(ae_unittest) unittest
{
	auto csv = toCSV(["a", "b"], [["1", "2"], ["3 4", `5"6`]]);
	assert(csv == "a,b\r\n1,2\r\n\"3 4\",\"5\"\"6\"\r\n");
}

void putCSV(Output)(Output output, OrderedMap!(string, string)[] rows)
{
	enforce(rows.length > 0, "Cannot write empty CSV");

	output.putCSVRow(rows[0].byKey);
	foreach (row; rows)
		output.putCSVRow(row.byValue);
}

string toCSV(OrderedMap!(string, string)[] rows)
{
	auto buffer = appender!string;
	buffer.putCSV(rows);
	return buffer.data;
}

debug(ae_unittest) unittest
{
	import std.typecons : tuple;

	auto csv = toCSV([
		orderedMap([tuple("a", "1"), tuple("b", "2")]),
		orderedMap([tuple("a", "3 4"), tuple("b", `5"6`)]),
	]);
	assert(csv == "a,b\r\n1,2\r\n\"3 4\",\"5\"\"6\"\r\n");
}
