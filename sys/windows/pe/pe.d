/**
 * Support for the Windows PE executable format.
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

module ae.sys.windows.pe.pe;

import std.exception;
import std.string;

import ae.sys.windows.imports;
mixin(importWin32!q{winnt});

struct PE
{
	ubyte[] data;

	PIMAGE_DOS_HEADER dosHeader;
	PIMAGE_NT_HEADERS ntHeaders;
	IMAGE_SECTION_HEADER[] sectionHeaders;
	IMAGE_DATA_DIRECTORY[] dataDirectories;

	this(void[] exe)
	{
		data = cast(ubyte[])exe;

		enforce(data.length > IMAGE_DOS_HEADER.sizeof, "Not enough data for DOS header");
		dosHeader = cast(PIMAGE_DOS_HEADER)data.ptr;
		enforce(dosHeader.e_magic == IMAGE_DOS_SIGNATURE, "Invalid DOS signature");

		enforce(data.length > dosHeader.e_lfanew + IMAGE_NT_HEADERS.sizeof, "Not enough data for NT headers");
		ntHeaders = cast(PIMAGE_NT_HEADERS)(data.ptr + dosHeader.e_lfanew);
		enforce(ntHeaders.Signature == IMAGE_NT_SIGNATURE, "Invalid NT signature");
		enforce(ntHeaders.FileHeader.Machine == IMAGE_FILE_MACHINE_I386, "Not an x86 PE");

		dataDirectories = ntHeaders.OptionalHeader.DataDirectory.ptr[0..ntHeaders.OptionalHeader.NumberOfRvaAndSizes];
		enforce(cast(ubyte*)(dataDirectories.ptr + dataDirectories.length) <= data.ptr + data.length, "Not enough data for data directories");

		auto sectionsStart = dosHeader.e_lfanew + ntHeaders.OptionalHeader.offsetof + ntHeaders.FileHeader.SizeOfOptionalHeader;
		auto sectionsEnd = sectionsStart + ntHeaders.FileHeader.NumberOfSections * IMAGE_SECTION_HEADER.sizeof;
		enforce(sectionsEnd <= data.length, "Not enough data for section headers");
		sectionHeaders = cast(IMAGE_SECTION_HEADER[])(data[sectionsStart .. sectionsEnd]);
	}

	/// Translate a file offset to the relative virtual address
	/// (address relative to the image base).
	size_t fileToRva(size_t offset)
	{
		foreach (ref section; sectionHeaders)
			if (offset >= section.PointerToRawData && offset < section.PointerToRawData + section.SizeOfRawData)
				return offset - section.PointerToRawData + section.VirtualAddress;
		throw new Exception("Unmapped file offset");
	}

	/// Reverse of fileToRva
	size_t rvaToFile(size_t offset)
	{
		foreach (ref section; sectionHeaders)
			if (offset >= section.VirtualAddress && offset < section.VirtualAddress + section.SizeOfRawData)
				return offset - section.VirtualAddress + section.PointerToRawData;
		throw new Exception("Unmapped memory address");
	}

	/// Translate a file offset to the corresponding virtual address
	/// (the in-memory image address at the default image base).
	size_t fileToImage(size_t offset)
	{
		return fileToRva(offset) + ntHeaders.OptionalHeader.ImageBase;
	}

	/// Reverse of fileToImage
	size_t imageToFile(size_t offset)
	{
		return rvaToFile(offset - ntHeaders.OptionalHeader.ImageBase);
	}

	/// Provide an array-like view of the in-memory layout.
	@property auto imageData()
	{
		static struct ImageData
		{
			PE* pe;

			ref ubyte opIndex(size_t offset)
			{
				return pe.data[pe.imageToFile(offset)];
			}

			ubyte[] opSlice(size_t start, size_t end)
			{
				return pe.data[pe.imageToFile(start) .. pe.imageToFile(end)];
			}

			T interpretAs(T)(size_t offset)
			{
				return *cast(T*)(pe.data.ptr + pe.imageToFile(offset));
			}
		}

		return ImageData(&this);
	}

	/// Get the image data for the given section header.
	ubyte[] sectionData(ref IMAGE_SECTION_HEADER section)
	{
		return data[section.PointerToRawData .. section.PointerToRawData + section.SizeOfRawData];
	}

	/// Get the image data for the given directory entry.
	ubyte[] directoryData(USHORT entry)
	{
		auto dir = ntHeaders.OptionalHeader.DataDirectory[entry];
		auto b = rvaToFile(dir.VirtualAddress);
		return data[b .. b + dir.Size];
	}
}

// UFCS helper
T interpretAs(T)(ubyte[] data, size_t offset)
{
	return *cast(T*)(data.ptr + offset);
}

/// Get the name of an IMAGE_SECTION_HEADER as a D string.
@property string name(ref IMAGE_SECTION_HEADER section)
{
	auto n = cast(char[])section.Name[];
	auto p = n.indexOf(0);
	return n[0 .. p<0 ? $ : p].idup;
}
