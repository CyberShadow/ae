/**
 * ae.sys.persistence.mapped
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

module ae.sys.persistence.mapped;

import std.file;
import std.mmfile;
import std.typecons;

/// Map a file onto a D type.
/// Experimental.

struct Mapped(T)
{
	this(string fn)
	{
		if (!fn.exists)
			std.file.write(fn, [T.init]);
		__mapped_file = __mapped_makeFile(fn);
	}

	private static auto __mapped_makeFile(string fn)
	{
		static if (is(typeof({T t = void; t = t;})))
			enum mode = MmFile.Mode.readWrite;
		else
			enum mode = MmFile.Mode.read;
		return scoped!MmFile(fn, mode, T.sizeof, null);
	}

	typeof(__mapped_makeFile(null)) __mapped_file;
	@disable this(this);

	@property ref T __mapped_data()
	{
		return *cast(T*)__mapped_file[].ptr;
	}
	alias __mapped_data this;
}

unittest
{
	static struct S
	{
		ubyte value;
	}

	enum fn = "test.bin";
	auto m = Mapped!S(fn);
	scope(exit) remove(fn);

	m.value = 1;
	assert(read(fn) == [ubyte(1)]);
	write(fn, [ubyte(2)]);
	assert(m.value == 2);
}
