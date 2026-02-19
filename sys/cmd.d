/**
 * Simple execution of shell commands,
 * and wrappers for common utilities.
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

module ae.sys.cmd;

import core.thread;

import std.exception;
import std.process;
import std.stdio;
import std.string;
import std.traits;

import ae.sys.data : TData;
import ae.sys.file;
import ae.utils.array : asBytes;
import ae.utils.text.ascii : ascii;

private template hasIndirections(T)
{
    static if (is(T == enum))
        enum hasIndirections = hasIndirections!(OriginalType!T);
    else static if (is(T == struct) || is(T == union))
        enum hasIndirections = anySatisfy!(.hasIndirections, typeof(T.tupleof));
    else static if (__traits(isAssociativeArray, T) || is(T == class) || is(T == interface))
        enum hasIndirections = true;
    else static if (is(T == E[N], E, size_t N))
        enum hasIndirections = T.sizeof && hasIndirections!(BaseElemOf!E);
    else static if (isFunctionPointer!T)
        enum hasIndirections = false;
    else static if (is(immutable(T) == immutable(void)))
        enum hasIndirections = true;
    else
        enum hasIndirections = isPointer!T || isDelegate!T || isDynamicArray!T;
}

/// Returns a very unique name for a temporary file.
string getTempFileName(string extension)
{
	import std.random : uniform;
	import std.file : tempDir;
	import std.path : buildPath;

	static int counter;
	return buildPath(tempDir(), format("run-%d-%d-%d-%d.%s",
		getpid(),
		getCurrentThreadID(),
		uniform!uint(),
		counter++,
		extension
	));
}

version (linux)
{
	import core.sys.posix.sys.types : pid_t;
	private extern(C) pid_t gettid();
}

/// Like `thisProcessID`, but for threads.
ulong getCurrentThreadID()
{
	version (Windows)
	{
		import core.sys.windows.windows : GetCurrentThreadId;
		return GetCurrentThreadId();
	}
	else
	version (linux)
	{
		return gettid();
	}
	else
	version (Posix)
	{
		import core.sys.posix.pthread : pthread_self;
		return cast(ulong)pthread_self();
	}
}

// ************************************************************************

private struct ProcessParams
{
	string shellCommand;
	string[] processArgs;

	string toShellCommand() { return shellCommand ? shellCommand :  escapeShellCommand(processArgs); }
	// Note: a portable toProcessArgs() cannot exist because CMD.EXE does not use CommandLineToArgvW.

	const(string[string]) environment = null;
	std.process.Config config = std.process.Config.none;
	size_t maxOutput = size_t.max;
	string workDir = null;
	File[3] files;
	size_t numFiles;

	this(Params...)(Params params)
	{
		files = [stdin, stdout, stderr];

		static foreach (i; 0 .. params.length)
		{{
			auto arg = params[i];
			static if (i == 0)
			{
				static if (is(typeof(arg) == string))
					shellCommand = arg;
				else
				static if (is(typeof(arg) == string[]))
					processArgs = arg;
				else
					static assert(false, "Unknown type for process invocation command line: " ~ typeof(arg).stringof);
				assert(arg, "Null command");
			}
			else
			{
				static if (is(typeof(arg) == string))
					workDir = arg;
				else
				static if (is(typeof(arg) : const(string[string])))
					environment = arg;
				else
				static if (is(typeof(arg) == size_t))
					maxOutput = arg;
				else
				static if (is(typeof(arg) == std.process.Config))
					config |= arg;
				else
				static if (is(typeof(arg) == File))
					files[numFiles++] = arg;
				else
					static assert(false, "Unknown type for process invocation parameter: " ~ typeof(arg).stringof);
			}
		}}
	}
}

private void invoke(alias runner)(string command)
{
	//debug scope(failure) std.stdio.writeln("[CWD] ", getcwd());
	debug(CMD) std.stdio.stderr.writeln("invoke: ", command);
	auto status = runner();
	enforce(status == 0,
		"Command `%s` failed with status %d".format(command, status));
}

/// std.process helper.
/// Run a command, and throw if it exited with a non-zero status.
void run(Params...)(Params params)
{
	auto parsed = ProcessParams(params);
	invoke!({
		auto pid = parsed.processArgs
			? spawnProcess(
				parsed.processArgs, parsed.files[0], parsed.files[1], parsed.files[2],
				parsed.environment, parsed.config, parsed.workDir
			)
			: spawnShell(
				parsed.shellCommand, parsed.files[0], parsed.files[1], parsed.files[2],
				parsed.environment, parsed.config, parsed.workDir
			);
		return pid.wait();
	})(parsed.toShellCommand());
}

/// std.process helper.
/// Run a command and collect its output.
/// Throw if it exited with a non-zero status.
string query(Params...)(Params params)
{
	auto parsed = ProcessParams(params, Config.stderrPassThrough);
	assert(parsed.numFiles == 0, "Can't specify files with query");
	string output;
	invoke!({
		auto result = parsed.processArgs
			? execute(parsed.processArgs, parsed.environment, parsed.config, parsed.maxOutput, parsed.workDir)
			: executeShell(parsed.shellCommand, parsed.environment, parsed.config, parsed.maxOutput, parsed.workDir);
		output = result.output.stripRight();
		return result.status;
	})(parsed.toShellCommand());
	return output;
}

/// std.process helper.
/// Run a command, feed it the given input, and collect its output.
/// Throw if it exited with non-zero status. Return output.
T[] pipe(T, Params...)(in T[] input, Params params)
if (!hasIndirections!T)
{
	auto parsed = ProcessParams(params);
	assert(parsed.numFiles == 0, "Can't specify files with pipe");
	T[] output;
	invoke!({
		auto pipes = parsed.processArgs
			? pipeProcess(parsed.processArgs, Redirect.stdin | Redirect.stdout,
				parsed.environment, parsed.config, parsed.workDir)
			: pipeShell(parsed.shellCommand, Redirect.stdin | Redirect.stdout,
				parsed.environment, parsed.config, parsed.workDir);
		auto f = pipes.stdin;
		auto writer = writeFileAsync(f, input);
		scope(exit) writer.join();
		output = cast(T[])readFile(pipes.stdout);
		return pipes.pid.wait();
	})(parsed.toShellCommand());
	return output;
}

TData!T pipe(T, Params...)(in TData!T input, Params params)
if (!hasIndirections!T)
{
	import ae.sys.dataio : readFileData;

	auto parsed = ProcessParams(params);
	assert(parsed.numFiles == 0, "Can't specify files with pipe");
	TData!T output;
	invoke!({
		auto pipes = parsed.processArgs
			? pipeProcess(parsed.processArgs, Redirect.stdin | Redirect.stdout,
				parsed.environment, parsed.config, parsed.workDir)
			: pipeShell(parsed.shellCommand, Redirect.stdin | Redirect.stdout,
				parsed.environment, parsed.config, parsed.workDir);
		auto f = pipes.stdin;
		auto writer = writeFileAsync(f, input.unsafeContents);
		scope(exit) writer.join();
		output = readFileData(pipes.stdout).asDataOf!T;
		return pipes.pid.wait();
	})(parsed.toShellCommand());
	return output;
}

deprecated T[] pipe(T, Params...)(string[] args, in T[] input, Params params)
if (!hasIndirections!T)
{
	return pipe(input, args, params);
}

debug(ae_unittest) unittest
{
	if (false) // Instantiation test
	{
		import ae.sys.data : Data;
		import ae.utils.array : asBytes;

		run("cat");
		run(["cat"]);
		query(["cat"]);
		query("cat | cat");
		pipe("hello", "rev");
		pipe(Data("hello".asBytes), "rev");
	}
}

// ************************************************************************

/// Wrapper for the `iconv` program.
ubyte[] iconv(const(ubyte)[] data, string inputEncoding, string outputEncoding)
{
	auto args = ["timeout", "30", "iconv", "-f", inputEncoding, "-t", outputEncoding];
	auto result = data.pipe(args);
	return cast(ubyte[])result;
}

/// ditto
string iconv(const(ubyte)[] data, string inputEncoding)
{
	import std.utf : validate;
	auto result = cast(string)iconv(data, inputEncoding, "UTF-8");
	validate(result);
	return result;
}

/// ditto
ubyte[] iconv(ascii data, string inputEncoding, string outputEncoding)
{
	return iconv(data.asBytes, inputEncoding, outputEncoding);
}

/// ditto
string iconv(ascii data, string inputEncoding)
{
	return iconv(data.asBytes, inputEncoding);
}

version (HAVE_UNIX)
debug(ae_unittest) unittest
{
	assert(iconv("Hello"w, "UTF-16LE") == "Hello");
}

/// Wrapper for the `sha1sum` program.
string sha1sum(const(ubyte)[] data)
{
	auto output = cast(string)data.pipe(["sha1sum", "-b", "-"]);
	return output[0..40];
}

version (HAVE_UNIX)
debug(ae_unittest) unittest
{
	assert(sha1sum("") == "da39a3ee5e6b4b0d3255bfef95601890afd80709");
	assert(sha1sum("a  b\nc\r\nd") == "667c71ffe2ac8a4fe500e3b96435417e4c5ec13b");
}

// ************************************************************************

import ae.utils.path;
deprecated alias NULL_FILE = nullFileName;

// ************************************************************************

/// Reverse of std.process.environment.toAA
void setEnvironment(string[string] env)
{
	foreach (k, v; env)
		if (k.length)
			environment[k] = v;
	foreach (k, v; environment.toAA())
		if (k.length && k !in env)
			environment.remove(k);
}

/// Expand Windows-like variable placeholders (`"%VAR%"`) in the given string.
string expandWindowsEnvVars(alias getenv = environment.get)(string s)
{
	import std.array : appender;
	auto buf = appender!string();

	size_t lastPercent = 0;
	bool inPercent = false;

	foreach (i, c; s)
		if (c == '%')
		{
			if (inPercent)
				buf.put(lastPercent == i ? "%" : getenv(s[lastPercent .. i]));
			else
				buf.put(s[lastPercent .. i]);
			inPercent = !inPercent;
			lastPercent = i + 1;
		}
	enforce(!inPercent, "Unterminated environment variable name");
	buf.put(s[lastPercent .. $]);
	return buf.data;
}

debug(ae_unittest) unittest
{
	std.process.environment[`FOOTEST`] = `bar`;
	assert("a%FOOTEST%b".expandWindowsEnvVars() == "abarb");
}

// ************************************************************************

/// Like `std.process.wait`, but with a timeout.
/// If the timeout is exceeded, the program is killed.
int waitTimeout(Pid pid, Duration time)
{
	bool ok = false;
	auto t = new Thread({
		Thread.sleep(time);
		if (!ok)
			try
				pid.kill();
			catch (Exception) {} // Ignore race condition
	}).start();
	scope(exit) t.join();

	auto result = pid.wait();
	ok = true;
	return result;
}

/// Wait for process to exit asynchronously.
/// Call callback when it exits.
/// WARNING: the callback will be invoked in another thread!
Thread waitAsync(Pid pid, void delegate(int) callback = null)
{
	return new Thread({
		auto result = pid.wait();
		if (callback)
			callback(result);
	}).start();
}
