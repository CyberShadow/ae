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

void toCSV(Output)(OrderedMap!(string, string)[] rows, Output output)
{
	void putValue(string value)
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

	enforce(rows.length > 0, "Cannot write empty CSV");

	{
		bool first = true;
		foreach (header; rows[0].byKey)
		{
			if (first)
				first = false;
			else
				output.put(',');
			putValue(header);
		}
		output.put("\r\n");
	}

	foreach (row; rows)
	{
		bool first = true;
		foreach (name, value; row)
		{
			if (first)
				first = false;
			else
				output.put(',');
			putValue(value);
		}
		output.put("\r\n");
	}
}
		
string toCSV(OrderedMap!(string, string)[] rows)
{
	auto buffer = appender!string;
	toCSV(rows, buffer);
	return buffer.data;
}
