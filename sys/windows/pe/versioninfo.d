/**
 * Support for Windows PE VersionInfo resources.
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

module ae.sys.windows.pe.versioninfo;

import std.algorithm.searching;
import std.conv;
import std.exception;
import std.string;

/// Parses PE VersionInfo resources.
struct VersionInfoParser
{
	ubyte[] data; /// All data.

	this(void[] data)
	{
		enforce((cast(size_t)data.ptr) % 4 == 0, "Data must be DWORD-aligned");
		this.data = cast(ubyte[])data;
		root = readNode();
	} ///

	/// A `VersionInfo` node.
	struct Node
	{
		string key; ///
		bool isText; ///
		void[] value; ///
		Node[] children; ///

		/// Return the string contents of a text node.
		@property string valueText()
		{
			if (!value.length)
				return null;
			auto str = cast(wchar[])value;
			enforce(str.endsWith("\0"w), "Not null-terminated");
			return str[0..$-1].to!string;
		}
	}
	Node root; /// The root node.

private:
	Node readNode()
	{
		auto size = read!ushort() - ushort.sizeof;
		auto remainingData = data[size..$];
		scope(success) data = remainingData;
		data = data[0..size];

		auto valueLength = read!ushort();
		auto type = read!ushort();
		if (type)
			valueLength *= 2;

		wchar[] key;
		ubyte[] value;
		debug (verparse) scope(failure) stderr.writefln("wLength=%d wValueLength=%d remainder=%d wType=%d key=%(%s%) [error]", size, valueLength, data.length, type, [key]);
		if (valueLength < data.length && (cast(wchar[])data[0..$-valueLength]).indexOf('\0') < 0)
		{
			// Work around resource compiler bug
			debug (verparse) stderr.writeln("Resource compiler bug detected");
			valueLength += 2; // Make up for the lost null terminator
			auto wdata = cast(wchar[])data;
			while (wdata.length > 1 && wdata[$-1] == 0 && wdata[$-2] == 0)
				wdata = wdata[0..$-1];
			auto point = wdata.length - valueLength/wchar.sizeof;
			key = wdata[0..point];
			value = cast(ubyte[])wdata[point..$];
			data = null;
		}
		else
		{
			key = readWStringz();
			readAlign();
			if (valueLength > data.length)
				valueLength = data.length.to!ushort; // Work around Borland linker bug (madCHook.dll)
			value = readBytes(valueLength);
			readAlign();
		}

		debug (verparse)
		{
			stderr.writefln("wLength=%d wValueLength=%d remainder=%d wType=%d key=%(%s%)", size, valueLength, data.length, type, [key]);
			if (value.length)
				stderr.writeln(hexDump(value));
		}

		Node node;
		node.key = to!string(key);
		node.isText = type > 0;
		node.value = value;

		while (data.length)
		{
			node.children ~= readNode();
			readAlign();
		}

		return node;
	}

	T read(T)()
	{
		T value = *cast(T*)data.ptr;
		data = data[T.sizeof..$];
		return value;
	}

	wchar[] readWStringz()
	{
		auto start = cast(wchar*)data.ptr;
		size_t count = 0;
		while (read!wchar())
			count++;
		return start[0..count];
	}

	ubyte[] readBytes(size_t count)
	{
		scope(success) data = data[count..$];
		return data[0..count];
	}

	void readAlign()
	{
		while (data.length && (cast(size_t)data.ptr) % 4 != 0)
			read!ubyte();
	}
}

