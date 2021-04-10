/**
 * Support for Windows PE resources.
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

module ae.sys.windows.pe.resources;

import std.conv;
import std.exception;

import ae.sys.windows.imports;
mixin(importWin32!q{winnt});

/// Parses Windows PE resources.
struct ResourceParser
{
	ubyte[] data; /// All data.
	uint rva; /// RVA of data.

	this(void[] data, uint rva)
	{
		this.data = cast(ubyte[])data;
		this.rva = rva;
		root = readDirectory(0);
	} ///

	/// Resource directory.
	struct Directory
	{
		/// Directory properties.
		uint characteristics, timestamp;
		/// ditto
		ushort majorVersion, minorVersion;
		/// Directory entries.
		DirectoryEntry[] entries;

		/// Find an entry by ID.
		ref DirectoryEntry opIndex(uint id)
		{
			foreach (ref entry; entries)
				if (entry.name is null && entry.id == id)
					return entry;
			throw new Exception("Can't find directory with this ID");
		}

		/// Find an entry by name.
		ref DirectoryEntry opIndex(string name)
		{
			foreach (ref entry; entries)
				if (entry.name !is null && entry.name == name)
					return entry;
			throw new Exception("Can't find directory with this name");
		}
	}
	Directory root; /// The root directory.

	/// An entry in a `Directory`.
	struct DirectoryEntry
	{
		string name; /// Entry name (if it is identified by a name).
		uint id; /// Entry ID (if it is identified by an ID).
		bool isDirectory; /// True if this entry is another directory.
		union Contents
		{
			Directory directory;
			DirectoryData data;
		}
		Contents contents;
		ref @property Directory directory() return { assert(isDirectory); return contents.directory; } /// Return the contents as a subdirectory.
		ref @property DirectoryData data() return { assert(!isDirectory); return contents.data; } /// Return the contents as data.
	}

	/// Data contents of a `DirectoryEntry` with `!isDirectory`.
	struct DirectoryData
	{
		uint codePage; ///
		void[] data;   ///
	}

	Directory readDirectory(uint offset)
	{
		enforce(offset + IMAGE_RESOURCE_DIRECTORY.sizeof <= data.length, "Out-of-bounds directory offset");
		auto winDir = cast(IMAGE_RESOURCE_DIRECTORY*)(data.ptr + offset);
		Directory dir;
		dir.characteristics = winDir.Characteristics;
		dir.timestamp = winDir.TimeDateStamp;
		dir.majorVersion = winDir.MajorVersion;
		dir.minorVersion = winDir.MinorVersion;
		dir.entries.length = winDir.NumberOfNamedEntries + winDir.NumberOfIdEntries;

		offset += IMAGE_RESOURCE_DIRECTORY.sizeof;
		enforce(offset + dir.entries.length * IMAGE_RESOURCE_DIRECTORY_ENTRY.sizeof <= data.length, "Not enough data for directory entries");
		auto winEntries = cast(IMAGE_RESOURCE_DIRECTORY_ENTRY*)(data.ptr + offset)[0..dir.entries.length];

		foreach (n; 0..dir.entries.length)
		{
			auto winEntry = &winEntries[n];
			auto entry = &dir.entries[n];

			if (winEntry.NameIsString)
				entry.name = readString(winEntry.NameOffset).to!string;
			else
				entry.id = winEntry.Id;

			entry.isDirectory = winEntry.DataIsDirectory;
			if (entry.isDirectory)
				entry.directory = readDirectory(winEntry.OffsetToDirectory);
			else
				entry.data = readDirectoryData(winEntry.OffsetToData);
		}

		return dir;
	}

	DirectoryData readDirectoryData(uint offset)
	{
		enforce(offset + IMAGE_RESOURCE_DATA_ENTRY.sizeof <= data.length, "Out-of-bounds directory data header offset");
		auto winDirData = cast(IMAGE_RESOURCE_DATA_ENTRY*)(data.ptr + offset);
		DirectoryData dirData;
		dirData.codePage = winDirData.CodePage;
		auto start = winDirData.OffsetToData - rva;
		enforce(start + winDirData.Size <= data.length, "Out-of-bounds directory data offset");
		dirData.data = data[start .. start + winDirData.Size];

		return dirData;
	}

	WCHAR[] readString(uint offset)
	{
		enforce(offset + typeof(IMAGE_RESOURCE_DIR_STRING_U.Length).sizeof <= data.length, "Out-of-bounds string offset");
		auto winStr = cast(IMAGE_RESOURCE_DIR_STRING_U*)(data.ptr + offset);
		offset += typeof(IMAGE_RESOURCE_DIR_STRING_U.Length).sizeof;
		enforce(offset + winStr.Length * WCHAR.sizeof <= data.length, "Out-of-bounds string offset");
		auto firstChar = &winStr._NameString;
		return firstChar[0..winStr.Length];
	}
}
