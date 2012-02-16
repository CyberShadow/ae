/**
 * Gamma conversion.
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
		}(0, 0, src, lum2pixValues[]);
	}

	auto lum2pix(DSTCOLOR, SRCCANVAS)(ref SRCCANVAS src)
		if (IsCanvas!SRCCANVAS && is(SRCCANVAS.COLOR.BaseType==LUM_BASETYPE))
	{
		Image!DSTCOLOR dst;
		dst.size(src.w, src.h);
		lum2pix(src, dst);
		return dst;
	}

	void pix2lum(SRCCANVAS, DSTCANVAS)(ref SRCCANVAS src, ref DSTCANVAS dst)
		if (IsCanvas!SRCCANVAS && IsCanvas!DSTCANVAS && is(SRCCANVAS.COLOR.BaseType==PIX_BASETYPE) && is(DSTCANVAS.COLOR.BaseType==LUM_BASETYPE))
	{
		dst.transformDraw!q{
			COLOR.op!q{
				b[a]
			}(c, extraArgs[0])
		}(0, 0, src, pix2lumValues[]);
	}

	auto pix2lum(DSTCOLOR, SRCCANVAS)(ref SRCCANVAS src)
		if (IsCanvas!SRCCANVAS && is(SRCCANVAS.COLOR.BaseType==PIX_BASETYPE))
	{
		Image!DSTCOLOR dst;
		dst.size(src.w, src.h);
		pix2lum(src, dst);
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

unittest
{
	// test instantiation
	auto gamma = GammaRamp!(ushort, ubyte)(ColorSpace.sRGB);
	auto image = Image!RGB16(1, 1);
	auto image2 = gamma.lum2pix!RGB(image);
}
