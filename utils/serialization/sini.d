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
 *   Vladimir Panteleev <ae@cy.md>
 */

deprecated module ae.utils.serialization.sini;
deprecated:

import std.exception;
import std.range;
import std.string;
import std.traits;

import ae.utils.meta.binding;
import ae.utils.meta.reference;

struct IniParser(R)
{
	static void setValue(S, Sink)(S[] segments, S value, Sink sink)
	{
		if (segments.length == 0)
			sink.handleString(value);
		else
		{
			struct Reader
			{
				// https://d.puremagic.com/issues/show_bug.cgi?id=12318
				void dummy() {}

				void read(Sink)(Sink sink)
				{
					setValue(segments[1..$], value, sink);
				}
			}
			Reader reader;
			sink.traverse(segments[0], boundFunctorOf!(Reader.read)(&reader));
		}
	}

	static S readSection(R, S, Sink)(ref R r, S[] segments, Sink sink)
	{
		if (segments.length)
		{
			struct Reader
			{
				// https://d.puremagic.com/issues/show_bug.cgi?id=12318
				void dummy() {}

				S read(Sink)(Sink sink)
				{
					return readSection(r, segments[1..$], sink);
				}
			}
			Reader reader;
			return sink.traverse(segments[0], boundFunctorOf!(Reader.read)(&reader));
		}

		while (!r.empty)
		{
			auto line = r.front.chomp().stripLeft();

			scope(success) r.popFront();
			if (line.empty)
				continue;
			if (line[0] == '#' || line[0] == ';')
				continue;

			if (line.startsWith('['))
			{
				line = line.stripRight();
				enforce(line[$-1] == ']', "Malformed section line (no ']')");
				return line[1..$-1];
			}

			auto pos = line.indexOf('=');
			enforce(pos > 0, "Malformed value line (no '=')");
			auto name = line[0..pos].strip;
			segments = name.split(".");
			enforce(segments.length, "Malformed value line (empty name)");
			setValue(segments, line[pos+1..$].strip, sink);
		}
		return null;
	}

	void parseIni(R, Sink)(R r, Sink sink)
	{
		auto nextSection = readSection(r, typeof(r.front)[].init, sink);

		while (nextSection)
			nextSection = readSection(r, nextSection.split("."), sink);
	}
}

/// Parse a structured INI from a range of lines, into a user-defined struct.
T parseIni(T, R)(R r)
	if (isInputRange!R && isSomeString!(ElementType!R))
{
	import ae.utils.serialization.serialization;

	T result;
	auto parser = IniParser!R();
	parser.parseIni(r, deserializer(&result));
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

	auto f = parseIni!File
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

unittest
{
	import ae.utils.serialization.serialization;
	import std.conv;

	static struct Custom
	{
		struct Section
		{
			string name;
			string[string] values;
		}
		Section[] sections;

		enum isSerializationSink = true;

		auto traverse(Reader)(wstring name, Reader reader)
		{
			sections.length++;
			auto p = &sections[$-1];
			p.name = to!string(name);
			return reader(deserializer(&p.values));
		}

		void handleString(S)(S s) { assert(false); }
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
