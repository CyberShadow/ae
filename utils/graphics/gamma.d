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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.graphics.gamma;

import std.math;

import ae.utils.graphics.color;
import ae.utils.graphics.view;

/// Predefined colorspaces.
enum ColorSpace
{
	sRGB, /// https://en.wikipedia.org/wiki/SRGB
}

/// Contains a gamma ramp.
/// LUM_BASETYPE and PIX_BASETYPE should be numeric types indicating
/// the channel type for the colors that will be converted.
struct GammaRamp(LUM_BASETYPE, PIX_BASETYPE)
{
	LUM_BASETYPE[PIX_BASETYPE.max+1] pix2lumValues; /// Calculated gamma ramp table.
	PIX_BASETYPE[LUM_BASETYPE.max+1] lum2pixValues; /// ditto

	/// Create a GammaRamp with the given gamma value.
	this(double gamma)
	{
		foreach (pix; 0..PIX_BASETYPE.max+1)
			pix2lumValues[pix] = cast(LUM_BASETYPE)(pow(pix/cast(double)PIX_BASETYPE.max,   gamma)*LUM_BASETYPE.max);
		foreach (lum; 0..LUM_BASETYPE.max+1)
			lum2pixValues[lum] = cast(PIX_BASETYPE)(pow(lum/cast(double)LUM_BASETYPE.max, 1/gamma)*PIX_BASETYPE.max);
	}

	/// Create a GammaRamp with the given colorspace.
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

	/// Convert pixel value to linear luminosity.
	auto pix2lum(PIXCOLOR)(PIXCOLOR c) const
	{
		alias LUMCOLOR = ChangeChannelType!(PIXCOLOR, LUM_BASETYPE);
		return LUMCOLOR.op!q{b[a]}(c, pix2lumValues[]);
	}

	/// Convert linear luminosity to pixel value.
	auto lum2pix(LUMCOLOR)(LUMCOLOR c) const
	{
		alias PIXCOLOR = ChangeChannelType!(LUMCOLOR, PIX_BASETYPE);
		return PIXCOLOR.op!q{b[a]}(c, lum2pixValues[]);
	}
}

/// Return a view which converts luminosity to image pixel data
/// using the specified gamma ramp
auto lum2pix(SRC, GAMMA)(auto ref SRC src, auto ref GAMMA gamma)
	if (isView!SRC)
{
	auto g = &gamma;
	return src.colorMap!(c => g.lum2pix(c));
}

/// Return a view which converts image pixel data to luminosity
/// using the specified gamma ramp
auto pix2lum(SRC, GAMMA)(auto ref SRC src, auto ref GAMMA gamma)
	if (isView!SRC)
{
	auto g = &gamma;
	return src.colorMap!(c => g.pix2lum(c));
}

/// Return a reference to a statically-initialized GammaRamp
/// with the indicated parameters
ref auto gammaRamp(LUM_BASETYPE, PIX_BASETYPE, alias value)()
{
	alias Ramp = GammaRamp!(LUM_BASETYPE, PIX_BASETYPE);
	static struct S
	{
		static immutable Ramp ramp;

		// Need to use static initialization instead of CTFE due to
		// https://issues.dlang.org/show_bug.cgi?id=12412
		shared static this()
		{
			ramp = Ramp(value);
		}
	}
	return S.ramp;
}

debug(ae_unittest) unittest
{
	// test instantiation
	auto lum = onePixel(RGB16(1, 2, 3));
	auto pix = lum.lum2pix(gammaRamp!(ushort, ubyte, ColorSpace.sRGB));
}
