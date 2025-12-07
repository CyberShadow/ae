/**
 * Exception formatting
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

module ae.utils.exception;

import std.algorithm;
import std.string;

/// Stringify an exception chain.
string formatException(Throwable e)
{
	string[] descriptions;
	while (e)
		descriptions ~= e.toString(),
		e = e.next;
	return descriptions.join("\n===================================\n");
}

// --------------------------------------------------------------------------

import ae.utils.meta;

/// Mixin to declare a new exception type with the given name.
/// Automatically generates common constructors.
mixin template DeclareException(string NAME, BASE = Exception)
{
	import ae.utils.meta.x;

	mixin(mixin(X!q{
		class @(NAME) : BASE
		{
			this(string s, string fn = __FILE__, size_t ln = __LINE__)
			{
				super(s, fn, ln);
			}

			this(string s, Throwable next, string fn = __FILE__, size_t ln = __LINE__)
			{
				super(s, next, fn, ln);
			}
		}
	}));
}

debug(ae_unittest) unittest
{
	mixin DeclareException!q{OutOfCheeseException};
	try
		throw new OutOfCheeseException("*** OUT OF CHEESE ***");
	catch (Exception e)
		assert(e.classinfo.name.indexOf("Cheese") > 0);
}

// --------------------------------------------------------------------------

/// This exception can never be thrown.
/// Useful for a temporary or aliased catch block exception type.
class NoException : Exception
{
	@disable this()
	{
		super(null);
	} ///
}

/// Allows toggling catch blocks with -debug=NO_CATCH.
/// To use, catch `CaughtException` instead of `Exception` in catch blocks.
debug(NO_CATCH)
	alias CaughtException = NoException;
else
	alias CaughtException = Exception;

// --------------------------------------------------------------------------

import std.conv;

/// Returns string mixin for adding a chained exception
string exceptionContext(string messageExpr, string name = text(__LINE__))
{
	name = "exceptionContext_" ~ name;
	return mixin(X!q{
		bool @(name);
		scope(exit) if (@(name)) throw new Exception(@(messageExpr));
		scope(failure) @(name) = true;
	});
}

debug(ae_unittest) unittest
{
	try
	{
		mixin(exceptionContext(q{"Second"}));
		throw new Exception("First");
	}
	catch (Exception e)
	{
		assert(e.msg == "First");
		assert(e.next.msg == "Second");
	}
}

// --------------------------------------------------------------------------

/// Extracts the stack trace from an exception's `toString`, as an array of lines.
string[] getStackTrace(string until = __FUNCTION__, string since = "_d_run_main")
{
	string[] lines;
	try
		throw new Exception(null);
	catch (Exception e)
		lines = e.toString().splitLines()[1..$];

	auto start = lines.countUntil!(line => line.canFind(until));
	auto end   = lines.countUntil!(line => line.canFind(since));
	if (start < 0) start = -1;
	if (end   < 0) end   = lines.length;
	return lines[start+1..end];
}

/// Alias for the stack trace info type.
package(ae) alias TraceInfo = Throwable.TraceInfo;

// Get access to the trace context function from druntime
private extern (C) TraceInfo _d_traceContext(void* ptr = null) @nogc nothrow;

/// Captures the current stack trace.
/// This is cheaper than getStackTrace() because it defers symbol resolution
/// until the stack trace is actually printed.
/// Returns null if no trace handler is installed.
package(ae) TraceInfo captureStackTrace() @nogc nothrow
{
	return _d_traceContext();
}

/// Prints a captured stack trace to stderr.
/// Uses the same pattern as Throwable.toString() for printing.
package(ae) void printCapturedStackTrace(TraceInfo info)
{
	import core.stdc.stdio : stderr, fprintf, fwrite;

	if (info is null)
		return;

	try
	{
		fprintf(stderr, "----------------\n");
		foreach (line; info)
		{
			fwrite(line.ptr, 1, line.length, stderr);
			fprintf(stderr, "\n");
		}
	}
	catch (Throwable)
	{
		// Ignore errors during trace printing, same as Throwable.toString()
	}
}

// --------------------------------------------------------------------------

import core.exception;
import std.exception;

/// Test helper. Asserts that `a` `op` `b`, and includes the values in the error message.
template assertOp(string op)
{
	void assertOp(A, B)(auto ref A a, auto ref B b, string file=__FILE__, int line=__LINE__)
	{
		if (!(mixin("a " ~ op ~ " b")))
			throw new AssertError("Assertion failed: %s %s %s".format(a, op, b), file, line);
	}
}
alias assertEqual = assertOp!"=="; ///

debug(ae_unittest) unittest
{
	assertThrown!AssertError(assertEqual(1, 2));
}
