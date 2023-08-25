/**
 * Memory and GC stuff.
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

module ae.sys.memory;

import core.exception;
import core.memory;
import core.thread;

/// Did the GC run since this function's last call on this thread?
/// Not 100% reliable (due to false pointers).
bool gcRan()
{
	static bool initialized = false;
	static bool destroyed = false;

	static class Beacon
	{
		~this() @nogc
		{
			destroyed = true;
		}
	}

	if (!initialized)
	{
		destroyed = false;
		new Beacon();
		initialized = true;
	}

	bool result = destroyed;
	if (destroyed)
	{
		destroyed = false;
		new Beacon();
	}

	return result;
}

/// Is the given pointer located on the stack of the current thread?
/// Useful to assert on before taking the address of e.g. a struct member.
bool onStack(const(void)* p)
{
	auto p0 = thread_stackTop();
	auto p1 = thread_stackBottom();
	return p0 <= p && p <= p1;
}

unittest
{
	/* .......... */ int l; auto pl = &l;
	static /* ... */ int s; auto ps = &s;
	static __gshared int g; auto pg = &g;
	/* ................. */ auto ph = new int;
	assert( pl.onStack());
	assert(!ps.onStack());
	assert(!pg.onStack());
	assert(!ph.onStack());
}

private void callExtend()
{
	// Call GC.extend with dummy data.
	// It will normally exit silently if given a null pointer,
	// but not before the reentrance check.
	GC.extend(null, 0, 0, null);
}

/// Checks if we are inside a GC collection cycle.
/// This is currently done in a dumb and expensive way, so use sparingly.
bool inCollect() @nogc
{
	try
		(cast(void function() @nogc)&callExtend)();
	catch (InvalidMemoryOperationError)
		return true;
	return false;
}

unittest
{
	assert(!inCollect());

	class C
	{
		static bool tested;

		~this() @nogc
		{
			assert(inCollect());
			tested = true;
		}
	}

	foreach (n; 0..128)
		new C;
	GC.collect();
	assert(C.tested);
}
