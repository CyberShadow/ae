/**
 * ImageMagick "convert" program wrapper
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

module ae.utils.graphics.im_convert;

import ae.sys.cmd;
import ae.sys.imagemagick;
import ae.utils.graphics.color;
import ae.utils.graphics.image;

/// Invoke ImageMagick's `convert` program to parse the given data.
auto parseViaIMConvert(COLOR)(const(void)[] data)
{
	string[] convertFlags;
	static if (is(COLOR : BGR))
	{
	//	convertFlags ~= ["-colorspace", "rgb"];
	//	convertFlags ~= ["-depth", "24"];
		convertFlags ~= ["-type", "TrueColor"];
		convertFlags ~= ["-alpha", "off"];
	}
	else
	static if (is(COLOR : BGRA))
	{
		convertFlags ~= ["-type", "TrueColorAlpha"];
		convertFlags ~= ["-alpha", "on"];
	}
	return pipe(["convert".imageMagickBinary()] ~ convertFlags ~ ["-[0]", "bmp:-"], data).viewBMP!COLOR();
}

/// ditto
auto parseViaIMConvert(C = TargetColor, TARGET)(const(void)[] data, auto ref TARGET target)
	if (isWritableView!TARGET && isTargetColor!(C, TARGET))
{
	return data.parseViaIMConvert!(ViewColor!TARGET)().copy(target);
}

unittest
{
	if (false)
	{
		void[] data;
		parseViaIMConvert!BGR(data);

		Image!BGR i;
		parseViaIMConvert!BGR(data, i);
	}
}
