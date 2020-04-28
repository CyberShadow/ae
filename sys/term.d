/**
 * Basic cross-platform color output
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

module ae.sys.term;

import std.stdio;

/// Base class for a terminal implementation.
/// The interface only contains the common subset of features
/// available on both platforms (Windows API and ANSI).
abstract class Term
{
	/// The 16 standard VGA/ANSI colors plus a "none" pseudo-color.
	enum Color : byte
	{
		none          = -1, /// transparent or default

		black         = 0,

		red           = 1 << 0,
		green         = 1 << 1,
		blue          = 1 << 2,

		yellow        = red | green       ,
		magenta       = red |         blue,
		cyan          =       green | blue,
		gray          = red | green | blue,

		darkGray      = bright | black,
		brightRed     = bright | red,
		brightGreen   = bright | green,
		brightBlue    = bright | blue,
		brightYellow  = bright | yellow,
		brightMagenta = bright | magenta,
		brightCyan    = bright | cyan,
		white         = bright | gray,

		// Place this definition after the colors so that e.g.
		// std.conv prefers the color name over this flag name.
		bright        = 1 << 3,
	}

	private enum mixColorAliases(T) = (){
		import std.traits : EnumMembers;
		string s;
		foreach (i, m; EnumMembers!Color)
		{
			enum name = __traits(identifier, EnumMembers!Color[i]);
			s ~= `enum ` ~ name ~ ` = ` ~ T.stringof ~ `(Color.` ~ name ~ `);`;
		}

		return s;
	}();

	/// Color wrapping formatting operations for put.
	struct ForegroundColor { Color c; mixin(mixColorAliases!ForegroundColor); }
	struct BackgroundColor { Color c; mixin(mixColorAliases!BackgroundColor); } /// ditto

	/// Shorthands
	alias fg = ForegroundColor;
	alias bg = BackgroundColor; /// ditto
	mixin(mixColorAliases!ForegroundColor); /// ditto

	/// Puts some combination of colors and stringifiable objects in order.
	void put(Args...)(auto ref Args args)
	{
		putImpl(InitState.init, args);
	}

private:
	void putImpl(State, Args...)(State state, ref Args args)
	{
		// Use a tail recursion and maintain state using a type to
		// allow congesting consecutive formatting operations into a
		// single terminal operation.
		// E.g.: `fg.a, bg.b` (or swapped) gets encoded as `\e[3a;4bm`
		// instead of `\e[3am\e[4bm`
		// E.g.: `fg.a, fg.b` gets encoded as `\e[3bm` instead of
		// `\e[3am\e[3bm`
		static if (Args.length == 0)
			flush(state);
		else
		{
			alias A = Args[0];
			static if (is(A == ForegroundColor))
			{
				static struct NextState
				{
					ForegroundColor fg;
					typeof(State.bg) bg;
				}
				return putImpl(NextState(args[0], state.bg), args[1..$]);
			}
			else
			static if (is(A == BackgroundColor))
			{
				static struct NextState
				{
					typeof(State.fg) fg;
					BackgroundColor bg;
				}
				return putImpl(NextState(state.fg, args[0]), args[1..$]);
			}
			else
			{
				flush(state);
				static if (is(A : const(char)[]))
					putText(args[0]);
				else
				{
					import std.format : formattedWrite;
					formattedWrite!"%s"(&putText, args[0]);
				}
				return putImpl(initState, args[1..$]);
			}
		}
	}

	alias NoColor = void[0];
	static struct InitState
	{
		NoColor fg, bg;
	}
	enum initState = InitState.init;

	void flush(State)(State state)
	{
		static if (!is(typeof(state.bg) == NoColor))
			static if (!is(typeof(state.fg) == NoColor))
				setColor(state.bg.c, state.fg.c);
			else
				setBackgroundColor(state.bg.c);
		else
			static if (!is(typeof(state.fg) == NoColor))
				setTextColor(state.fg.c);
	}

protected:
	void putText(in char[] s);
	void setTextColor(Color c);
	void setBackgroundColor(Color c);
	void setColor(Color fg, Color bg);
}

/// No output (including text).
/// (See DumbTerm for text-only output).
class NullTerm : Term
{
protected:
	override void putText(in char[] s) {}
	override void setTextColor(Color c) {}
	override void setBackgroundColor(Color c) {}
	override void setColor(Color fg, Color bg) {}
}

/// Base class for File-based terminal implementations.
abstract class FileTerm : Term
{
	File f;

protected:
	override void putText(in char[] s) { f.rawWrite(s); }
}

/// No color, only text output.
class DumbTerm : FileTerm
{
	this(File f)
	{
		this.f = f;
	}

protected:
	override void setTextColor(Color c) {}
	override void setBackgroundColor(Color c) {}
	override void setColor(Color fg, Color bg) {}
}

/// ANSI escape sequence based terminal.
class ANSITerm : FileTerm
{
	static bool isTerm(File f)
	{
		version (Posix)
		{
			import core.sys.posix.unistd : isatty;
			if (!isatty(f.fileno))
				return false;
		}

		import std.process : environment;
		auto term = environment.get("TERM");
		if (!term || term == "dumb")
			return false;
		return true;
	}

	static int ansiColor(Color c, bool background)
	{
		if (c < -1 || c > Color.white)
			assert(false);

		int result;
		if (c == Color.none)
			result = 39;
		else
		if (c & Color.bright)
			result = 90 + (c & ~uint(Color.bright));
		else
			result = 30 + c;
		if (background)
			result += 10;
		return result;
	}

	this(File f)
	{
		this.f = f;
	}

protected:
	override void setTextColor(Color c)
	{
		f.writef("\x1b[%dm", ansiColor(c, false));
	}

	override void setBackgroundColor(Color c)
	{
		f.writef("\x1b[%dm", ansiColor(c, true));
	}

	override void setColor(Color fg, Color bg)
	{
		f.writef("\x1b[%d;%dm", ansiColor(fg, false), ansiColor(bg, true));
	}
}

/// Windows API based terminal.
version (Windows)
class WindowsTerm : FileTerm
{
	import core.sys.windows.basetsd : HANDLE;
	import core.sys.windows.windef : WORD;
	import core.sys.windows.wincon : CONSOLE_SCREEN_BUFFER_INFO, GetConsoleScreenBufferInfo, SetConsoleTextAttribute;
	import ae.sys.windows.exception : wenforce;

	static bool isTerm(File f)
	{
		CONSOLE_SCREEN_BUFFER_INFO info;
		return !!GetConsoleScreenBufferInfo(f.windowsHandle, &info);
	}

	HANDLE handle;
	WORD attributes, origAttributes;

	this(File f)
	{
		this.f = f;
		handle = f.windowsHandle;

		CONSOLE_SCREEN_BUFFER_INFO info;
		GetConsoleScreenBufferInfo(handle, &info)
			.wenforce("GetConsoleScreenBufferInfo");
		attributes = origAttributes = info.wAttributes;
	}

protected:
	final void setAttribute(bool background)(Color c)
	{
		enum shift = background ? 4 : 0;
		enum mask = 0xF << shift;
		if (c == Color.none)
			attributes = (attributes & ~mask) | (origAttributes & mask);
		else
		{
			WORD value = c;
			value <<= shift;
			attributes = (attributes & ~mask) | value;
		}
	}

	final void applyAttribute()
	{
		f.flush();
		SetConsoleTextAttribute(handle, attributes)
			.wenforce("SetConsoleTextAttribute");
	}

	override void setTextColor(Color c)
	{
		setAttribute!false(c);
		applyAttribute();
	}

	override void setBackgroundColor(Color c)
	{
		setAttribute!true(c);
		applyAttribute();
	}

	override void setColor(Color fg, Color bg)
	{
		setAttribute!false(fg);
		setAttribute!true(bg);
		applyAttribute();
	}
}

/// Returns whether the given file is likely to be attached to a terminal.
bool isTerm(File f)
{
	version (Windows)
	{
		if (WindowsTerm.isTerm(f))
			return true;
		// fall through - we might be on a POSIX environment on Windows
	}
	return ANSITerm.isTerm(f);
}

/// Choose a suitable terminal implementation for the given file, create and return it.
Term makeTerm(File f = stderr)
{
	if (isTerm(f))
		version (Windows)
			return new WindowsTerm(f);
		else
			return new ANSITerm(f);
	else
		return new DumbTerm(f);
}

/// Get or set a Term implementation for the current thread (creating one if necessary).
private Term globalTerm;
@property Term term()
{
	if (!globalTerm)
		globalTerm = makeTerm();
	return globalTerm;
}
@property Term term(Term newTerm) /// ditto
{
	return globalTerm = newTerm;
}

version (ae_sys_term_demo)
void main()
{
	auto t = term;
	foreach (bg; -1 .. 16)
	{
		t.put(t.bg(cast(Term.Color)bg));
		foreach (fg; -1 .. 16)
			t.put(t.fg(cast(Term.Color)fg), "XX");
		t.put(t.none, t.bg.none, "\n");
	}
	readln();
}
