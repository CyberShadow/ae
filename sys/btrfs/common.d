/**
 * BTRFS common declarations.
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

module ae.sys.btrfs.common;

version(linux):

package:
	
enum BTRFS_IOCTL_MAGIC = 0x94;

version (unittest)
{
	import ae.sys.file;
	import std.stdio : stderr;

	bool checkBtrfs(string moduleName = __MODULE__)()
	{
		auto fs = getPathFilesystem(".");
		if (fs != "btrfs")
		{
			stderr.writefln("Current filesystem is %s, not btrfs, skipping %s test.", fs, moduleName);
			return false;
		}
		return true;
	}
}