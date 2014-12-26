/**
 * ImageMagick locator
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

module ae.sys.imagemagick;

version(Windows)
string imageMagickPath(string value = "BinPath")
{
	import std.windows.registry;
	return Registry
		.localMachine
		.getKey(`SOFTWARE\ImageMagick\Current`)
		.getValue(value)
		.value_SZ;
}

string imageMagickBinary(string program)
{
	version(Windows)
	{
		import std.path;
		return buildPath(imageMagickPath(), program ~ ".exe");
	}
	else
		return program;
}
