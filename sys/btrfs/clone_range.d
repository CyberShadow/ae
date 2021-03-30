/**
 * BTRFS_IOC_FILE_CLONE_RANGE.
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

module ae.sys.btrfs.clone_range;

version(linux):

import core.stdc.errno;
import core.sys.posix.sys.ioctl;

import std.exception;
import std.stdio : File;

import ae.sys.btrfs.common;

private:

enum BTRFS_IOC_FILE_CLONE_RANGE = _IOW!btrfs_ioctl_clone_range_args(BTRFS_IOCTL_MAGIC, 13);

struct btrfs_ioctl_clone_range_args
{
	long src_fd;
	ulong src_offset, src_length;
	ulong dest_offset;
}

public:

void cloneRange(
	ref const File srcFile, ulong srcOffset,
	ref const File dstFile, ulong dstOffset,
	ulong length)
{
	btrfs_ioctl_clone_range_args args;

	args.src_fd = srcFile.fileno;
	args.src_offset = srcOffset;
	args.src_length = length;
	args.dest_offset = dstOffset;

	int ret = ioctl(dstFile.fileno, BTRFS_IOC_FILE_CLONE_RANGE, &args);
	errnoEnforce(ret >= 0, "ioctl(BTRFS_IOC_FILE_CLONE_RANGE)");
}

unittest
{
	if (!checkBtrfs())
		return;
	import std.range, std.random, std.algorithm, std.file;
	enum blockSize = 16*1024; // TODO: detect
	auto data = blockSize.iota.map!(n => uniform!ubyte).array();
	std.file.write("test1.bin", data);
	scope(exit) remove("test1.bin");
	auto f1 = File("test1.bin", "rb");
	scope(exit) remove("test2.bin");
	auto f2 = File("test2.bin", "wb");
	cloneRange(f1, 0, f2, 0, blockSize);
	f2.close();
	f1.close();
	assert(std.file.read("test2.bin") == data);
}
