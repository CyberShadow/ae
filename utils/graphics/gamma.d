/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2007-2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Gamma conversion.
module ae.utils.graphics.gamma;

import ae.utils.graphics.image;

enum ColorSpace { sRGB }

struct GammaRamp(LUM_COLOR, PIX_COLOR)
{
	LUM_COLOR[PIX_COLOR.max+1] pix2lum;
	PIX_COLOR[LUM_COLOR.max+1] lum2pix;

	this(double gamma)
	{
		foreach (pix; 0..PIX_COLOR.max+1)
			pix2lum[pix] = cast(LUM_COLOR)(pow(pix/cast(double)PIX_COLOR.max,   gamma)*LUM_COLOR.max);
		foreach (lum; 0..LUM_COLOR.max+1)
			lum2pix[lum] = cast(PIX_COLOR)(pow(lum/cast(double)LUM_COLOR.max, 1/gamma)*PIX_COLOR.max);
	}

	this(ColorSpace colorSpace)
	{
		final switch(colorSpace)
		{
			case ColorSpace.sRGB:
			{
				static double sRGB_to_linear(double cf)
				{
					if (cf <= 0.0392857)
						return cf / 12.9232102;
					else
						return pow((cf + 0.055)/1.055, 2.4L);
				}

				static double linear_to_sRGB(double cf)
				{
					if (cf <= 0.00303993)
						return cf * 12.9232102;
					else
						return 1.055*pow(cf, 1/2.4L) - 0.055;
				}

				foreach (pix; 0..PIX_COLOR.max+1)
					pix2lum[pix] = cast(LUM_COLOR)(sRGB_to_linear(pix/cast(double)PIX_COLOR.max)*LUM_COLOR.max);
				foreach (lum; 0..LUM_COLOR.max+1)
					lum2pix[lum] = cast(PIX_COLOR)(linear_to_sRGB(lum/cast(double)LUM_COLOR.max)*PIX_COLOR.max);
				break;
			}
		}
	}

	static string mixConvert(T)(string srcVar, string destVar, string convArray)
	{
		static if (is(T==struct))
		{
			string s;
			foreach (field; structFields!T)
				s ~= destVar~"."~field~" = "~convArray~"["~srcVar~"."~field~"];";
			return s;
		}
		else
			return destVar~" = "~convArray~"["~srcVar~"];";
	}

	auto pix2image(COLOR, COLOR2 = ReplaceType!(COLOR, PIX_COLOR, LUM_COLOR))(in Image!COLOR pixImage)
	{
		auto lumImage = Image!COLOR2(pixImage.w, pixImage.h);
		foreach (i, p; pixImage.pixels)
			mixin(mixConvert!COLOR(`p`, `lumImage.pixels[i]`, `pix2lum`));
		return lumImage;
	}

	auto image2pix(COLOR, COLOR2 = ReplaceType!(COLOR, LUM_COLOR, PIX_COLOR))(in Image!COLOR lumImage)
	{
		auto pixImage = Image!COLOR2(lumImage.w, lumImage.h);
		foreach (i, p; lumImage.pixels)
			mixin(mixConvert!COLOR(`p`, `pixImage.pixels[i]`, `lum2pix`));
		return pixImage;
	}
}
