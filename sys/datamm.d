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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.sys.datamm;

import std.mmfile;
debug import std.stdio;

import ae.sys.data;

alias MmMode = MmFile.Mode;

// ************************************************************************

class MappedDataWrapper : DataWrapper
{
	MmFile mmFile;
	void[] mappedData;

	debug(DATA_REFCOUNT)
	this()
	{
		writefln("? -> %s: Created MappedDataWrapper", cast(void*)this);
	}

	override @property inout(void)[] contents() inout { return mappedData; }
	override @property size_t size() const { return mappedData.length; }
	override void setSize(size_t newSize) { assert(false, "Can't resize MappedDataWrapper"); }
	override @property size_t capacity() const { return mappedData.length; }
}

auto mapFile(string name, MmMode mode, size_t from = 0, size_t to = 0)
{
	auto wrapper = new MappedDataWrapper;
	wrapper.mmFile = new MmFile(name, mode, 0, null);
	wrapper.mappedData = (from || to) ? wrapper.mmFile[from..(to ? to : wrapper.mmFile.length)] : wrapper.mmFile[];
	return Data(wrapper, mode != MmMode.read);
}
