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

import core.thread;

import std.exception;
import std.process;
import std.stdio;
import std.string;

import ae.sys.file;

string getTempFileName(string extension)
{
	import std.random;
	import std.file;
	import std.path : buildPath;

	static int counter;
	return buildPath(tempDir(), format("run-%d-%d-%d.%s",
		getpid(),
		uniform!uint(),
		counter++,
		extension
	));
}

// ************************************************************************

private void invoke(alias runner)(string[] args)
{
	//debug scope(failure) std.stdio.writeln("[CWD] ", getcwd());
	auto status = runner();
	enforce(status == 0, "Command %s failed with status %d".format(args, status));
}

/// std.process helper. Run a command, and throw if it exited with a non-zero status.
void run(string[] args)
{
	invoke!({ return spawnProcess(args).wait(); })(args);
}

/// std.process helper. Run a command, collect its output, and throw if it exited with a non-zero status.
string query(string[] args)
{
	string output;
	invoke!({ auto result = execute(args); output = result.output.strip(); return result.status; })(args);
	return output;
}

/// std.process helper. Run a command, feed it the given input, and collect its output.
/// Throw if it exited with non-zero status. Return output.
T[] pipe(T)(string[] args, in T[] input)
{
	T[] output;
	invoke!({
		auto pipes = pipeProcess(args);
		auto f = pipes.stdin;
		auto writer = writeFileAsync(f, input);
		scope(exit) writer.join();
		output = cast(T[])readFile(pipes.stdout);
		return pipes.pid.wait();
	})(args);
	return output;
}

// ************************************************************************

ubyte[] iconv(in void[] data, string inputEncoding, string outputEncoding)
{
	auto result = pipe(["iconv", "-f", inputEncoding, "-t", outputEncoding], data);
	return cast(ubyte[])result;
}

string iconv(in void[] data, string inputEncoding)
{
	import std.utf;
	auto result = cast(string)iconv(data, inputEncoding, "UTF-8");
	validate(result);
	return result;
}

unittest
{
	//assert(iconv("Hello"w, "UTF-16LE") == "Hello");
}

string sha1sum(in void[] data)
{
	auto output = cast(string)pipe(["sha1sum", "-b", "-"], data);
	return output[0..40];
}

version (sha1sum)
unittest
{
	assert(sha1sum("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
	assert(sha1sum("a  b\nc\r\nd") == "667c71ffe2ac8a4fe500e3b96435417e4c5ec13b");
}

// ************************************************************************

version (Windows)
	enum NULL_FILE = "nul";
else
	enum NULL_FILE = "/dev/null";
