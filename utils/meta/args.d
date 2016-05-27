/**
 * Named method arguments
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

		foreach (dg; dgs)
		{
			alias DummyType = int; // anything goes
			alias fun = dg!DummyType;
			static if (is(FunctionTypeOf!fun PT == __parameters))
			{
				enum name = __traits(identifier, PT);
				foreach (i, argName; names)
					if (name == argName)
						args[i] = fun(DummyType.init);
			}
			else
				static assert(false, "Failed to extract parameter name from " ~ fun.stringof);
		}
		return fun(args);
	}
}

unittest
{
	static int fun(int a=1, int b=2, int c=3, int d=4, int e=5)
	{
		return a+b+c+d+e;
	}

	assert(args!(fun) == 15);
	assert(args!(fun, b=>3) == 16);
	assert(args!(fun, b=>3, d=>3) == 15);
}

unittest
{
	static int fun(int a, int b=2, int c=3, int d=4, int e=5)
	{
		return a+b+c+d+e;
	}

	assert(args!(fun)(1) == 15);
	assert(args!(fun, b=>3)(1) == 16);
}
