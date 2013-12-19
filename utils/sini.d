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
import std.traits;

alias std.string.indexOf indexOf;

/// Represents the user-defined behavior for handling a node in a
/// structured INI file's hierarchy.
struct StructuredIniHandler
{
	/// User callback for parsing a value at this node.
	void delegate(in char[] name, in char[] value) leafHandler;

	/// User callback for obtaining a child node from this node.
	StructuredIniHandler delegate(in char[] name) nodeHandler;

	private void handleLeaf(in char[] name, in char[] value)
	{
		enforce(leafHandler, "This group may not have any values.");
		leafHandler(name, value);
	}

	private StructuredIniHandler handleNode(in char[] name)
	{
		enforce(nodeHandler, "This group may not have any nodes.");
		return nodeHandler(name);
	}
}

/// Parse a structured INI from a range of lines, through the given handler.
void parseStructuredIni(R)(R r, StructuredIniHandler rootHandler)
	if (isInputRange!R && is(ElementType!R : const(char)[]))
{
	auto currentHandler = rootHandler;

	size_t lineNumber;
	while (!r.empty)
	{
		lineNumber++;

		auto line = r.front.chomp().stripLeft();
		scope(success) r.popFront();
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
			auto name = line[0..pos].strip;
			auto handler = currentHandler;
			auto segments = name.split(".");
			enforce(segments.length, "Malformed value line (empty name)");
			foreach (segment; segments[0..$-1])
				handler = handler.handleNode(segment);
			handler.handleLeaf(segments[$-1], line[pos+1..$].strip);
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
			(in char[] name)
			{
				assert(name == "s");
				return StructuredIniHandler
				(
					(in char[] name, in char[] value)
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

/// Alternative API for StructuredIniHandler, where each leaf is a node
struct StructuredIniTraversingHandler
{
	/// User callback for parsing a value at this node.
	void delegate(in char[] value) leafHandler;

	/// User callback for obtaining a child node from this node.
	StructuredIniTraversingHandler delegate(in char[] name) nodeHandler;

	private void handleLeaf(in char[] value)
	{
		enforce(leafHandler, "This group may not have a value.");
		leafHandler(value);
	}

	private StructuredIniTraversingHandler handleNode(in char[] name)
	{
		enforce(nodeHandler, "This group may not have any nodes.");
		return nodeHandler(name);
	}

	private StructuredIniHandler conv()
	{
		// Don't reference "this" from a lambda,
		// as it can be a temporary on the stack
		StructuredIniTraversingHandler thisCopy = this;
		return StructuredIniHandler
		(
			(in char[] name, in char[] value)
			{
				thisCopy.handleNode(name).handleLeaf(value);
			},
			(in char[] name)
			{
				return thisCopy.handleNode(name).conv();
			}
		);
	}
}

/// Parse a structured INI from a range of lines, into a user-defined struct.
T parseStructuredIni(T, R)(R r)
	if (isInputRange!R && is(ElementType!R : const(char)[]))
{
	static StructuredIniTraversingHandler makeHandler(U)(ref U v)
	{
		import std.conv;

		static if (is(U == struct))
			return StructuredIniTraversingHandler
			(
				null,
				(in char[] name)
				{
					bool found;
					foreach (i, field; v.tupleof)
						if (name == v.tupleof[i].stringof[2..$])
							return makeHandler(v.tupleof[i]);
					throw new Exception("Unknown field " ~ name.assumeUnique);
				}
			);
		else
		static if (is(typeof(v[string.init])))
			return StructuredIniTraversingHandler
			(
				null,
				(in char[] name)
				{
					auto pField = name in v;
					if (!pField)
					{
						v[name] = typeof(v[name]).init;
						pField = name in v;
					}
					return makeHandler(*pField);
				}
			);
		else
		static if (is(typeof(std.conv.to!U(string.init))))
			return StructuredIniTraversingHandler
			(
				(in char[] value)
				{
					v = std.conv.to!U(value);
				}
			);
		else
			static assert(false, "Can't parse " ~ U.stringof);
	}

	T result;
	parseStructuredIni(r, makeHandler(result).conv());
	return result;
}

unittest
{
	static struct File
	{
		struct S
		{
			string n1, n2;
			int[string] a;
		}
		S s;
	}

	auto f = parseStructuredIni!File
	(
		q"<
			s.n1=v1
			s.a.foo=1
			[s]
			n2=v2
			a.bar=2
		>".splitLines()
	);

	assert(f.s.n1=="v1");
	assert(f.s.n2=="v2");
	assert(f.s.a==["foo":1, "bar":2]);
}

/// Simple convenience formatter for writing INI files.
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
