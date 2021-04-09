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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.imagemagick;

/// Obtains the ImageMagick installation path from the Windows registry.
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

/// Returns a likely working program name for a given ImageMagick
/// program.
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
