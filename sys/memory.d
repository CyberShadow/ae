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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.memory;

/// Did the GC run since this function's last call on this thread?
/// Not 100% reliable (due to false pointers).
bool gcRan()
{
	static bool initialized = false;
	static bool destroyed = false;

	static class Beacon
	{
		~this()
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

import core.thread;

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
