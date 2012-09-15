/**
 * Simple execution of shell commands, and wrappers for common utilities.
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

module ae.sys.cmd;

string getTempFileName(string extension)
{
	// TODO: use proper OS directories
	import std.random;
	import std.conv;

	static int counter;
	if (!std.file.exists("data"    )) std.file.mkdir("data");
	if (!std.file.exists("data/tmp")) std.file.mkdir("data/tmp");
	return "data/tmp/run-" ~ to!string(uniform!uint()) ~ "-" ~ to!string(counter++) ~ "." ~ extension;
}

// ************************************************************************

// Will be made redundant by https://github.com/D-Programming-Language/phobos/pull/457

/*
	Command line arguments exist in three forms:
	1) string or char* array, as received by main.
	   Also used internally on POSIX systems.
	2) Command line string, as used in Windows'
	   CreateProcess and CommandLineToArgvW functions.
	   A specific quoting and escaping algorithm is used
	   to distinguish individual arguments.
	3) Shell command string, as written at a shell prompt
	   or passed to cmd /C - this one may contain shell
	   control characters, e.g. > or | for redirection /
	   piping - thus, yet another layer of escaping is
	   used to distinguish them from program arguments.

	Except for escapeWindowsArgument, the intermediary
	format (2) is hidden away from the user in this module.
*/

pure @safe nothrow
private char[] charAllocator(size_t size) { return new char[size]; }

/**
	Quote an argument in a manner conforming to the behavior of
	$(LINK2 http://msdn.microsoft.com/en-us/library/windows/desktop/bb776391(v=vs.85).aspx,
	CommandLineToArgvW).
*/

pure nothrow
string escapeWindowsArgument(in char[] arg)
{
	// Rationale for leaving this function as public:
	// this algorithm of escaping paths is also used in other software,
	// e.g. DMD's response files.

	auto buf = escapeWindowsArgumentImpl!charAllocator(arg);
	return assumeUnique(buf);
}

@safe nothrow
private char[] escapeWindowsArgumentImpl(alias allocator)(in char[] arg)
	if (is(typeof(allocator(size_t.init)[0] = char.init)))
{
	// References:
	// * http://msdn.microsoft.com/en-us/library/windows/desktop/bb776391(v=vs.85).aspx
	// * http://blogs.msdn.com/b/oldnewthing/archive/2010/09/17/10063629.aspx

	// Calculate the total string size.

	// Trailing backslashes must be escaped
	bool escaping = true;
	// Result size = input size + 2 for surrounding quotes + 1 for the
	// backslash for each escaped character.
	size_t size = 1 + arg.length + 1;

	foreach_reverse (c; arg)
	{
		if (c == '"')
		{
			escaping = true;
			size++;
		}
		else
		if (c == '\\')
		{
			if (escaping)
				size++;
		}
		else
			escaping = false;
	}

	// Construct result string.

	auto buf = allocator(size);
	size_t p = size;
	buf[--p] = '"';
	escaping = true;
	foreach_reverse (c; arg)
	{
		if (c == '"')
			escaping = true;
		else
		if (c != '\\')
			escaping = false;

		buf[--p] = c;
		if (escaping)
			buf[--p] = '\\';
	}
	buf[--p] = '"';
	assert(p == 0);

	return buf;
}

version(Windows) version(unittest)
{
	import core.sys.windows.windows;
	import core.stdc.stddef;

	extern (Windows) wchar_t**  CommandLineToArgvW(wchar_t*, int*);
	extern (C) size_t wcslen(in wchar *);

	unittest
	{
		string[] testStrings = [
			`Hello`,
			`Hello, world`,
			`Hello, "world"`,
			`C:\`,
			`C:\dmd`,
			`C:\Program Files\`,
		];

		enum CHARS = `_x\" *&^`; // _ is placeholder for nothing
		foreach (c1; CHARS)
		foreach (c2; CHARS)
		foreach (c3; CHARS)
		foreach (c4; CHARS)
			testStrings ~= [c1, c2, c3, c4].replace("_", "");

		foreach (s; testStrings)
		{
			auto q = escapeWindowsArgument(s);
			LPWSTR lpCommandLine = (to!(wchar[])("Dummy.exe " ~ q) ~ "\0"w).ptr;
			int numArgs;
			LPWSTR* args = CommandLineToArgvW(lpCommandLine, &numArgs);
			scope(exit) LocalFree(args);
			assert(numArgs==2, s ~ " => " ~ q ~ " #" ~ text(numArgs-1));
			auto arg = to!string(args[1][0..wcslen(args[1])]);
			assert(arg == s, s ~ " => " ~ q ~ " => " ~ arg);
		}
	}
}

pure nothrow
private string escapePosixArgument(in char[] arg)
{
	auto buf = escapePosixArgumentImpl!charAllocator(arg);
	return assumeUnique(buf);
}

@safe nothrow
private char[] escapePosixArgumentImpl(alias allocator)(in char[] arg)
	if (is(typeof(allocator(size_t.init)[0] = char.init)))
{
	// '\'' means: close quoted part of argument, append an escaped
	// single quote, and reopen quotes

	// Below code is equivalent to:
	// return `'` ~ std.array.replace(arg, `'`, `'\''`) ~ `'`;

	size_t size = 1 + arg.length + 1;
	foreach (c; arg)
		if (c == '\'')
			size += 3;

	auto buf = allocator(size);
	size_t p = 0;
	buf[p++] = '\'';
	foreach (c; arg)
		if (c == '\'')
			buf[p..p+4] = `'\''`;
		else
			buf[p++] = c;
	buf[p++] = '\'';
	assert(p == size);

	return buf;
}

@safe nothrow
private auto escapeShellArgument(alias allocator)(in char[] arg)
{
	// The unittest for this function requires special
	// preparation - see below.

	version (Windows)
		return escapeWindowsArgumentImpl!allocator(arg);
	else
		return escapePosixArgumentImpl!allocator(arg);
}

pure nothrow
private string escapeShellArguments(in char[][] args)
{
	char[] buf;

	@safe nothrow
	char[] allocator(size_t size)
	{
		if (buf.length == 0)
			return buf = new char[size];
		else
		{
			auto p = buf.length;
			buf.length = buf.length + 1 + size;
			buf[p++] = ' ';
			return buf[p..p+size];
		}
	}

	foreach (arg; args)
		escapeShellArgument!allocator(arg);
	return assumeUnique(buf);
}

string escapeWindowsShellCommand(in char[] command)
{
	auto result = appender!string();
	result.reserve(command.length);

	foreach (c; command)
		switch (c)
		{
			case '\0':
				assert(0, "Cannot put NUL in command line");
			case '\r':
			case '\n':
				assert(0, "CR/LF are not escapable");
			case '\x01': .. case '\x09':
			case '\x0B': .. case '\x0C':
			case '\x0E': .. case '\x1F':
			case '"':
			case '^':
			case '&':
			case '<':
			case '>':
			case '|':
				result.put('^');
				goto default;
			default:
				result.put(c);
		}
	return result.data();
}

private string escapeShellCommandString(string command)
{
	version (Windows)
		return escapeWindowsShellCommand(command);
	else
		return command;
}

/**
	Escape an argv-style argument array to be used with the
	$(D system) or $(D shell) functions.

	Example:
---
string url = "http://dlang.org/";
system(escapeShellCommand("wget", url, "-O", "dlang-index.html"));
---

	Concatenate multiple $(D escapeShellCommand) and
	$(D escapeShellFileName) results to use shell redirection or
	piping operators.

	Example:
---
system(
	escapeShellCommand("curl", "http://dlang.org/download.html") ~
	"|" ~
	escapeShellCommand("grep", "-o", `http://\S*\.zip`) ~
	">" ~
	escapeShellFileName("D download links.txt"));
---
*/

string escapeShellCommand(in char[][] args...)
{
	return escapeShellCommandString(escapeShellArguments(args));
}

/**
	Escape a filename to be used for shell redirection with
	the $(D system) or $(D shell) functions.
*/

pure nothrow
string escapeShellFileName(in char[] fn)
{
	// The unittest for this function requires special
	// preparation - see below.

	version (Windows)
		return cast(string)('"' ~ fn ~ '"');
	else
		return escapePosixArgument(fn);
}

// Loop generating strings with random characters
//version = unittest_burnin;

version(unittest_burnin)
unittest
{
	// There are no readily-available commands on all platforms suitable
	// for properly testing command escaping. The behavior of CMD's "echo"
	// built-in differs from the POSIX program, and Windows ports of POSIX
	// environments (Cygwin, msys, gnuwin32) may interfere with their own
	// "echo" ports.

	// To run this unit test, create std_process_unittest_helper.d with the
	// following content and compile it:
	// import std.stdio, std.array; void main(string[] args) { write(args.join("\0")); }
	// Then, test this module with:
	// rdmd --main -unittest -version=unittest_burnin process.d

	auto helper = rel2abs("std_process_unittest_helper");
	assert(shell(helper ~ " hello").split("\0")[1..$] == ["hello"], "Helper malfunction");

	void test(string[] s, string fn)
	{
		string e;
		string[] g;

		e = escapeShellCommand(helper ~ s);
		{
			scope(failure) writefln("shell() failed.\nExpected:\t%s\nEncoded:\t%s", s, [e]);
			g = shell(e).split("\0")[1..$];
		}
		assert(s == g, format("shell() test failed.\nExpected:\t%s\nGot:\t\t%s\nEncoded:\t%s", s, g, [e]));

		e = escapeShellCommand(helper ~ s) ~ ">" ~ escapeShellFileName(fn);
		{
			scope(failure) writefln("system() failed.\nExpected:\t%s\nFilename:\t%s\nEncoded:\t%s", s, [fn], [e]);
			system(e);
			g = readText(fn).split("\0")[1..$];
		}
		remove(fn);
		assert(s == g, format("system() test failed.\nExpected:\t%s\nGot:\t\t%s\nEncoded:\t%s", s, g, [e]));
	}

	while (true)
	{
		string[] args;
		foreach (n; 0..uniform(1, 4))
		{
			string arg;
			foreach (l; 0..uniform(0, 10))
			{
				dchar c;
				while (true)
				{
					version (Windows)
					{
						// As long as DMD's system() uses CreateProcessA,
						// we can't reliably pass Unicode
						c = uniform(0, 128);
					}
					else
						c = uniform!ubyte();

					if (c == 0)
						continue; // argv-strings are zero-terminated
					version (Windows)
						if (c == '\r' || c == '\n')
							continue; // newlines are unescapable on Windows
					break;
				}
				arg ~= c;
			}
			args ~= arg;
		}

		// generate filename
		string fn = "test_";
		foreach (l; 0..uniform(1, 10))
		{
			dchar c;
			while (true)
			{
				version (Windows)
					c = uniform(0, 128); // as above
				else
					c = uniform!ubyte();

				if (c == 0 || c == '/')
					continue; // NUL and / are the only characters
							  // forbidden in POSIX filenames
				version (Windows)
					if (c < '\x20' || c == '<' || c == '>' || c == ':' ||
						c == '"' || c == '\\' || c == '|' || c == '?' || c == '*')
						continue; // http://msdn.microsoft.com/en-us/library/aa365247(VS.85).aspx
				break;
			}

			fn ~= c;
		}

		test(args, fn);
	}
}

// ************************************************************************

import std.process;
import std.string;
import std.array;
import std.exception;

string run(string command, string input = null)
{
	string tempfn = getTempFileName("txt"); // HACK
	string tempfn2;
	if (input !is null)
	{
		tempfn2 = getTempFileName("txt");
		std.file.write(tempfn2, input);
		command ~= " < " ~ tempfn2;
	}
	version(Windows)
		system(command ~ ` 2>&1 > ` ~ tempfn);
	else
		system(command ~ ` &> ` ~ tempfn);
	string result = cast(string)std.file.read(tempfn);
	std.file.remove(tempfn);
	if (tempfn2) std.file.remove(tempfn2);
	return result;
}

string run(string[] args)
{
	return run(escapeShellCommand(args));
}

// ************************************************************************

static import std.uri;

string[] extraWgetOptions;
string cookieFile = "data/cookies.txt";

void enableCookies()
{
	if (!std.file.exists(cookieFile))
		std.file.write(cookieFile, "");
	extraWgetOptions ~= ["--load-cookies", cookieFile, "--save-cookies", cookieFile, "--keep-session-cookies"];
}

string download(string url)
{
	auto dataFile = getTempFileName("wget"); scope(exit) if (std.file.exists(dataFile)) std.file.remove(dataFile);
	auto result = spawnvp(P_WAIT, "wget", ["wget", "-q", "--no-check-certificate", "-O", dataFile] ~ extraWgetOptions ~ [url]);
	enforce(result==0, "wget error");
	return cast(string)std.file.read(dataFile);
}

string post(string url, string data)
{
	auto postFile = getTempFileName("txt");
	std.file.write(postFile, data);
	scope(exit) std.file.remove(postFile);

	auto dataFile = getTempFileName("wget"); scope(exit) if (std.file.exists(dataFile)) std.file.remove(dataFile);
	auto result = spawnvp(P_WAIT, "wget", ["wget", "-q", "--no-check-certificate", "-O", dataFile, "--post-file", postFile] ~ extraWgetOptions ~ [url]);
	enforce(result==0, "wget error");
	return cast(string)std.file.read(dataFile);
}

string put(string url, string data)
{
	auto putFile = getTempFileName("txt");
	std.file.write(putFile, data);
	scope(exit) std.file.remove(putFile);

	auto dataFile = getTempFileName("curl"); scope(exit) if (std.file.exists(dataFile)) std.file.remove(dataFile);
	auto result = spawnvp(P_WAIT, "curl", ["curl", "-s", "-k", "-X", "PUT", "-o", dataFile, "-d", "@" ~ putFile, url]);
	enforce(result==0, "curl error");
	return cast(string)std.file.read(dataFile);
}

string shortenURL(string url)
{
	// TODO: proper config support
	if (std.file.exists("data/bitly.txt"))
		return strip(download(format("http://api.bitly.com/v3/shorten?%s&longUrl=%s&format=txt&domain=j.mp", cast(string)std.file.read("data/bitly.txt"), std.uri.encodeComponent(url))));
	else
		return url;
}

string iconv(string data, string inputEncoding, string outputEncoding = "UTF-8")
{
	return run(format("iconv -f %s -t %s", inputEncoding, outputEncoding), data);
}

string sha1sum(void[] data)
{
	auto dataFile = getTempFileName("sha1data");
	std.file.write(dataFile, data);
	scope(exit) std.file.remove(dataFile);

	return run(["sha1sum", "-b", dataFile])[0..40];
}

// ************************************************************************

version (Windows)
	enum NULL_FILE = "nul";
else
	enum NULL_FILE = "/dev/null";
