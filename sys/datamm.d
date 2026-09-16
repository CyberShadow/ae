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
import core.stdc.stdlib : free, malloc;

import std.exception;
import std.mmfile;
import std.typecons;

debug(DATA_REFCOUNT) import std.stdio, core.stdc.stdio;

import ae.sys.data;

alias MmMode = MmFile.Mode; /// Convenience alias.

// ************************************************************************

/// What to do with the file's page cache when the mapping is released.
///
/// Reading a file through a mapping fills the OS page cache, and nothing
/// evicts it afterwards except memory pressure. For a program which walks
/// over many files once, that cache is pure cost: it evicts other
/// processes' memory (on Linux, by pushing their anonymous pages to swap)
/// to retain data which will never be read again.
enum MmCacheHint
{
	/// Leave it to the OS. The default, and the only portable behavior.
	keep,

	/// Keep the data cached, but mark it as the first thing to evict.
	/// Costs nothing if the file is read again soon.
	/// Linux only (`MADV_COLD`); a no-op elsewhere.
	cold,

	/// Evict the data immediately: this file will not be read again.
	/// Implemented on Linux (`MADV_PAGEOUT`) and Windows (see below).
	drop,
}

version (linux)
{
	// Linux 5.4+. Absent from druntime's core.sys.linux.sys.mman as of 2.110.
	private enum MADV_COLD = 20, MADV_PAGEOUT = 21;
	private extern(C) int madvise(void*, size_t, int) @nogc nothrow;
}
else
version (Windows)
{
	import core.sys.windows.winbase;
	import core.sys.windows.winnt;

	/// Convert to a NUL-terminated UTF-16 string in `malloc`ed memory.
	/// `MappedMemory` is allocated with `unmanagedNew`, which the GC does
	/// not scan, so it cannot hold a GC-allocated string.
	private wchar* toUnmanagedWStringz(string s)
	{
		import std.utf : byUTF;
		size_t length = 0;
		foreach (wchar c; s.byUTF!wchar)
			length++;
		auto result = cast(wchar*)malloc((length + 1) * wchar.sizeof);
		size_t i = 0;
		foreach (wchar c; s.byUTF!wchar)
			result[i++] = c;
		result[length] = 0;
		return result;
	}
}

// ************************************************************************

/// `Memory` implementation encapsulating a memory-mapped file.
/// When the last reference is released, the file is unmapped.
class MappedMemory : Memory
{
	MmFile mmFile; /// The `MmFile` object.
	ubyte[] mappedData; /// View of the mapped file data.

	private MmCacheHint hint;
	/// The entire mapping, of which `mappedData` may be a sub-range.
	/// `madvise` requires a page-aligned start address, which a
	/// `[from..to]` slice is not guaranteed to have.
	private ubyte[] wholeMapping;
	version (Windows) private wchar* fileNameW;

	this(string name, MmMode mode, size_t from, size_t to, MmCacheHint hint)
	{
		mmFile = retryInterrupted({
			return unmanagedNew!MmFile(name, mode, 0uL, null);
		});
		wholeMapping = cast(ubyte[])mmFile[];
		mappedData = (from || to)
			? wholeMapping[from..(to ? to : wholeMapping.length)]
			: wholeMapping;
		this.hint = hint;
		version (Windows)
		if (hint == MmCacheHint.drop)
			fileNameW = toUnmanagedWStringz(name);

		debug(DATA_REFCOUNT) writefln("? -> %s [%s..%s]: Created MappedMemory", cast(void*)this, contents.ptr, contents.ptr + contents.length);
	} ///

	~this() @nogc
	{
		debug(DATA_REFCOUNT) printf("? -> %p: Deleted MappedMemory\n", cast(void*)this);

		// The two platforms want the hint applied on opposite sides of the
		// unmap: `madvise` needs a live mapping, while Windows' only way to
		// evict a file from the system cache (opening it unbuffered) is a
		// silent no-op while any view of it is mapped. Hence the explicit
		// `mmFile` lifetime, instead of letting a field destructor run last.

		version (linux)
		if (hint != MmCacheHint.keep && wholeMapping.length)
			madvise(wholeMapping.ptr, wholeMapping.length,
				hint == MmCacheHint.drop ? MADV_PAGEOUT : MADV_COLD);

		unmanagedDelete(mmFile);

		version (Windows)
		if (hint == MmCacheHint.drop)
		{
			// Cached and unbuffered I/O cannot coexist coherently, so this
			// makes the cache manager purge the file. There is no documented
			// API for this, and no equivalent of MADV_COLD.
			auto h = CreateFileW(fileNameW, GENERIC_READ,
				FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
				null, OPEN_EXISTING,
				FILE_ATTRIBUTE_NORMAL | FILE_FLAG_NO_BUFFERING, null);
			if (h != INVALID_HANDLE_VALUE)
				CloseHandle(h);
			free(fileNameW);
		}
	}

	override @property inout(ubyte)[] contents() inout { return mappedData; } ///
	override @property size_t size() const { return mappedData.length; } ///
	override void setSize(size_t newSize) { assert(false, "Can't resize MappedMemory"); } ///
	override @property size_t capacity() const { return mappedData.length; } ///
}

/// Returns a `Data` viewing a mapped file.
Data mapFile(string name, MmMode mode, size_t from = 0, size_t to = 0, MmCacheHint hint = MmCacheHint.keep)
{
	auto memory = unmanagedNew!MappedMemory(name, mode, from, to, hint);
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
