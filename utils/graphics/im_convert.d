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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.graphics.im_convert;

import ae.sys.cmd;
import ae.sys.imagemagick;
import ae.utils.graphics.image;

auto parseViaIMConvert(C = TargetColor, TARGET)(const(void)[] data, auto ref TARGET target)
	if (isWritableView!TARGET && isTargetColor!(C, TARGET))
{
	return pipe(["convert".imageMagickBinary(), "-", "bmp:-"], data).parseBMP(target);
}

auto parseViaIMConvert(COLOR)(const(void)[] data)
{
	Image!COLOR target;
	return data.parseViaIMConvert(target);
}
