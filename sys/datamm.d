/**
 * ae.sys.datamm
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

module ae.sys.datamm;

import core.stdc.errno;

import std.exception;
import std.mmfile;
import std.typecons;

debug(DATA_REFCOUNT) import std.stdio, core.stdc.stdio;

import ae.sys.data;

alias MmMode = MmFile.Mode; /// Convenience alias.

// ************************************************************************

/// `Memory` implementation encapsulating a memory-mapped file.
/// When the last reference is released, the file is unmapped.
class MappedMemory : Memory
{
	typeof(scoped!MmFile(null)) mmFile; /// The `MmFile` object.
	ubyte[] mappedData; /// View of the mapped file data.

	this(string name, MmMode mode, size_t from, size_t to)
	{
		mmFile = retryInterrupted({
			return scoped!MmFile(name, mode, 0, null);
		});
		mappedData = cast(ubyte[])(
			(from || to)
			? mmFile.Scoped_payload[from..(to ? to : mmFile.length)]
			: mmFile.Scoped_payload[]
		);

		debug(DATA_REFCOUNT) writefln("? -> %s [%s..%s]: Created MappedMemory", cast(void*)this, contents.ptr, contents.ptr + contents.length);
	} ///

	debug(DATA_REFCOUNT)
	~this() @nogc
	{
		printf("? -> %p: Deleted MappedMemory\n", cast(void*)this);
	}

	override @property inout(ubyte)[] contents() inout { return mappedData; } ///
	override @property size_t size() const { return mappedData.length; } ///
	override void setSize(size_t newSize) { assert(false, "Can't resize MappedMemory"); } ///
	override @property size_t capacity() const { return mappedData.length; } ///
}

/// Returns a `Data` viewing a mapped file.
Data mapFile(string name, MmMode mode, size_t from = 0, size_t to = 0)
{
	auto memory = unmanagedNew!MappedMemory(name, mode, from, to);
	return Data(memory);
}

private T retryInterrupted(T)(scope T delegate() dg)
{
	version (Posix)
	{
		while (true)
		{
			try
			{
				return dg();
			}
			catch (ErrnoException e)
			{
				if (e.errno == EINTR)
					continue;
				throw e;
			}
		}
	}
	else
		return dg();
}
