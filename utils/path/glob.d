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

/// Compiled glob pattern with fast @nogc matching
struct CompiledGlob(C)
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

	/// Match a path against this compiled pattern (@nogc, fast)
	bool match(const(C)[] path) const pure nothrow @nogc
	{
		size_t consumed = matchImpl(path, 0, instructions, 0, null);
		return consumed != size_t.max && consumed == path.length;
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

				// Find closing ]
				size_t end = start;
				while (end < pattern.length && pattern[end] != ']')
					end++;

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

					for (size_t j = start; j < end; )
					{
						// Check for range pattern: char-char
						if (j + 2 < end && pattern[j + 1] == '-')
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
						instr.charClass = CharClassData(chars, ranges, negated);
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
}

/// Compile a glob pattern (GC allowed, done once)
CompiledGlob!C compileGlob(C)(const(C)[] pattern) pure
{
	return CompiledGlob!C(pattern);
}

// std.path-like API for testing
private bool globMatch(C)(const(C)[] path, const(C)[] pattern)
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
