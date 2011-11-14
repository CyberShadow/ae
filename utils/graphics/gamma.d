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

import std.math;

import ae.utils.graphics.canvas;
import ae.utils.graphics.image;

enum ColorSpace { sRGB }

struct GammaRamp(LUM_BASETYPE, PIX_BASETYPE)
{
	LUM_BASETYPE[PIX_BASETYPE.max+1] pix2lumValues;
	PIX_BASETYPE[LUM_BASETYPE.max+1] lum2pixValues;

	this(double gamma)
	{
		foreach (pix; 0..PIX_BASETYPE.max+1)
			pix2lumValues[pix] = cast(LUM_BASETYPE)(pow(pix/cast(double)PIX_BASETYPE.max,   gamma)*LUM_BASETYPE.max);
		foreach (lum; 0..LUM_BASETYPE.max+1)
			lum2pixValues[lum] = cast(PIX_BASETYPE)(pow(lum/cast(double)LUM_BASETYPE.max, 1/gamma)*PIX_BASETYPE.max);
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

				foreach (pix; 0..PIX_BASETYPE.max+1)
					pix2lumValues[pix] = cast(LUM_BASETYPE)(sRGB_to_linear(pix/cast(double)PIX_BASETYPE.max)*LUM_BASETYPE.max);
				foreach (lum; 0..LUM_BASETYPE.max+1)
					lum2pixValues[lum] = cast(PIX_BASETYPE)(linear_to_sRGB(lum/cast(double)LUM_BASETYPE.max)*PIX_BASETYPE.max);
				break;
			}
		}
	}

	// TODO: compute destination color type automatically (ReplaceType doesn't handle methods)

	/*PIX_BASETYPE lum2pix()(LUM_BASETYPE c)
	{
		return PIX_BASETYPE.op!q{b[a]}(c, lum2pixValues[]);
	}*/

	void lum2pix(SRCCANVAS, DSTCANVAS)(ref SRCCANVAS src, ref DSTCANVAS dst)
		if (IsCanvas!SRCCANVAS && IsCanvas!DSTCANVAS && is(SRCCANVAS.COLOR.BaseType==LUM_BASETYPE) && is(DSTCANVAS.COLOR.BaseType==PIX_BASETYPE))
	{
		dst.transformDraw!q{
			COLOR.op!q{
				b[a]
			}(c, extraArgs[0])
		}(src, 0, 0, lum2pixValues[]);
	}

	auto lum2pix(DSTCOLOR, SRCCANVAS)(ref SRCCANVAS src)
		if (IsCanvas!SRCCANVAS && is(SRCCANVAS.COLOR.BaseType==LUM_BASETYPE))
	{
		Image!DSTCOLOR dst;
		dst.size(src.w, src.h);
		lum2pix(src, dst);
		return dst;
	}

	LUM_COLOR pix2lum(LUM_COLOR, PIX_COLOR)(PIX_COLOR c)
	{
		return LUM_COLOR.op!q{b[a]}(c, pix2lumValues[]);
	}

	/*static string mixConvert(T)(string srcVar, string destVar, string convArray)
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

	auto pix2image(COLOR, COLOR2 = ReplaceType!(COLOR, PIX_BASETYPE, LUM_BASETYPE))(in Image!COLOR pixImage)
	{
		auto lumImage = Image!COLOR2(pixImage.w, pixImage.h);
		foreach (i, p; pixImage.pixels)
			mixin(mixConvert!COLOR(`p`, `lumImage.pixels[i]`, `pix2lumValues`));
		return lumImage;
	}

	auto image2pix(COLOR, COLOR2 = ReplaceType!(COLOR, LUM_BASETYPE, PIX_BASETYPE))(in Image!COLOR lumImage)
	{
		auto pixImage = Image!COLOR2(lumImage.w, lumImage.h);
		foreach (i, p; lumImage.pixels)
			mixin(mixConvert!COLOR(`p`, `pixImage.pixels[i]`, `lum2pixValues`));
		return pixImage;
	}*/
}
