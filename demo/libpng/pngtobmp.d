/**
 * ae.demo.libpng.pngtobmp
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

module ae.demo.libpng.pngtobmp;

import std.exception;
import std.file;
import std.path;

import ae.utils.funopt;
import ae.utils.graphics.color;
import ae.utils.graphics.image;
import ae.utils.graphics.libpng;
import ae.utils.main;
import ae.utils.meta;

void pngtobmp(bool strict, bool alpha, bool gray, bool rgb, string[] files)
{
	enforce(files.length, "No PNG files specified");

	void cv3(COLOR)()
	{
		static if (is(typeof(Image!COLOR.init.toBMP)))
		{
			foreach (fn; files)
			{
				auto i = decodePNG!COLOR(cast(ubyte[])read(fn), strict);
				write(fn.setExtension(".bmp"), i.toBMP);
			}
		}
		else
			throw new Exception("Invalid format options");
	}

	void cv1(string[] colorChannels)()
	{
		if (alpha)
			cv3!(Color!(ubyte, ArrayToTuple!(colorChannels ~ "a")))();
		else
			static if (colorChannels.length == 1)
				cv3!(Color!(ubyte, ArrayToTuple!(colorChannels ~ "x")))();
			else
				cv3!(Color!(ubyte, ArrayToTuple!colorChannels))();
	}

	if (gray)
	{
		enforce(!rgb, "--rgb meaningless with --gray");
		cv1!(["l"])();
	}
	else
	if (rgb)
		cv1!(["r", "g", "b"])();
	else
		cv1!(["b", "g", "r"])();
}

mixin main!(funopt!pngtobmp);
