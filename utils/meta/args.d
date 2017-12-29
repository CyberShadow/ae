/**
 * Named method and struct literal arguments
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

module ae.utils.meta.args;

import std.traits;

// Inspired by
// http://forum.dlang.org/post/awjuoemsnmxbfgzhgkgx@forum.dlang.org

/// Simulates named arguments for function calls.
/// Accepts arguments as lambdas (name => value) on the template parameter list,
/// and positional arguments on the runtime parameter list (see examples below).
template args(alias fun, dgs...)
if (is(typeof(fun) == function))
{
	auto args(PosArgs...)(auto ref PosArgs posArgs)
	{
		ParameterTypeTuple!fun args;
		enum names = ParameterIdentifierTuple!fun;

		foreach (i, ref arg; posArgs)
			args[i] = posArgs[i];
		foreach (i, arg; ParameterDefaults!fun)
			static if (i >= posArgs.length)
				args[i] = ParameterDefaults!fun[i];

		// anything works here, but use a custom type to avoid user errors
		static struct DummyType {}

		foreach (dg; dgs)
		{
			alias fun = dg!DummyType;
			static if (is(FunctionTypeOf!fun PT == __parameters))
			{
				enum name = __traits(identifier, PT);
				enum index = argIndex!names(name);
				static assert(index >= 0, "No such argument: " ~ name);
				args[index] = fun(DummyType.init);
			}
			else
				static assert(false, "Failed to extract parameter name from " ~ fun.stringof);
		}
		return fun(args);
	}
}

///
unittest
{
	static int fun(int a=1, int b=2, int c=3, int d=4, int e=5)
	{
		return a+b+c+d+e;
	}

	assert(args!(fun) == 15);
	assert(args!(fun, b=>3) == 16);
	assert(args!(fun, b=>3, d=>3) == 15);

	static assert(!is(typeof(args!(fun, b=>b)())));
	static assert(!is(typeof(args!(fun, x=>42)())));
}

/// Mixing named and positional arguments
unittest
{
	static int fun(int a, int b=2, int c=3, int d=4, int e=5)
	{
		return a+b+c+d+e;
	}

	assert(args!(fun)(1) == 15);
	assert(args!(fun, b=>3)(1) == 16);
}

/// Simulates named arguments for struct literals.
template args(S, dgs...)
if (is(S == struct))
{
	@property S args()
	{
		S s;

		// anything works here, but use a custom type to avoid user errors
		static struct DummyType {}

		foreach (dg; dgs)
		{
			alias fun = dg!DummyType;
			static if (is(FunctionTypeOf!fun PT == __parameters))
			{
				enum name = __traits(identifier, PT);
				enum index = fieldIndex!S(name);
				static assert(index >= 0, "No such field: " ~ name);
				s.tupleof[index] = fun(DummyType.init);
			}
			else
				static assert(false, "Failed to extract parameter name from " ~ fun.stringof);
		}
		return s;
	}
}

unittest
{
	static struct S
	{
		int a = 1, b = 2, c = 3, d = 4, e = 5;
		@property int sum() { return a + b + c + d + e; }
	}

	assert(args!(S).sum == 15);
	assert(args!(S, b=>3).sum == 16);
	assert(args!(S, b=>3, d=>3).sum == 15);

	static assert(!is(typeof(args!(S, b=>b))));
	static assert(!is(typeof(args!(S, x=>42))));
}

unittest
{
	struct S
	{
		union { int a, b; }
	}

	assert(args!(S, a => 1).a == 1);
	assert(args!(S, b => 1).a == 1);
}

private sizediff_t argIndex(names...)(string name)
{
	foreach (i, argName; names)
		if (name == argName)
			return i;
	return -1;
}

private sizediff_t fieldIndex(S)(string name)
{
	import ae.utils.meta : RangeTuple;

	foreach (i; RangeTuple!(S.tupleof.length))
		if (__traits(identifier, S.tupleof[i]) == name)
			return i;
	return -1;
}
