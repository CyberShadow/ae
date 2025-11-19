/**
 * Fast compiled glob expressions
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

module ae.utils.path.glob;

import std.traits : isSomeChar;

/// Compiled glob pattern with fast @nogc matching
struct CompiledGlob(C)
if (isSomeChar!C)
{
	/// A single matching instruction
	private struct Instruction
	{
		/// Instruction types for compiled pattern
		enum Type
		{
			literal,           /// Match exact string
			star,              /// Match zero or more characters
			question,          /// Match exactly one character
			charClass,         /// Match one character from a set
			braceAlternatives, /// Match one of several alternative patterns
		}

		Type type; /// ditto

		// Data for each instruction type
		union
		{
			const(C)[] literal;                /// For literal
			CharClassData charClass;           /// For charClass
			const(Instruction[])[] alternatives; /// For braceAlternatives
		}

		/// String representation of this instruction
		void toString(Writer)(ref Writer w) const
		{
			final switch (type)
			{
				case Type.literal:
					auto literal = (() @trusted => this.literal)();
					foreach (c; literal)
					{
						// Escape special characters
						if (c == '*' || c == '?' || c == '[' || c == ']' ||
							c == '{' || c == '}' || c == '\\' || c == ',')
						{
							w.put('\\');
						}
						w.put(c);
					}
					break;

				case Type.star:
					w.put('*');
					break;

				case Type.question:
					w.put('?');
					break;

				case Type.charClass:
					auto charClass = (() @trusted => this.charClass)();
					w.put('[');
					if (charClass.negated)
						w.put('!');
					// Escape special characters in character classes
					foreach (c; charClass.chars)
					{
						if (c == ']' || c == '\\')
							w.put('\\');
						w.put(c);
					}
					foreach (range; charClass.ranges)
					{
						if (range.start == ']' || range.start == '\\')
							w.put('\\');
						w.put(range.start);
						w.put('-');
						if (range.end == ']' || range.end == '\\')
							w.put('\\');
						w.put(range.end);
					}
					// Output POSIX classes
					if (charClass.posixClasses != PosixClass.none)
					{
						import std.range.primitives : put;

						// Helper to output a POSIX class if its flag is set
						void outputClass(PosixClass flag, string name)
						{
							if (charClass.posixClasses & flag)
							{
								w.put('[');
								w.put(':');
								put(w, name);
								w.put(':');
								w.put(']');
							}
						}

						outputClass(PosixClass.alnum,  "alnum");
						outputClass(PosixClass.alpha,  "alpha");
						outputClass(PosixClass.blank,  "blank");
						outputClass(PosixClass.cntrl,  "cntrl");
						outputClass(PosixClass.digit,  "digit");
						outputClass(PosixClass.graph,  "graph");
						outputClass(PosixClass.lower,  "lower");
						outputClass(PosixClass.print,  "print");
						outputClass(PosixClass.punct,  "punct");
						outputClass(PosixClass.space,  "space");
						outputClass(PosixClass.upper,  "upper");
						outputClass(PosixClass.xdigit, "xdigit");
					}
					w.put(']');
					break;

				case Type.braceAlternatives:
					auto alternatives = (() @trusted => this.alternatives)();
					w.put('{');
					bool first = true;
					foreach (alt; alternatives)
					{
						if (!first)
							w.put(',');
						first = false;
						foreach (ref instr; alt)
							instr.toString(w);
					}
					w.put('}');
					break;
			}
		}
	}

	/// POSIX character class flags (bitfield)
	private enum PosixClass : ushort
	{
		none    = 0,
		alnum   = 1 << 0,  /// Alphanumeric: [A-Za-z0-9]
		alpha   = 1 << 1,  /// Alphabetic: [A-Za-z]
		blank   = 1 << 2,  /// Space and tab
		cntrl   = 1 << 3,  /// Control characters
		digit   = 1 << 4,  /// Digits: [0-9]
		graph   = 1 << 5,  /// Visible characters (no space)
		lower   = 1 << 6,  /// Lowercase: [a-z]
		print   = 1 << 7,  /// Printable characters
		punct   = 1 << 8,  /// Punctuation
		space   = 1 << 9,  /// Whitespace
		upper   = 1 << 10, /// Uppercase: [A-Z]
		xdigit  = 1 << 11, /// Hexadecimal digits: [0-9A-Fa-f]
	}

	/// Character class data
	private struct CharClassData
	{
		/// Character range for character classes
		struct Range
		{
			C start;
			C end;
		}

		const(C)[] chars;
		const(Range)[] ranges;
		PosixClass posixClasses;  // Bitfield of POSIX classes
		bool negated;
	}

	/// Continuation chain node (allocated on stack via recursion)
	private struct Continuation
	{
		const(Instruction)[] instructions;
		const(Continuation)* next;  /// Points to outer continuation
	}

	// Compiled instruction sequence
	private Instruction[] instructions;

	/// Compile a glob pattern (GC allowed, done once)
	this(const(C)[] pattern) pure
	{
		this.instructions = compilePattern(pattern);
	}

	/// String representation (reconstructs pattern from instructions)
	void toString(Writer)(ref Writer w) const
	{
		foreach (ref instr; instructions)
			instr.toString(w);
	}

	/// Match a path against this compiled pattern (@nogc, fast)
	bool match(const(C)[] path) const pure nothrow @nogc
	{
		size_t consumed = matchImpl(path, 0, instructions, 0, null);
		return consumed != size_t.max && consumed == path.length;
	}

	/// Returns true if the pattern is a literal (no wildcards or special characters)
	bool isLiteral() const pure nothrow @nogc @safe
	{
		foreach (ref instr; instructions)
			if (instr.type != Instruction.Type.literal)
				return false;
		return true;
	}

	// Recursive matching implementation
	// Returns: number of path characters consumed, or size_t.max if no match
	// continuation: linked list of continuations to match after current pattern
	private static size_t matchImpl(
		const(C)[] path, size_t pathIdx,
		const(Instruction)[] pattern, size_t patIdx,
		const(Continuation)* continuation,
	) pure nothrow @nogc
	{
		while (patIdx < pattern.length)
		{
			const instr = pattern[patIdx];

			final switch (instr.type)
			{
				case Instruction.Type.literal:
					// Match exact string
					const lit = (() @trusted => instr.literal)();
					if (pathIdx + lit.length > path.length)
						return size_t.max;
					foreach (i, c; lit)
						if (path[pathIdx + i] != c)
							return size_t.max;
					pathIdx += lit.length;
					patIdx++;
					break;

				case Instruction.Type.star:
					// Try matching zero or more characters
					if (patIdx + 1 == pattern.length)
					{
						// Star at end of current pattern
						if (continuation is null)
							return path.length; // No continuation, matches rest

						// Try all positions, then match continuation chain
						for (size_t i = pathIdx; i <= path.length; i++)
						{
							size_t consumed = matchImpl(path, i, continuation.instructions, 0, continuation.next);
							if (consumed != size_t.max)
								return consumed;
						}
						return size_t.max;
					}

					// Try all possible positions, continue with rest of pattern
					for (size_t i = pathIdx; i <= path.length; i++)
					{
						size_t consumed = matchImpl(path, i, pattern, patIdx + 1, continuation);
						if (consumed != size_t.max)
							return consumed;
					}
					return size_t.max;

				case Instruction.Type.question:
					// Match exactly one character
					if (pathIdx >= path.length)
						return size_t.max;
					pathIdx++;
					patIdx++;
					break;

				case Instruction.Type.charClass:
					// Match one character from set or range
					if (pathIdx >= path.length)
						return size_t.max;

					const ch = path[pathIdx];
					bool found = false;
					const charClass = (() @trusted => instr.charClass)();

					// Check individual characters
					foreach (c; charClass.chars)
					{
						if (ch == c)
						{
							found = true;
							break;
						}
					}

					// Check ranges
					if (!found)
					{
						foreach (range; charClass.ranges)
						{
							if (ch >= range.start && ch <= range.end)
							{
								found = true;
								break;
							}
						}
					}

					// Check POSIX classes
					if (!found && charClass.posixClasses != PosixClass.none)
					{
						// Check each flag in the bitfield
						if ((charClass.posixClasses & PosixClass.alnum)  && matchesPosixClass(ch, PosixClass.alnum))  found = true;
						if ((charClass.posixClasses & PosixClass.alpha)  && matchesPosixClass(ch, PosixClass.alpha))  found = true;
						if ((charClass.posixClasses & PosixClass.blank)  && matchesPosixClass(ch, PosixClass.blank))  found = true;
						if ((charClass.posixClasses & PosixClass.cntrl)  && matchesPosixClass(ch, PosixClass.cntrl))  found = true;
						if ((charClass.posixClasses & PosixClass.digit)  && matchesPosixClass(ch, PosixClass.digit))  found = true;
						if ((charClass.posixClasses & PosixClass.graph)  && matchesPosixClass(ch, PosixClass.graph))  found = true;
						if ((charClass.posixClasses & PosixClass.lower)  && matchesPosixClass(ch, PosixClass.lower))  found = true;
						if ((charClass.posixClasses & PosixClass.print)  && matchesPosixClass(ch, PosixClass.print))  found = true;
						if ((charClass.posixClasses & PosixClass.punct)  && matchesPosixClass(ch, PosixClass.punct))  found = true;
						if ((charClass.posixClasses & PosixClass.space)  && matchesPosixClass(ch, PosixClass.space))  found = true;
						if ((charClass.posixClasses & PosixClass.upper)  && matchesPosixClass(ch, PosixClass.upper))  found = true;
						if ((charClass.posixClasses & PosixClass.xdigit) && matchesPosixClass(ch, PosixClass.xdigit)) found = true;
					}

					if (found == charClass.negated)
						return size_t.max;

					pathIdx++;
					patIdx++;
					break;

				case Instruction.Type.braceAlternatives:
					// Try each alternative, chaining continuations
					const alts = (() @trusted => instr.alternatives)();

					// Build continuation chain: if there's more pattern after this brace,
					// create a node on the stack with it
					Continuation contNode;
					const(Continuation)* braceContinuation;
					if (patIdx + 1 < pattern.length)
					{
						contNode.instructions = pattern[patIdx + 1 .. $];
						contNode.next = continuation;
						// Safe to take address: contNode lives until end of this case block
						braceContinuation = () @trusted { return &contNode; }();
					}
					else
					{
						braceContinuation = continuation;
					}

					foreach (alt; alts)
					{
						// Match this alternative with continuation chain
						size_t consumed = matchImpl(path, pathIdx, alt, 0, braceContinuation);
						if (consumed != size_t.max)
						{
							// Check if we should accept this match
							if (continuation is null)
							{
								// Top level: only accept if entire path consumed
								if (consumed == path.length)
									return consumed;
							}
							else
							{
								// Inside alternative: return first match
								return consumed;
							}
						}
					}
					return size_t.max;
			}
		}

		// Finished current pattern, now match continuation chain if any
		if (continuation !is null)
			return matchImpl(path, pathIdx, continuation.instructions, 0, continuation.next);

		return pathIdx;
	}

	// Compile pattern into instructions
	private static Instruction[] compilePattern(const(C)[] pattern) pure
	{
		Instruction[] instructions;
		size_t i = 0;

		while (i < pattern.length)
		{
			const ch = pattern[i];

			if (ch == '\\' && i + 1 < pattern.length)
			{
				// Escape sequence - treat next character as literal
				C[] escaped;
				escaped ~= pattern[i + 1];
				instructions ~= makeLiteral(escaped);
				i += 2;
			}
			else if (ch == '*')
			{
				instructions ~= Instruction(Instruction.Type.star);
				i++;
			}
			else if (ch == '?')
			{
				instructions ~= Instruction(Instruction.Type.question);
				i++;
			}
			else if (ch == '[')
			{
				// Parse character class
				size_t start = i + 1;
				bool negated = false;

				if (start < pattern.length && pattern[start] == '!')
				{
					negated = true;
					start++;
				}

				// Special case: ] as first character is literal
				// e.g., []abc] or [!]abc]
				size_t searchStart = start;
				if (searchStart < pattern.length && pattern[searchStart] == ']')
					searchStart++;

				// Find closing ] (handling escapes and POSIX classes)
				size_t end = searchStart;
				while (end < pattern.length)
				{
					if (pattern[end] == '\\' && end + 1 < pattern.length)
					{
						end += 2; // Skip escaped character
					}
					else if (pattern[end] == '[' && end + 1 < pattern.length && pattern[end + 1] == ':')
					{
						// Skip over POSIX class [:...:]
						end += 2;
						while (end + 1 < pattern.length &&
							   !(pattern[end] == ':' && pattern[end + 1] == ']'))
						{
							end++;
						}
						if (end + 1 < pattern.length)
							end += 2; // Skip past :]
					}
					else if (pattern[end] == ']')
					{
						break;
					}
					else
					{
						end++;
					}
				}

				if (end >= pattern.length)
				{
					// No closing ], treat [ as literal
					instructions ~= makeLiteral(pattern[i .. i + 1]);
					i++;
				}
				else
				{
					// Parse character class content, extracting ranges
					C[] chars;
					CharClassData.Range[] ranges;
					PosixClass posixClasses = PosixClass.none;

					for (size_t j = start; j < end; )
					{
						if (pattern[j] == '\\' && j + 1 < end)
						{
							// Escaped character - always literal
							chars ~= pattern[j + 1];
							j += 2;
						}
						// Check for POSIX character class [:name:]
						else if (pattern[j] == '[' && j + 1 < end && pattern[j + 1] == ':')
						{
							// Find the closing :]
							size_t posixEnd = j + 2;
							while (posixEnd + 1 < end &&
								   !(pattern[posixEnd] == ':' && pattern[posixEnd + 1] == ']'))
							{
								posixEnd++;
							}

							if (posixEnd + 1 < end && pattern[posixEnd] == ':' && pattern[posixEnd + 1] == ']')
							{
								// Extract POSIX class name
								auto className = pattern[j + 2 .. posixEnd];
								bool recognized = true;

								// Match against known POSIX classes using switch
								switch (className)
								{
									case "alnum":  posixClasses |= PosixClass.alnum;  break;
									case "alpha":  posixClasses |= PosixClass.alpha;  break;
									case "blank":  posixClasses |= PosixClass.blank;  break;
									case "cntrl":  posixClasses |= PosixClass.cntrl;  break;
									case "digit":  posixClasses |= PosixClass.digit;  break;
									case "graph":  posixClasses |= PosixClass.graph;  break;
									case "lower":  posixClasses |= PosixClass.lower;  break;
									case "print":  posixClasses |= PosixClass.print;  break;
									case "punct":  posixClasses |= PosixClass.punct;  break;
									case "space":  posixClasses |= PosixClass.space;  break;
									case "upper":  posixClasses |= PosixClass.upper;  break;
									case "xdigit": posixClasses |= PosixClass.xdigit; break;
									default:
										recognized = false;
										break;
								}

								if (recognized)
								{
									j = posixEnd + 2; // Skip past :]
								}
								else
								{
									// Unknown POSIX class, treat as literal
									chars ~= pattern[j];
									j++;
								}
							}
							else
							{
								// No closing :], treat as literal
								chars ~= pattern[j];
								j++;
							}
						}
						// Check for range pattern: char-char (not escaped)
						else if (j + 2 < end && pattern[j + 1] == '-' && pattern[j + 2] != ']')
						{
							// It's a range
							ranges ~= CharClassData.Range(pattern[j], pattern[j + 2]);
							j += 3;
						}
						else
						{
							// Single character
							chars ~= pattern[j];
							j++;
						}
					}

					Instruction instr;
					instr.type = Instruction.Type.charClass;
					() @trusted {
						instr.charClass = CharClassData(chars, ranges, posixClasses, negated);
					}();
					instructions ~= instr;
					i = end + 1;
				}
			}
			else if (ch == '{')
			{
				// Parse brace alternatives
				size_t closeIdx = i;
				int depth = 1;
				closeIdx++;

				// Find matching close brace
				while (closeIdx < pattern.length && depth > 0)
				{
					if (pattern[closeIdx] == '\\' && closeIdx + 1 < pattern.length)
					{
						closeIdx += 2; // Skip escaped character
					}
					else if (pattern[closeIdx] == '{')
					{
						depth++;
						closeIdx++;
					}
					else if (pattern[closeIdx] == '}')
					{
						depth--;
						if (depth == 0)
							break;
						closeIdx++;
					}
					else
					{
						closeIdx++;
					}
				}

				if (depth != 0 || closeIdx >= pattern.length)
				{
					// No matching brace, treat as literal
					instructions ~= makeLiteral(pattern[i .. i + 1]);
					i++;
				}
				else
				{
					// Split alternatives and compile each
					Instruction[][] alternatives;
					size_t start = i + 1;
					depth = 0;

					for (size_t j = start; j <= closeIdx; j++)
					{
						if (j < closeIdx)
						{
							if (pattern[j] == '\\' && j + 1 < closeIdx)
							{
								j++; // Skip escaped character
								continue;
							}
							else if (pattern[j] == '{')
								depth++;
							else if (pattern[j] == '}')
								depth--;
						}

						// Split on comma only at depth 0
						if ((j == closeIdx) || (pattern[j] == ',' && depth == 0))
						{
							// Compile this alternative
							alternatives ~= compilePattern(pattern[start .. j]);
							start = j + 1;
						}
					}

					// Create braceAlternatives instruction
					Instruction instr;
					instr.type = Instruction.Type.braceAlternatives;
					() @trusted {
						instr.alternatives = alternatives;
					}();
					instructions ~= instr;
					i = closeIdx + 1;
				}
			}
			else
			{
				// Collect consecutive literal characters
				size_t start = i;
				while (i < pattern.length &&
					   pattern[i] != '*' &&
					   pattern[i] != '?' &&
					   pattern[i] != '[' &&
					   pattern[i] != '{' &&
					   pattern[i] != '\\')
				{
					i++;
				}

				instructions ~= makeLiteral(pattern[start .. i]);
			}
		}

		return instructions;
	}

	// Helper to create a literal instruction
	private static Instruction makeLiteral(const(C)[] str) pure @trusted
	{
		Instruction instr;
		instr.type = Instruction.Type.literal;
		instr.literal = str.dup;
		return instr;
	}

	// Helper to check if character matches a POSIX class
	private static bool matchesPosixClass(C)(C c, PosixClass pc) pure nothrow @nogc @safe
	{
		import std.ascii;

		final switch (pc)
		{
			case PosixClass.none:    return false;
			case PosixClass.alnum:   return isAlphaNum(c);
			case PosixClass.alpha:   return isAlpha(c);
			case PosixClass.blank:   return c == ' ' || c == '\t';
			case PosixClass.cntrl:   return isControl(c);
			case PosixClass.digit:   return isDigit(c);
			case PosixClass.graph:   return isGraphical(c);
			case PosixClass.lower:   return isLower(c);
			case PosixClass.print:   return isPrintable(c);
			case PosixClass.punct:   return isPunctuation(c);
			case PosixClass.space:   return isWhite(c);
			case PosixClass.upper:   return isUpper(c);
			case PosixClass.xdigit:  return isHexDigit(c);
		}
	}
}

/// Compile a glob pattern (GC allowed, done once)
CompiledGlob!C compileGlob(C)(const(C)[] pattern) pure
if (isSomeChar!C)
{
	return CompiledGlob!C(pattern);
}

// std.path-like API for testing
private bool globMatch(C)(const(C)[] path, const(C)[] pattern)
if (isSomeChar!C)
{
	auto compiled = compileGlob(pattern);
	return compiled.match(path);
}

///
debug(ae_unittest) @safe unittest
{
	// Compile once (uses GC)
	auto pattern1 = compileGlob("foo.bar");

	// Test millions of times (@nogc, fast)
	assert(pattern1.match("foo.bar"));
	assert(!pattern1.match("foo.baz"));

	auto pattern2 = compileGlob("*");
	assert(pattern2.match("foo.bar"));
	assert(pattern2.match("anything"));

	auto pattern3 = compileGlob("*.*");
	assert(pattern3.match("foo.bar"));
	assert(!pattern3.match("foo"));

	auto pattern4 = compileGlob("f*b*r");
	assert(pattern4.match(`foo/foo\bar`));
	assert(pattern4.match("fbar"));

	auto pattern5 = compileGlob("f???bar");
	assert(pattern5.match("foo.bar"));
	assert(!pattern5.match("fo.bar"));

	auto pattern6 = compileGlob("[fg]???bar");
	assert(pattern6.match("foo.bar"));
	assert(!pattern6.match("hoo.bar"));

	auto pattern7 = compileGlob("[!gh]*bar");
	assert(pattern7.match("foo.bar"));
	assert(!pattern7.match("goo.bar"));

	auto pattern8 = compileGlob("bar.{foo,bif}z");
	assert(pattern8.match("bar.fooz"));
	assert(pattern8.match("bar.bifz"));
	assert(!pattern8.match("bar.barz"));

	// Case-sensitive only
	auto pattern9 = compileGlob("foo");
	assert(!pattern9.match("Foo"));

	auto pattern10 = compileGlob("[fg]???bar");
	assert(!pattern10.match("Goo.bar"));
}

debug(ae_unittest) @safe unittest
{
	// Test isLiteral
	assert(compileGlob("foo.bar").isLiteral);
	assert(compileGlob("simple").isLiteral);
	assert(compileGlob("path/to/file.txt").isLiteral);
	assert(compileGlob("file with spaces").isLiteral);
	assert(compileGlob("\\*").isLiteral);  // Escaped * is a literal
	assert(compileGlob("\\?").isLiteral);  // Escaped ? is a literal
	assert(compileGlob("foo\\?bar").isLiteral);  // Escape inside a literal is a literal
	assert(compileGlob("").isLiteral);  // Empty string is a literal

	assert(!compileGlob("*").isLiteral);
	assert(!compileGlob("*.txt").isLiteral);
	assert(!compileGlob("foo*bar").isLiteral);
	assert(!compileGlob("test?").isLiteral);
	assert(!compileGlob("f???bar").isLiteral);
	assert(!compileGlob("[abc]").isLiteral);
	assert(!compileGlob("[a-z]").isLiteral);
	assert(!compileGlob("{foo,bar}").isLiteral);
	assert(!compileGlob("test.{c,d}").isLiteral);
}

debug(ae_unittest) @safe unittest
{
	// Legacy API still works (compiles pattern each time)
	assert(globMatch("foo", "*"));
	assert(globMatch("foo.bar"w, "*"w));
	assert(globMatch("foo.bar"d, "*.*"d));
	assert(globMatch("foo.bar", "foo*"));
	assert(globMatch("foo.bar"w, "f*bar"w));
	assert(globMatch("foo.bar"d, "f*b*r"d));
	assert(globMatch("foo.bar", "f???bar"));
	assert(globMatch("foo.bar"w, "[fg]???bar"w));
	assert(globMatch("foo.bar"d, "[!gh]*bar"d));

	assert(!globMatch("foo", "bar"));
	assert(!globMatch("foo"w, "*.*"w));
	assert(!globMatch("foo.bar"d, "f*baz"d));
	assert(!globMatch("foo.bar", "f*b*x"));
	assert(!globMatch("foo.bar", "[gh]???bar"));
	assert(!globMatch("foo.bar"w, "[!fg]*bar"w));
	assert(!globMatch("foo.bar"d, "[fg]???baz"d));
	// https://issues.dlang.org/show_bug.cgi?id=6634
	assert(!globMatch("foo.di", "*.d")); // triggered bad assertion

	assert(globMatch("foo.bar", "{foo,bif}.bar"));
	assert(globMatch("bif.bar"w, "{foo,bif}.bar"w));

	assert(globMatch("bar.foo"d, "bar.{foo,bif}"d));
	assert(globMatch("bar.bif", "bar.{foo,bif}"));

	assert(globMatch("bar.fooz"w, "bar.{foo,bif}z"w));
	assert(globMatch("bar.bifz"d, "bar.{foo,bif}z"d));

	assert(globMatch("bar.foo", "bar.{biz,,baz}foo"));
	assert(globMatch("bar.foo"w, "bar.{biz,}foo"w));
	assert(globMatch("bar.foo"d, "bar.{,biz}foo"d));
	assert(globMatch("bar.foo", "bar.{}foo"));

	assert(globMatch("bar.foo"w, "bar.{ar,,fo}o"w));
	assert(globMatch("bar.foo"d, "bar.{,ar,fo}o"d));
	assert(globMatch("bar.o", "bar.{,ar,fo}o"));

	assert(!globMatch("foo", "foo?"));
	assert(!globMatch("foo", "foo[]"));
	assert(!globMatch("foo", "foob"));
	assert(!globMatch("foo", "foo{b}"));

	static assert(globMatch("foo.bar", "[!gh]*bar"));
}

// Test nested braces
debug(ae_unittest) @safe unittest
{
	// Simple nested braces
	assert(globMatch("a", "{a,{b,c}}"));
	assert(globMatch("b", "{a,{b,c}}"));
	assert(globMatch("c", "{a,{b,c}}"));
	assert(!globMatch("d", "{a,{b,c}}"));

	// Nested with prefix/suffix
	assert(globMatch("file-a.txt", "file-{a,{b,c}}.txt"));
	assert(globMatch("file-b.txt", "file-{a,{b,c}}.txt"));
	assert(globMatch("file-c.txt", "file-{a,{b,c}}.txt"));
	assert(!globMatch("file-d.txt", "file-{a,{b,c}}.txt"));

	// Deeply nested
	assert(globMatch("x", "{x,{y,{z,w}}}"));
	assert(globMatch("y", "{x,{y,{z,w}}}"));
	assert(globMatch("z", "{x,{y,{z,w}}}"));
	assert(globMatch("w", "{x,{y,{z,w}}}"));

	// Multiple nested groups
	assert(globMatch("1", "{{1,2},{3,4}}"));
	assert(globMatch("2", "{{1,2},{3,4}}"));
	assert(globMatch("3", "{{1,2},{3,4}}"));
	assert(globMatch("4", "{{1,2},{3,4}}"));
}

// Test escape sequences
debug(ae_unittest) @safe unittest
{
	// Escape special characters
	assert(globMatch("*", "\\*"));
	assert(globMatch("?", "\\?"));
	assert(globMatch("[", "\\["));
	assert(globMatch("]", "\\]"));
	assert(globMatch("{", "\\{"));
	assert(globMatch("}", "\\}"));
	assert(globMatch("\\", "\\\\"));

	// Wildcards match themselves as strings (and everything else)
	assert(globMatch("*", "*"));  // * pattern matches literal "*" string
	assert(globMatch("?", "?"));  // ? pattern matches literal "?" string

	// But escaped versions only match the literal
	assert(!globMatch("abc", "\\*"));  // Escaped * only matches literal "*"
	assert(!globMatch("ab", "\\?"));   // Escaped ? only matches literal "?"

	// Escape in patterns
	assert(globMatch("test*.txt", "test\\*.txt"));
	assert(globMatch("file?.log", "file\\?.log"));
	assert(globMatch("a[b]c", "a\\[b\\]c"));

	// Escape with wildcards
	assert(globMatch("prefix*suffix", "prefix\\*suffix"));
	assert(!globMatch("prefixXsuffix", "prefix\\*suffix"));
	assert(globMatch("test*abc", "test\\**"));

	// Multiple escapes
	assert(globMatch("a*b?c", "a\\*b\\?c"));
	assert(globMatch("**??", "\\*\\*\\?\\?"));
}

// Test character ranges
debug(ae_unittest) @safe unittest
{
	// Basic ranges
	assert(globMatch("a", "[a-z]"));
	assert(globMatch("m", "[a-z]"));
	assert(globMatch("z", "[a-z]"));
	assert(!globMatch("A", "[a-z]"));
	assert(!globMatch("0", "[a-z]"));

	assert(globMatch("A", "[A-Z]"));
	assert(globMatch("M", "[A-Z]"));
	assert(globMatch("Z", "[A-Z]"));
	assert(!globMatch("a", "[A-Z]"));

	assert(globMatch("0", "[0-9]"));
	assert(globMatch("5", "[0-9]"));
	assert(globMatch("9", "[0-9]"));
	assert(!globMatch("a", "[0-9]"));

	// Multiple ranges
	assert(globMatch("a", "[a-zA-Z]"));
	assert(globMatch("Z", "[a-zA-Z]"));
	assert(!globMatch("0", "[a-zA-Z]"));

	assert(globMatch("x", "[a-z0-9]"));
	assert(globMatch("5", "[a-z0-9]"));
	assert(!globMatch("X", "[a-z0-9]"));

	// Ranges with individual chars
	assert(globMatch("a", "[a-z_]"));
	assert(globMatch("_", "[a-z_]"));
	assert(globMatch("z", "[a-z_]"));

	// Negated ranges
	assert(!globMatch("a", "[!a-z]"));
	assert(!globMatch("m", "[!a-z]"));
	assert(globMatch("A", "[!a-z]"));
	assert(globMatch("0", "[!a-z]"));

	// In patterns
	assert(globMatch("test5.txt", "test[0-9].txt"));
	assert(globMatch("fileA.log", "file[A-Z].log"));
	assert(!globMatch("file5.log", "file[A-Z].log"));

	// Edge cases
	assert(globMatch("a", "[a-a]"));   // Single char range
	assert(globMatch("-", "[-]"));     // Literal dash at start
	assert(globMatch("-", "[a-]"));    // Literal dash at end
}

// Test character class escaping
debug(ae_unittest) @safe unittest
{
	// Escape ] inside character class
	assert(globMatch("]", "[\\]]"));
	assert(globMatch("]", "[]a]"));     // ] as first character
	assert(globMatch("a", "[]a]"));
	assert(!globMatch("b", "[]a]"));

	// Escape \ inside character class
	assert(globMatch("\\", "[\\\\]"));
	assert(globMatch("\\", "[\\\\a]"));
	assert(globMatch("a", "[\\\\a]"));

	// Escape - to prevent range
	assert(globMatch("-", "[a\\-z]"));
	assert(globMatch("a", "[a\\-z]"));
	assert(globMatch("z", "[a\\-z]"));
	assert(!globMatch("b", "[a\\-z]")); // Not a range!

	// Negated with escaped chars
	assert(!globMatch("]", "[!\\]]"));
	assert(globMatch("a", "[!\\]]"));
	assert(!globMatch("\\", "[!\\\\]"));
	assert(globMatch("a", "[!\\\\]"));

	// Mixed escaped and unescaped
	assert(globMatch("]", "[\\]a-z]"));
	assert(globMatch("a", "[\\]a-z]"));
	assert(globMatch("b", "[\\]a-z]"));
	assert(globMatch("z", "[\\]a-z]"));

	// Test toString round-trip for escaped chars
	import std.array : appender;
	auto testRoundTrip(string pattern)
	{
		auto compiled = compileGlob(pattern);
		auto app = appender!string;
		compiled.toString(app);
		auto reconstructed = compileGlob(app.data);
		// Test that both patterns match the same way
		assert(compiled.match("]") == reconstructed.match("]"));
		assert(compiled.match("\\") == reconstructed.match("\\"));
		assert(compiled.match("a") == reconstructed.match("a"));
	}

	testRoundTrip("[\\]]");
	testRoundTrip("[\\\\]");
	testRoundTrip("[]a]");
}

// Test POSIX character classes
debug(ae_unittest) unittest
{
	// [:alpha:] - alphabetic
	assert(compileGlob("[[:alpha:]]").match("a"));
	assert(compileGlob("[[:alpha:]]").match("Z"));
	assert(!compileGlob("[[:alpha:]]").match("5"));
	assert(!compileGlob("[[:alpha:]]").match("_"));

	// [:digit:] - digits
	assert(compileGlob("[[:digit:]]").match("0"));
	assert(compileGlob("[[:digit:]]").match("9"));
	assert(!compileGlob("[[:digit:]]").match("a"));

	// [:alnum:] - alphanumeric
	assert(compileGlob("[[:alnum:]]").match("a"));
	assert(compileGlob("[[:alnum:]]").match("5"));
	assert(!compileGlob("[[:alnum:]]").match("_"));
	assert(!compileGlob("[[:alnum:]]").match("-"));

	// [:space:] - whitespace
	assert(compileGlob("[[:space:]]").match(" "));
	assert(compileGlob("[[:space:]]").match("\t"));
	assert(compileGlob("[[:space:]]").match("\n"));
	assert(!compileGlob("[[:space:]]").match("a"));

	// [:blank:] - space and tab only
	assert(compileGlob("[[:blank:]]").match(" "));
	assert(compileGlob("[[:blank:]]").match("\t"));
	assert(!compileGlob("[[:blank:]]").match("\n"));
	assert(!compileGlob("[[:blank:]]").match("a"));

	// [:upper:] - uppercase
	assert(compileGlob("[[:upper:]]").match("A"));
	assert(compileGlob("[[:upper:]]").match("Z"));
	assert(!compileGlob("[[:upper:]]").match("a"));

	// [:lower:] - lowercase
	assert(compileGlob("[[:lower:]]").match("a"));
	assert(compileGlob("[[:lower:]]").match("z"));
	assert(!compileGlob("[[:lower:]]").match("A"));

	// [:xdigit:] - hexadecimal digits
	assert(compileGlob("[[:xdigit:]]").match("0"));
	assert(compileGlob("[[:xdigit:]]").match("9"));
	assert(compileGlob("[[:xdigit:]]").match("a"));
	assert(compileGlob("[[:xdigit:]]").match("F"));
	assert(!compileGlob("[[:xdigit:]]").match("g"));

	// [:punct:] - punctuation
	assert(compileGlob("[[:punct:]]").match("."));
	assert(compileGlob("[[:punct:]]").match("_"));
	assert(compileGlob("[[:punct:]]").match("!"));
	assert(!compileGlob("[[:punct:]]").match("a"));

	// [:graph:] - visible characters (no space)
	assert(compileGlob("[[:graph:]]").match("a"));
	assert(compileGlob("[[:graph:]]").match("!"));
	assert(!compileGlob("[[:graph:]]").match(" "));

	// [:print:] - printable characters (including space)
	assert(compileGlob("[[:print:]]").match("a"));
	assert(compileGlob("[[:print:]]").match(" "));
	assert(!compileGlob("[[:print:]]").match("\t"));

	// [:cntrl:] - control characters
	assert(compileGlob("[[:cntrl:]]").match("\t"));
	assert(compileGlob("[[:cntrl:]]").match("\n"));
	assert(!compileGlob("[[:cntrl:]]").match("a"));

	// Negated POSIX classes
	assert(!compileGlob("[![:digit:]]").match("5"));
	assert(compileGlob("[![:digit:]]").match("a"));

	// Combined with regular chars
	assert(compileGlob("[[:digit:]_]").match("5"));
	assert(compileGlob("[[:digit:]_]").match("_"));
	assert(!compileGlob("[[:digit:]_]").match("a"));

	// Combined with ranges
	assert(compileGlob("[a-z[:digit:]]").match("a"));
	assert(compileGlob("[a-z[:digit:]]").match("5"));
	assert(!compileGlob("[a-z[:digit:]]").match("A"));

	// Multiple POSIX classes
	assert(compileGlob("[[:alpha:][:digit:]]").match("a"));
	assert(compileGlob("[[:alpha:][:digit:]]").match("5"));
	assert(!compileGlob("[[:alpha:][:digit:]]").match("_"));

	// In patterns
	assert(compileGlob("test[[:digit:]].txt").match("test5.txt"));
	assert(!compileGlob("test[[:digit:]].txt").match("testA.txt"));

	// Test toString round-trip
	import std.array : appender;
	auto p1 = compileGlob("[[:alpha:]]");
	auto app = appender!string;
	p1.toString(app);
	assert(app.data == "[[:alpha:]]");

	auto p2 = compileGlob("[a[:digit:]z]");
	app = appender!string;
	p2.toString(app);
	assert(app.data == "[az[:digit:]]"); // Reordered: chars before POSIX classes
}

// Test patterns within braces
debug(ae_unittest) @safe unittest
{
	// Wildcards in braces
	assert(globMatch("foo-test", "{foo-*,bar}"));
	assert(globMatch("bar", "{foo-*,bar}"));
	assert(!globMatch("baz", "{foo-*,bar}"));

	// Star at start
	assert(globMatch("test-bar", "{*-bar,foo}"));
	assert(globMatch("foo", "{*-bar,foo}"));
	assert(!globMatch("test-baz", "{*-bar,foo}"));

	// Both wildcards
	assert(globMatch("prefix-middle-suffix", "{*-*,foo}"));
	assert(globMatch("foo", "{*-*,foo}"));
	assert(!globMatch("noseparator", "{*-*,foo}"));

	// Nested braces with wildcards
	assert(globMatch("foo-test", "{foo-*,*-{bar,baz-*}}"));
	assert(globMatch("test-bar", "{foo-*,*-{bar,baz-*}}"));
	assert(globMatch("x-baz-y", "{foo-*,*-{bar,baz-*}}"));
	assert(!globMatch("test-qux", "{foo-*,*-{bar,baz-*}}"));

	// Question mark in braces
	assert(globMatch("file1", "{file?,dir}"));
	assert(globMatch("dir", "{file?,dir}"));
	assert(!globMatch("file12", "{file?,dir}"));

	// Character classes in braces
	assert(globMatch("file1.txt", "{file[0-9].txt,dir}"));
	assert(globMatch("dir", "{file[0-9].txt,dir}"));
	assert(!globMatch("fileA.txt", "{file[0-9].txt,dir}"));

	// Complex nested example
	assert(globMatch("foo-bar", "{foo-{bar,baz},test-*}"));
	assert(globMatch("foo-baz", "{foo-{bar,baz},test-*}"));
	assert(globMatch("test-anything", "{foo-{bar,baz},test-*}"));
	assert(!globMatch("foo-qux", "{foo-{bar,baz},test-*}"));

	// Multiple levels of nesting with wildcards
	assert(globMatch("a-b-c", "{a-*,{b-*,c-*}}"));
	assert(globMatch("b-x", "{a-*,{b-*,c-*}}"));
	assert(globMatch("c-y", "{a-*,{b-*,c-*}}"));

	// Star in alternative with continuation after brace (user's test case)
	assert(globMatch("bar-rrrr-baz", "{foo,bar-*}-baz"));
	assert(globMatch("foo-baz", "{foo,bar-*}-baz"));
	assert(globMatch("bar-x-baz", "{foo,bar-*}-baz"));
	assert(!globMatch("baz-bar", "{foo,bar-*}-baz"));
	assert(!globMatch("bar-rrrr", "{foo,bar-*}-baz"));  // Missing suffix

	// Multiple patterns with continuation
	assert(globMatch("a-x-y-z", "{a-*,b}-y-z"));
	assert(globMatch("b-y-z", "{a-*,b}-y-z"));
	assert(!globMatch("a-x-y", "{a-*,b}-y-z"));

	// Nested braces with wildcards and continuation
	assert(globMatch("x-a-suffix", "{*-{a,b},c}-suffix"));
	assert(globMatch("y-b-suffix", "{*-{a,b},c}-suffix"));
	assert(globMatch("c-suffix", "{*-{a,b},c}-suffix"));
	assert(!globMatch("x-a", "{*-{a,b},c}-suffix"));

	// Empty alternatives with wildcards
	assert(globMatch("", "{,*-suffix}"));  // Empty string matches first alternative
	assert(globMatch("x-suffix", "{,*-suffix}"));  // Matches second alternative
	assert(!globMatch("test", "{,*-suffix}"));  // Doesn't match either

	// Prefix with empty alternative
	assert(globMatch("prefix", "prefix{,*-suffix}"));
	assert(globMatch("prefix-test-suffix", "prefix{,*-suffix}"));
	assert(!globMatch("test", "prefix{,*-suffix}"));

	// Deep nesting - test continuation chaining
	assert(globMatch("abcdef", "{a{b{c}d}e}f"));
	assert(globMatch("abcd", "a{b{c}d}"));
	assert(!globMatch("abc", "{a{b{c}d}e}f"));  // Missing parts
}

// Test stringification
debug(ae_unittest) unittest
{
	import std.conv : to;

	// Test explicit instantiation with a simple sink
	static struct DummySink
	{
		char[] data;
		void put(char c) { data ~= c; }
	}

	auto pattern = compileGlob("foo.bar");
	DummySink sink;
	pattern.toString(sink);
	assert(sink.data == "foo.bar");

	// Simple patterns
	assert(compileGlob("foo.bar").to!string == "foo.bar");
	assert(compileGlob("*.txt").to!string == "*.txt");
	assert(compileGlob("test?").to!string == "test?");
	assert(compileGlob("f*b?r").to!string == "f*b?r");

	// Character classes (note: chars and ranges may be reordered)
	assert(compileGlob("[abc]").to!string == "[abc]");
	assert(compileGlob("[a-z]").to!string == "[a-z]");
	assert(compileGlob("[!0-9]").to!string == "[!0-9]");
	assert(compileGlob("[a-z0-9_]").to!string == "[_a-z0-9]"); // Reordered: chars before ranges

	// Brace alternatives
	assert(compileGlob("{foo,bar}").to!string == "{foo,bar}");
	assert(compileGlob("test.{c,cpp,d}").to!string == "test.{c,cpp,d}");
	assert(compileGlob("{foo,bar}.{baz,qux}").to!string == "{foo,bar}.{baz,qux}");

	// Nested braces
	assert(compileGlob("{a,{b,c}}").to!string == "{a,{b,c}}");
	assert(compileGlob("{{1,2},{3,4}}").to!string == "{{1,2},{3,4}}");

	// Wildcards in braces
	assert(compileGlob("{foo-*,bar}").to!string == "{foo-*,bar}");
	assert(compileGlob("{*-bar,foo}").to!string == "{*-bar,foo}");

	// Escaped characters (special chars in literals get escaped)
	assert(compileGlob("\\*").to!string == "\\*");
	assert(compileGlob("\\?").to!string == "\\?");
	assert(compileGlob("\\[").to!string == "\\[");
	assert(compileGlob("\\{").to!string == "\\{");

	// Complex patterns
	assert(compileGlob("src/**/*.{c,cpp,d}").to!string == "src/**/*.{c,cpp,d}");
	assert(compileGlob("test[0-9].{log,txt}").to!string == "test[0-9].{log,txt}");
}
