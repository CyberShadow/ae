/**
 * Implements a multicast delegate type for registering event
 * handlers (essentially, linked list of delegates).
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

module ae.utils.event;

import std.traits : ReturnType, ParameterTypeTuple;

/// Multicast delegate, holding a list of D void delegates.
/// Optimized for zero or one delegate.
struct Event(Dg)
if (is(Dg == delegate) && is(ReturnType!Dg == void))
{
private:
	// Note: we accept the argument list by using the entire delegate
	// as the template argument type, as we can't otherwile define
	// callbacks with e.g. ref arguments.
	Dg dg;
	typeof(this)* next;

public:
	/// Register a new delegate.
	alias add = opOpAssign!"~";

	// Alternative syntax to register a delegate.
	// Does not require parens.
	void opOpAssign(string op : "~")(Dg dg)
	{
		assert(dg, "Attempting to register a null event handler");
		if (!this.dg)
			this.dg = dg;
		else
		{
			// Append to the end of the chain, so that we call
			// delegates in registration order.
			auto p = &this;
			while (p.next)
				p = p.next;
			p.next = new typeof(this);
			p.next.dg = dg;
		}
	} /// ditto

	/// Unregister a previously-registered delegate.
	void remove(Dg dg)
	{
		assert(dg, "Attempting to unregister a null event handler");
		if (this.dg is dg)
		{
			this.dg = null;
			if (this.next)
				this = *this.next;
		}
		else
		{
			for (auto pp = &this.next; *pp; pp = &(*pp).next)
				if ((*pp).dg is dg)
				{
					*pp = (*pp).next;
					return;
				}
			assert(false, "Attempting to unregister an event handler which was not registered");
		}
	}

	/// Call `add` or `remove`.  Interface for `VirtualEvent`.
	void addRemove(Dg dg, bool add) { if (add) this.add(dg); else this.remove(dg); }

	void clear()
	{
		dg = null;
		next = null;
	}

	void call()(auto ref ParameterTypeTuple!Dg args)
	{
		if (this.dg)
			for (auto p = &this; p; p = p.next)
				p.dg(args);
	}
	alias opCall = call;

	bool opCast(T : bool)() const
	{
		return !!this.dg;
	}

	@property size_t length() const
	{
		if (!dg)
			return 0;
		size_t result = 0;
		for (auto p = &this; p; p = p.next)
			result++;
		return result;
	}

	/// Backward compatibility with a single delegate.
	deprecated void opAssign(Dg dg)
	{
		assert(!this.next, "Clobbering multiple handlers");
		this.dg = dg;
	}

	/// ditto
	deprecated void opAssign(typeof(null))
	{
		clear();
	}

	deprecated @property Dg _get() { return this.dg; } /// ditto
	deprecated alias _get this; /// ditto

	/// Range primitives.  Note: `popFront` mutates the current value.
	@property bool empty() const { return dg is null; }
	@property Dg front() { return dg; } /// ditto
	void popFront() { assert(dg); if (next) this = *next; else dg = null; } /// ditto
}

unittest
{
	int[] buf;
	Event!(void delegate()) e;
	int[] callAll()
	{
		buf = null;
		e();
		return buf;
	}
	void add(int n)() { buf ~= n; }

	e ~= &add!1;
	e ~= &add!2;
	e ~= &add!3;
	assert(e.length == 3);
	assert(callAll() == [1, 2, 3]);

	e.remove(&add!2);
	assert(callAll() == [1, 3]);

	e.remove(&add!3);
	assert(callAll() == [1]);
	assert(e.length == 1);

	e.remove(&add!1);
	assert(callAll() == []);
	assert(e.length == 0);
}

// ****************************************************************************

/// Mixes in a member which provides an interface similar to Event,
/// but dispatches actual [un]registration to the methods named
/// addRemove{name}Handler in the current aggregate.
/// Following convention, the mixed-in member is named handle{name}.
mixin template VirtualEvent(string name)
{
	final @property auto _virtualEventImpl()
	{
		static if (is(typeof(this) == struct))
			auto self = &this;
		else
			auto self = this;

		import std.traits : ParameterTypeTuple;
		mixin(`alias Dg = ParameterTypeTuple!(addRemove` ~ name ~ `Handler)[0];`);

		static struct VEvent
		{
			typeof(self) p;

			debug bool used; // Debug trap / workaround for https://issues.dlang.org/show_bug.cgi?id=22769 ; can be replaced with @mustuse
			@disable this(this);
			debug ~this() { assert(used, "VirtualEvent accessed but not used (attempt to call VirtualEvent instead of Event?)"); }

			alias add = opOpAssign!"~";

			void opOpAssign(string op : "~")(Dg dg)
			{
				debug used = true;
				assert(dg, "Attempting to register a null event handler");
				mixin(`p.addRemove` ~ name ~ `Handler(dg, true);`);
			}

			void remove(Dg dg)
			{
				debug used = true;
				assert(dg, "Attempting to unregister a null event handler");
				mixin(`p.addRemove` ~ name ~ `Handler(dg, false);`);
			}

			// Allow chaining VirtualEvents
			void addRemove(Dg dg, bool add) { if (add) this.add(dg); else this.remove(dg); }

			deprecated alias opAssign = add;
		}

		VEvent v;
		v.p = self;
		return v;
	}

	/// Compatibility setter shim
	deprecated final @property void _virtualEventImpl(typeof({
		import std.traits : ParameterTypeTuple;
		mixin(`alias Dg = ParameterTypeTuple!(addRemove` ~ name ~ `Handler)[0];`);
		return Dg.init;
	}()) dg)
	{
		assert(dg, "Unsetting handler via VirtualEvent opAssign not supported, use .remove");
		mixin(`addRemove` ~ name ~ `Handler(dg, true);`);
	}

	mixin(`alias handle` ~ name ~ ` = _virtualEventImpl;`);
}

unittest
{
	interface I
	{
		protected void addRemoveFooHandler(void delegate(), bool);
		mixin VirtualEvent!(q{Foo});
	}
}
