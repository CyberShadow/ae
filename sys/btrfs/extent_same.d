/**
 * BTRFS_IOC_FILE_EXTENT_SAME.
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

module ae.sys.btrfs.extent_same;

version(linux):

import core.stdc.errno;
import core.sys.posix.sys.ioctl;

import std.conv : to;
import std.exception;
import std.stdio : File;
import std.string : format;

import ae.sys.btrfs.common;

private:

enum BTRFS_IOC_FILE_EXTENT_SAME = _IOWR!btrfs_ioctl_same_args(BTRFS_IOCTL_MAGIC, 54);

enum BTRFS_SAME_DATA_DIFFERS = 1;

/* For extent-same ioctl */
struct btrfs_ioctl_same_extent_info
{
	long fd;						/* in - destination file */
	ulong logical_offset;			/* in - start of extent in destination */
	ulong bytes_deduped;			/* out - total # of bytes we
									 * were able to dedupe from
									 * this file */
	/* status of this dedupe operation:
	 * 0 if dedup succeeds
	 * < 0 for error
	 * == BTRFS_SAME_DATA_DIFFERS if data differs
	 */
	int status;						/* out - see above description */
	uint reserved;
}

struct btrfs_ioctl_same_args
{
	ulong logical_offset;		/* in - start of extent in source */
	ulong length;				/* in - length of extent */
	ushort dest_count;			/* in - total elements in info array */
								/* out - number of files that got deduped */
	ushort reserved1;
	uint reserved2;
	btrfs_ioctl_same_extent_info[0] info;
}

public:

/// Submit a `BTRFS_IOC_FILE_EXTENT_SAME` ioctl.
struct Extent
{
	/// File containing the extent to deduplicate.
	/// May occur more than once in `extents`.
	File file;

	/// The offset within the file of the extent, in bytes.
	ulong offset;
}

struct SameExtentResult
{
	/// Sum of returned `bytes_deduped`.
	ulong totalBytesDeduped;
} /// ditto

SameExtentResult sameExtent(in Extent[] extents, ulong length)
{
	assert(extents.length >= 2, "Need at least 2 extents to deduplicate");

	auto buf = new ubyte[
		      btrfs_ioctl_same_args.sizeof +
		      btrfs_ioctl_same_extent_info.sizeof * extents.length];
	auto same = cast(btrfs_ioctl_same_args*) buf.ptr;

	same.length = length;
	same.logical_offset = extents[0].offset;
	same.dest_count = (extents.length - 1).to!ushort;

	foreach (i, ref extent; extents[1..$])
	{
		same.info.ptr[i].fd = extent.file.fileno;
		same.info.ptr[i].logical_offset = extent.offset;
		same.info.ptr[i].status = -1;
	}

	int ret = ioctl(extents[0].file.fileno, BTRFS_IOC_FILE_EXTENT_SAME, same);
	errnoEnforce(ret >= 0, "ioctl(BTRFS_IOC_FILE_EXTENT_SAME)");

	SameExtentResult result;

	foreach (i, ref extent; extents[1..$])
	{
		auto status = same.info.ptr[i].status;
		if (status)
		{
			enforce(status != BTRFS_SAME_DATA_DIFFERS,
				"Extent #%d differs".format(i+1));
			errno = -status;
			errnoEnforce(false,
				"Deduplicating extent #%d returned status %d".format(i+1, status));
		}
		result.totalBytesDeduped += same.info.ptr[i].bytes_deduped;
	}

	return result;
} /// ditto

debug(ae_unittest) unittest
{
	if (!checkBtrfs())
		return;
	import std.range, std.random, std.algorithm, std.file;
	enum blockSize = 16*1024; // TODO: detect
	auto data = blockSize.iota.map!(n => uniform!ubyte).array();
	std.file.write("test1.bin", data);
	scope(exit) remove("test1.bin");
	std.file.write("test2.bin", data);
	scope(exit) remove("test2.bin");

	sameExtent([
		Extent(File("test1.bin", "r+b"), 0),
		Extent(File("test2.bin", "r+b"), 0),
	], blockSize);

	data[0]++;
	std.file.write("test2.bin", data);
	assertThrown!Exception(sameExtent([
		Extent(File("test1.bin", "r+b"), 0),
		Extent(File("test2.bin", "r+b"), 0),
	], blockSize));
}
