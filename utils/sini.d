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
import std.conv;
import std.exception;
import std.range;
import std.string;
import std.traits;

alias std.string.indexOf indexOf;

/// Represents the user-defined behavior for handling a node in a
/// structured INI file's hierarchy.
struct IniHandler(S)
{
	/// User callback for parsing a value at this node.
	void delegate(S name, S value) leafHandler;

	/// User callback for obtaining a child node from this node.
	IniHandler delegate(S name) nodeHandler;
}

/// Parse a structured INI from a range of lines, through the given handler.
void parseIni(R, H)(R r, H rootHandler)
	if (isInputRange!R && isSomeString!(ElementType!R))
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
				currentHandler = currentHandler.nodeHandler
					.enforce("This group may not have any nodes.")
					(segment);
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
				handler = handler.nodeHandler
					.enforce("This group may not have any nodes.")
					(segment);
			handler.leafHandler
				.enforce("This group may not have any values.")
				(segments[$-1], line[pos+1..$].strip);
		}
	}
}

/// Helper which creates an INI handler out of delegates.
IniHandler!S iniHandler(S)(void delegate(S, S) leafHandler, IniHandler!S delegate(S) nodeHandler = null)
{
	return IniHandler!S(leafHandler, nodeHandler);
}

unittest
{
	int count;

	parseIni
	(
		q"<
			s.n1=v1
			[s]
			n2=v2
		>".splitLines(),
		iniHandler
		(
			null,
			(in char[] name)
			{
				assert(name == "s");
				return iniHandler
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

/// Alternative API for IniHandler, where each leaf is a node
struct IniTraversingHandler(S)
{
	/// User callback for parsing a value at this node.
	void delegate(S value) leafHandler;

	/// User callback for obtaining a child node from this node.
	IniTraversingHandler delegate(S name) nodeHandler;

	private IniHandler!S conv()
	{
		// Don't reference "this" from a lambda,
		// as it can be a temporary on the stack
		IniTraversingHandler thisCopy = this;
		return IniHandler!S
		(
			(S name, S value)
			{
				thisCopy
					.nodeHandler
					.enforce("This group may not have any nodes.")
					(name)
					.leafHandler
					.enforce("This group may not have a value.")
					(value);
			},
			(S name)
			{
				return thisCopy
					.nodeHandler
					.enforce("This group may not have any nodes.")
					(name)
					.conv();
			}
		);
	}
}

enum isNestingType(T) = isAssociativeArray!T || is(T == struct);

IniTraversingHandler!S makeIniHandler(S = string, U)(ref U v)
{
	static if (!is(U == Unqual!U))
		return makeIniHandler!S(*cast(Unqual!U*)&v);
	else
	static if (is(typeof((ref U v){alias V=typeof(v[S.init]); v[S.init] = V.init; *(S.init in v) = V.init;})))
		return IniTraversingHandler!S
		(
			null,
			(S name)
			{
				auto pField = name in v;
				if (!pField)
				{
					v[name] = typeof(v[name]).init;
					pField = name in v;
				}
				else
				static if (!isNestingType!U)
					throw new Exception("Duplicate value: " ~ to!string(name));
				return makeIniHandler!S(*pField);
			}
		);
	else
	static if (is(U == struct))
		return IniTraversingHandler!S
		(
			null,
			delegate IniTraversingHandler!S (S name)
			{
				bool found;
				foreach (i, field; v.tupleof)
				{
					enum fieldName = to!S(v.tupleof[i].stringof[2..$]);
					if (name == fieldName)
					{
						static if (is(typeof(makeIniHandler!S(v.tupleof[i]))))
							return makeIniHandler!S(v.tupleof[i]);
						else
							throw new Exception("Can't parse " ~ U.stringof ~ "." ~ cast(string)name ~ " of type " ~ typeof(v.tupleof[i]).stringof);
					}
				}
				static if (is(ReturnType!(v.parseSection)))
					return v.parseSection(name);
				else
					throw new Exception("Unknown field " ~ to!string(name));
			}
		);
	else
	static if (isAssociativeArray!U)
		return IniTraversingHandler!S
		(
			null,
			(S name)
			{
				alias K = typeof(v.keys[0]);
				auto key = to!K(name);
				auto pField = key in v;
				if (!pField)
				{
					v[key] = typeof(v[key]).init;
					pField = key in v;
				}
				else
				static if (!isNestingType!U)
					throw new Exception("Duplicate value: " ~ to!string(name));
				return makeIniHandler!S(*pField);
			}
		);
	else
	static if (is(typeof(to!U(string.init))))
		return IniTraversingHandler!S
		(
			(S value)
			{
				v = to!U(value);
			}
		);
	else
		static assert(false, "Can't parse " ~ U.stringof);
}

/// Parse structured INI lines from a range of strings, into a user-defined struct.
T parseIni(T, R)(R r)
	if (isInputRange!R && isSomeString!(ElementType!R))
{
	T result;
	r.parseIniInto(result);
	return result;
}

/// ditto
void parseIniInto(R, T)(R r, ref T result)
	if (isInputRange!R && isSomeString!(ElementType!R))
{
	parseIni(r, makeIniHandler!(ElementType!R)(result).conv());
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

	auto f = parseIni!File
	(
		q"<
			s.n1=v1
			s.a.foo=1
			[s]
			n2=v2
			a.bar=2
		>".dup.splitLines()
	);

	assert(f.s.n1=="v1");
	assert(f.s.n2=="v2");
	assert(f.s.a==["foo":1, "bar":2]);
}

unittest
{
	static struct Custom
	{
		struct Section
		{
			string name;
			string[string] values;
		}
		Section[] sections;

		auto parseSection(wstring name)
		{
			sections.length++;
			auto p = &sections[$-1];
			p.name = to!string(name);
			return makeIniHandler!wstring(p.values);
		}
	}

	auto c = parseIni!Custom
	(
		q"<
			[one]
			a=a
			[two]
			b=b
		>"w.splitLines()
	);

	assert(c == Custom([Custom.Section("one", ["a" : "a"]), Custom.Section("two", ["b" : "b"])]));
}

version(unittest) static import ae.utils.aa;

unittest
{
	import ae.utils.aa;

	auto o = parseIni!(OrderedMap!(string, string))
	(
		q"<
			b=b
			a=a
		>".splitLines()
	);

	assert(o["a"]=="a" && o["b"] == "b");
}

unittest
{
	import ae.utils.aa;

	static struct S { string x; }

	auto o = parseIni!(OrderedMap!(string, S))
	(
		q"<
			b.x=b
			[a]
			x=a
		>".splitLines()
	);

	assert(o["a"].x == "a" && o["b"].x == "b");
}

unittest
{
	static struct S { string x, y; }

	auto r = parseIni!(S[string])
	(
		q"<
			a.x=x
			[a]
			y=y
		>".splitLines()
	);

	assert(r["a"].x == "x" && r["a"].y == "y");
}

// ***************************************************************************

deprecated alias StructuredIniHandler = IniHandler;
deprecated alias parseStructuredIni = parseIni;
deprecated alias StructuredIniTraversingHandler = IniTraversingHandler;
deprecated alias makeStructuredIniHandler = makeIniHandler;

// ***************************************************************************

/// Convenience function to load a struct from an INI file.
/// Returns .init if the file does not exist.
S loadIni(S)(string fileName)
{
	S s;

	import std.file;
	if (fileName.exists)
		s = fileName
			.readText()
			.splitLines()
			.parseIni!S();

	return s;
}

/// As above, though loads several INI files
/// (duplicate values appearing in later INI files
/// override any values from earlier files).
S loadInis(S)(in char[][] fileNames)
{
	S s;

	import std.file;
	s = fileNames
		.map!(fileName =>
			fileName.exists ?
				fileName
				.readText()
				.splitLines()
			:
				null
		)
		.joiner(["[]"])
		.parseIni!S();

	return s;
}

// ***************************************************************************

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
