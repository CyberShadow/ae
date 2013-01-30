/**
 * Structured INI
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

module ae.utils.sini;

import std.algorithm;
import std.exception;
import std.range;
import std.string;

alias std.string.indexOf indexOf;

struct StructuredIniHandler
{
	void delegate(string name, string value) leafHandler;
	StructuredIniHandler delegate(string name) nodeHandler;

	private void handleLeaf(string name, string value)
	{
		enforce(leafHandler, "This group may not have any values.");
		leafHandler(name, value);
	}

	private StructuredIniHandler handleNode(string name)
	{
		enforce(nodeHandler, "This group may not have any nodes.");
		return nodeHandler(name);
	}
}

void parseStructuredIni(R)(R r, StructuredIniHandler rootHandler)
	if (isInputRange!R && is(ElementType!R == string))
{
	auto currentHandler = rootHandler;

	size_t lineNumber;
	while (!r.empty)
	{
		lineNumber++;

		auto line = r.front.chomp().stripLeft();
		r.popFront();
		if (line.empty)
			continue;
		if (line[0] == '#' || line[0] == ';')
			continue;

		if (line[0] == '[')
		{
			line = line.stripRight();
			enforce(line[$-1] == ']', "Malformed section line (no ']')");
			auto section = line[1..$-1];

			currentHandler = rootHandler;
			foreach (segment; section.split("."))
				currentHandler = currentHandler.handleNode(segment);
		}
		else
		{
			auto pos = line.indexOf('=');
			enforce(pos > 0, "Malformed value line (no '=')");
			// Should we strip whitespace from value?
			auto name = line[0..pos];
			auto handler = currentHandler;
			auto segments = name.split(".");
			enforce(segments.length, "Malformed value line (empty name)");
			foreach (segment; segments[0..$-1])
				handler = handler.handleNode(segment);
			handler.handleLeaf(segments[$-1], line[pos+1..$]);
		}
	}
}

unittest
{
	int count;

	parseStructuredIni
	(
		q"<
			s.n1=v1
			[s]
			n2=v2
		>".splitLines(),
		StructuredIniHandler
		(
			null,
			(string name)
			{
				assert(name == "s");
				return StructuredIniHandler
				(
					(string name, string value)
					{
						assert(name .length==2 && name [0] == 'n'
						    && value.length==2 && value[0] == 'v'
						    && name[1] == value[1]);
						count++;
					}
				);
			}
		)
	);

	assert(count==2);
}

struct IniWriter(O)
{
	O writer;

	void startSection(string name)
	{
		writer.put('[', name, "]\n");
	}

	void writeValue(string name, string value)
	{
		writer.put(name, '=', value, '\n');
	}
}

/// Insert a blank line before each section
string prettifyIni(string ini) { return ini.replace("\n[", "\n\n["); }
