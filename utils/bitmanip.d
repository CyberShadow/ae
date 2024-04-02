/**
 * Bit manipulation.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 *   Simon Arlott
 */

module ae.utils.bitmanip;

import std.bitmanip;
import std.traits;

/// Stores `T` in big-endian byte order.
struct BigEndian(T)
{
	private ubyte[T.sizeof] _endian_bytes;
	@property T _endian_value() const { return cast(T)bigEndianToNative!(OriginalType!T)(_endian_bytes); }
	@property void _endian_value(T value) { _endian_bytes = nativeToBigEndian(OriginalType!T(value)); }
	alias _endian_value this;
	alias opAssign = _endian_value; ///
	this(T value) { _endian_value(value); } ///
}

/// Stores `T` in little-endian byte order.
struct LittleEndian(T)
{
	private ubyte[T.sizeof] _endian_bytes;
	@property T _endian_value() const { return cast(T)littleEndianToNative!(OriginalType!T)(_endian_bytes); }
	@property void _endian_value(T value) { _endian_bytes = nativeToLittleEndian(OriginalType!T(value)); }
	alias _endian_value this;
	alias opAssign = _endian_value; ///
	this(T value) { _endian_value(value); } ///
}

alias NetworkByteOrder = BigEndian;

///
version(ae_unittest) unittest
{
	union U
	{
		BigEndian!ushort be;
		LittleEndian!ushort le;
		ubyte[2] bytes;
	}
	U u;

	u.be = 0x1234;
	assert(u.bytes == [0x12, 0x34]);

	u.le = 0x1234;
	assert(u.bytes == [0x34, 0x12]);

	u.bytes = [0x56, 0x78];
	assert(u.be == 0x5678);
	assert(u.le == 0x7856);
}

version(ae_unittest) unittest
{
	enum E : uint { e }
	BigEndian!E be;
}

version(ae_unittest) unittest
{
	const e = BigEndian!int(1);
	assert(e == 1);
}

// ----------------------------------------------------------------------------

/// Set consisting of members of the given enum.
/// Each unique enum member can be present or absent.
/// Accessing members can be done by name or with indexing.
struct EnumBitSet(E)
if (is(E == enum))
{
	private enum bits = size_t.sizeof * 8;
	private size_t[(cast(size_t)E.max + bits - 1) / bits] representation = 0;

	/// Construct an instance populated with a single member.
	this(E e)
	{
		this[e] = true;
	}

	/// Access by indexing (runtime value).
	bool opIndex(E e) const
	{
		return (representation[e / bits] >> (e % bits)) & 1;
	}

	/// ditto
	bool opIndexAssign(bool value, E e)
	{
		auto shift = e % bits;
		representation[e / bits] &= ~(1 << shift);
		representation[e / bits] |= value << shift;
		return value;
	}

	/// Access by name (compile-time value).
	template opDispatch(string name)
	if (__traits(hasMember, E, name))
	{
		enum E e = __traits(getMember, E, name);

		@property bool opDispatch() const
		{
			return (representation[e / bits] >> (e % bits)) & 1;
		}

		@property bool opDispatch(bool value)
		{
			auto shift = e % bits;
			representation[e / bits] &= ~(1 << shift);
			representation[e / bits] |= value << shift;
			return value;
		}
	}

	/// Enumeration of set members. Returns a range.
	auto opSlice()
	{
		alias set = this;

		struct R
		{
			size_t pos = 0;

			private void advance()
			{
				while (pos <= cast(size_t)E.max && !set[front])
					pos++;
			}

			@property E front() { return cast(E)pos; }

			bool empty() const { return pos > cast(size_t)E.max; }
			void popFront() { pos++; advance(); }
		}
		R r;
		r.advance();
		return r;
	}

	/// Filling / clearing.
	/// Caution: filling with `true` will also set members with no corresponding enum member,
	/// if the enum is not contiguous.
	void opSliceAssign(bool value)
	{
		representation[] = value ? 0xFF : 0x00;
	}

	/// Set operations.
	EnumBitSet opUnary(string op)() const
	if (op == "~")
	{
		EnumBitSet result = this;
		foreach (ref b; result.representation)
			b = ~b;
		return result;
	}

	EnumBitSet opBinary(string op)(auto ref const EnumBitSet b) const
	if (op == "|" || op == "&" || op == "^")
	{
		EnumBitSet result = this;
		mixin(q{result }~op~q{= b;});
		return result;
	}

	ref EnumBitSet opOpAssign(string op)(auto ref const EnumBitSet o)
	if (op == "|" || op == "&" || op == "^")
	{
		foreach (i; 0 .. representation.length)
			mixin(q{representation[i] }~op~q{= o.representation[i];});
		return this;
	}

	T opCast(T)() const
	if (is(T == bool))
	{
		return this !is typeof(this).init;
	}
}

version(ae_unittest) unittest
{
	import std.algorithm.comparison : equal;

	enum E { a, b, c }
	alias S = EnumBitSet!E;

	{
		S s;

		assert(!s[E.a]);
		s[E.a] = true;
		assert(s[E.a]);
		s[E.a] = false;
		assert(!s[E.a]);

		assert(!s.b);
		s.b = true;
		assert(s.b);
		s.b = false;
		assert(!s.b);

		assert(s[].empty);
		s.b = true;
		assert(equal(s[], [E.b]));
	}

	{
		auto a = S(E.a);
		auto c = S(E.c);
		a |= c;
		assert(a[].equal([E.a, E.c]));

		a[] = false;
		assert(a[].empty);
	}
}
