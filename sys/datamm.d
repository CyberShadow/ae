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

import std.mmfile;
import std.typecons;
debug import std.stdio;

import ae.sys.data;

alias MmMode = MmFile.Mode; /// Convenience alias.

// ************************************************************************

/// `DataWrapper` implementation encapsulating a memory-mapped file.
/// When the last reference is released, the file is unmapped.
class MappedDataWrapper : DataWrapper
{
	typeof(scoped!MmFile(null)) mmFile; /// The `MmFile` object.
	void[] mappedData; /// View of the mapped file data.

	this(string name, MmMode mode, size_t from, size_t to)
	{
		mmFile = scoped!MmFile(name, mode, 0, null);
		mappedData = (from || to) ? mmFile.Scoped_payload[from..(to ? to : mmFile.length)] : mmFile.Scoped_payload[];

		debug(DATA_REFCOUNT) writefln("? -> %s [%s..%s]: Created MappedDataWrapper", cast(void*)this, contents.ptr, contents.ptr + contents.length);
	} ///

	debug(DATA_REFCOUNT)
	~this()
	{
		writefln("? -> %s: Deleted MappedDataWrapper", cast(void*)this);
	}

	override @property inout(void)[] contents() inout { return mappedData; } ///
	override @property size_t size() const { return mappedData.length; } ///
	override void setSize(size_t newSize) { assert(false, "Can't resize MappedDataWrapper"); } ///
	override @property size_t capacity() const { return mappedData.length; } ///
}

/// Returns a `Data` viewing a mapped file.
auto mapFile(string name, MmMode mode, size_t from = 0, size_t to = 0)
{
	auto wrapper = unmanagedNew!MappedDataWrapper(name, mode, from, to);
	return Data(wrapper, mode != MmMode.read);
}
