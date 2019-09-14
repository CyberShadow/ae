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

import ae.utils.exception;
import ae.utils.meta : boxVoid, unboxVoid;

alias std.string.indexOf indexOf;

/// Represents the user-defined behavior for handling a node in a
/// structured INI file's hierarchy.
struct IniHandler(S)
{
	/// User callback for parsing a value at this node.
	void delegate(S value) leafHandler;

	/// User callback for obtaining a child node from this node.
	IniHandler delegate(S name) nodeHandler;
}

struct IniLine(S)
{
	enum Type
	{
		empty,
		section,
		value
	}

	Type type;
	S name; // section or value
	S value;
}

IniLine!S lexIniLine(S)(S line)
if (isSomeString!S)
{
	IniLine!S result;

	line = line.chomp().stripLeft();
	if (line.empty)
		return result;
	if (line[0] == '#' || line[0] == ';')
		return result;

	if (line[0] == '[')
	{
		line = line.stripRight();
		enforce(line[$-1] == ']', "Malformed section line (no ']')");
		result.type = result.Type.section;
		result.name = line[1..$-1];
	}
	else
	{
		auto pos = line.indexOf('=');
		enforce(pos > 0, "Malformed value line (no '=')");
		result.type = result.Type.value;
		result.name = line[0..pos].strip;
		result.value = line[pos+1..$].strip;
	}
	return result;
}

/// Evaluates to `true` if H is a valid INI handler for a string type S.
enum isIniHandler(H, S) =
	is(typeof((H handler, S s) { handler.nodeHandler(s); handler.leafHandler(s); }));

/// Parse a structured INI from a range of lines, through the given handler.
void parseIni(R, H)(R r, H rootHandler)
	if (isInputRange!R && isSomeString!(ElementType!R) && isIniHandler!(H, ElementType!R))
{
	auto currentHandler = rootHandler;

	size_t lineNumber;
	while (!r.empty)
	{
		lineNumber++;
		mixin(exceptionContext(q{"Error while parsing INI line %s:".format(lineNumber)}));

		scope(success) r.popFront();
		auto line = lexIniLine(r.front);
		final switch (line.type)
		{
			case line.Type.empty:
				break;
			case line.Type.section:
				currentHandler = rootHandler;
				foreach (segment; line.name.split("."))
					currentHandler = currentHandler.nodeHandler
						.enforce("This group may not have any nodes.")
						(segment);
				break;
			case line.Type.value:
			{
				auto handler = currentHandler;
				auto segments = line.name.split(".");
				enforce(segments.length, "Malformed value line (empty name)");
				enforce(handler.nodeHandler, "This group may not have any nodes.");
				while (segments.length > 1)
				{
					auto next = handler.nodeHandler(segments[0]);
					if (!next.nodeHandler)
						break;
					handler = next;
					segments = segments[1..$];
				}
				handler.nodeHandler
					.enforce("This group may not have any nodes.")
					(segments.join("."))
					.leafHandler
					.enforce("This group may not have any values.")
					(line.value);
				break;
			}
		}
	}
}

/// Helper which creates an INI handler out of delegates.
IniHandler!S iniHandler(S)(void delegate(S) leafHandler, IniHandler!S delegate(S) nodeHandler = null)
{
	return IniHandler!S(leafHandler, nodeHandler);
}

/// Alternative API for IniHandler, where each leaf accepts name/value
/// pairs instead of single values.
struct IniThickLeafHandler(S)
{
	/// User callback for parsing a value at this node.
	void delegate(S name, S value) leafHandler;

	/// User callback for obtaining a child node from this node.
	IniThickLeafHandler delegate(S name) nodeHandler;

	private IniHandler!S conv(S currentName = null)
	{
		// Don't reference "this" from a lambda,
		// as it can be a temporary on the stack
		IniThickLeafHandler self = this;
		return IniHandler!S
		(
			!currentName || !self.leafHandler ? null :
			(S value)
			{
				self.leafHandler(currentName, value);
			},
			(currentName ? !self.nodeHandler : !self.nodeHandler && !self.leafHandler) ? null :
			(S name)
			{
				if (!currentName)
					return self.conv(name);
				else
					return self.nodeHandler(currentName).conv(name);
			}
		);
	}
}

/// Helper which creates an IniThinkLeafHandler.
IniHandler!S iniHandler(S)(void delegate(S, S) leafHandler, IniThickLeafHandler!S delegate(S) nodeHandler = null)
{
	return IniThickLeafHandler!S(leafHandler, nodeHandler).conv(null);
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

enum isNestingType(T) = isAssociativeArray!T || is(T == struct);

private enum isAALike(U, S) = is(typeof(
	(ref U v)
	{
		alias K = typeof(v.keys[0]);
		alias V = typeof(v[K.init]);
		v.require(K.init);
	}
));

IniHandler!S makeIniHandler(S = string, U)(ref U v)
{
	static if (!is(U == Unqual!U))
		return makeIniHandler!S(*cast(Unqual!U*)&v);
	else
	static if (isAALike!(U, S))
		return IniHandler!S
		(
			null,
			(S name)
			{
				alias K = typeof(v.keys[0]);
				alias V = typeof(v[K.init]);

				auto key = name.to!K;

				auto update(T)(T delegate(ref V) dg)
				{
					static if (!isNestingType!U)
						if (key in v)
							throw new Exception("Duplicate value: " ~ to!string(name));
					return dg(v.require(key));
				}

				// To know if the value handler will accept leafs or nodes requires constructing the handler.
				// To construct the handler we must have a pointer to the object it will handle.
				// To have a pointer to the object means to allocate it in the AA...
				// but, we can't do that until we know it's going to be written to.
				// So, introspect what the handler for this type can handle at compile-time instead.
				static immutable dummyHandler = { V dummy; return makeIniHandler!S(dummy); }();

				return IniHandler!S
				(
					!dummyHandler.leafHandler ? null : (S value) => update((ref V v) => makeIniHandler!S(v).leafHandler(value)),
					!dummyHandler.nodeHandler ? null : (S name2) => update((ref V v) => makeIniHandler!S(v).nodeHandler(name2)),
				);
			}
		);
	else
	static if (isAssociativeArray!U)
		static assert(false, "Unsupported associative array type " ~ U.stringof);
	else
	static if (is(U == struct))
		return IniHandler!S
		(
			null,
			delegate IniHandler!S (S name)
			{
				bool found;
				foreach (i, ref field; v.tupleof)
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
	static if (is(typeof(to!U(string.init))))
		return IniHandler!S
		(
			(S value)
			{
				v = to!U(value);
			}
		);
	else
	static if (is(U V : V*))
	{
		static if (is(typeof(v = new V)))
			if (!v)
				v = new V;
		return makeIniHandler!S(*v);
	}
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
	parseIni(r, makeIniHandler!(ElementType!R)(result));
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

	alias M = OrderedMap!(string, string);
	static assert(isAALike!(M, string));

	auto o = parseIni!M
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
	alias M = OrderedMap!(string, S);
	static assert(isAALike!(M, string));

	auto o = parseIni!M
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

unittest
{
	static struct S { string x, y; }
	static struct T { S* s; }

	{
		T t;
		parseIniInto(["s.x=v"], t);
		assert(t.s.x == "v");
	}

	{
		S s = {"x"}; T t = {&s};
		parseIniInto(["s.y=v"], t);
		assert(s.x == "x");
		assert(s.y == "v");
	}
}

unittest
{
	auto r = parseIni!(string[string])
	(
		q"<
			a.b.c=d.e.f
		>".splitLines()
	);

	assert(r == ["a.b.c" : "d.e.f"]);
}

// ***************************************************************************

deprecated alias parseStructuredIni = parseIni;
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

// ***************************************************************************

/**
   Adds or updates a value in an INI file.

   If the value is already in the INI file, then it is updated
   in-place; otherwise, a new one is added to the matching section.

   Whitespace and comments on other lines are preserved.

   Params:
     lines = INI file lines (as in parseIni)
     name = fully-qualified name of the value to update
            (use `.` to specify section path)
     value = new value to write
*/

void updateIni(S)(ref S[] lines, S name, S value)
{
	size_t valueLine = size_t.max;
	S valueLineSection;

	S currentSection = null;
	auto pathPrefix() { return chain(currentSection, repeat(typeof(name[0])('.'), currentSection is null ? 0 : 1)); }

	size_t bestSectionEnd;
	S bestSection;
	bool inBestSection = true;

	foreach (i, line; lines)
	{
		auto lex = lexIniLine(line);
		final switch (lex.type)
		{
			case lex.Type.empty:
				break;
			case lex.Type.value:
				if (equal(chain(pathPrefix, lex.name), name))
				{
					valueLine = i;
					valueLineSection = currentSection;
				}
				break;
			case lex.type.section:
				if (inBestSection)
					bestSectionEnd = i;
				inBestSection = false;

				currentSection = lex.name;
				if (name.startsWith(pathPrefix) && currentSection.length > bestSection.length)
				{
					bestSection = currentSection;
					inBestSection = true;
				}
				break;
		}
	}

	if (inBestSection)
		bestSectionEnd = lines.length;

	S genLine(S section) { return name[section.length ? section.length + 1 : 0 .. $] ~ '=' ~ value; }

	if (valueLine != size_t.max)
		lines[valueLine] = genLine(valueLineSection);
	else
		lines = lines[0..bestSectionEnd] ~ genLine(bestSection) ~ lines[bestSectionEnd..$];
}

unittest
{
	auto ini = q"<
		a=1
		a=2
	>".splitLines();
	updateIni(ini, "a", "3");
	struct S { int a; }
	assert(parseIni!S(ini).a == 3);
}

unittest
{
	auto ini = q"<
		a=1
		[s]
		a=2
		[t]
		a=3
	>".strip.splitLines.map!strip.array;
	updateIni(ini, "a", "4");
	updateIni(ini, "s.a", "5");
	updateIni(ini, "t.a", "6");
	assert(equal(ini, q"<
		a=4
		[s]
		a=5
		[t]
		a=6
	>".strip.splitLines.map!strip), text(ini));
}

unittest
{
	auto ini = q"<
		[s]
		[t]
	>".strip.splitLines.map!strip.array;
	updateIni(ini, "a", "1");
	updateIni(ini, "s.a", "2");
	updateIni(ini, "t.a", "3");
	assert(equal(ini, q"<
		a=1
		[s]
		a=2
		[t]
		a=3
	>".strip.splitLines.map!strip));
}

void updateIniFile(S)(string fileName, S name, S value)
{
	import std.file, std.stdio, std.utf;
	auto lines = fileName.exists ? fileName.readText.splitLines : null;
	updateIni(lines, name, value);
	lines.map!(l => chain(l.byCodeUnit, only(typeof(S.init[0])('\n')))).joiner.toFile(fileName);
}

unittest
{
	import std.file;
	enum fn = "temp.ini";
	std.file.write(fn, "a=b\n");
	scope(exit) remove(fn);
	updateIniFile(fn, "a", "c");
	assert(read(fn) == "a=c\n");
}
