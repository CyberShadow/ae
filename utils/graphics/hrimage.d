/**
 * Wrapper around two images with up/downscaling functions.
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

module ae.utils.graphics.hrimage;

import ae.utils.graphics.image;

struct HRImage(COLOR, int HR)
{
	Image!COLOR hr, lr;

	this(int w, int h)
	{
		lr.size(w, h);
		hr.size(w*HR, h*HR);
	}

	void upscale()
	{
		foreach (y; 0..lr.h)
			foreach (x, c; lr.pixels[y*lr.w..(y+1)*lr.w])
				hr.fillRect(x*HR, y*HR, x*HR+HR, y*HR+HR, c);
	}

	void downscale()
	{
		foreach (y; 0..lr.h)
			foreach (x; 0..lr.w)
			{
				static if (HR*HR <= 0x100)
					enum EXPAND_BYTES = 1;
				else
				static if (HR*HR <= 0x10000)
					enum EXPAND_BYTES = 2;
				else
					static assert(0);
				static if (is(typeof(COLOR.init.a))) // downscale with alpha
				{
					ExpandType!(COLOR, EXPAND_BYTES+COLOR.init.a.sizeof) sum;
					ExpandType!(typeof(COLOR.init.a), EXPAND_BYTES) alphaSum;
					auto start = y*HR*hr.stride + x*HR;
					foreach (j; 0..HR)
					{
						foreach (p; hr.pixels[start..start+HR])
						{
							foreach (i, f; p.tupleof)
								static if (p.tupleof[i].stringof != "p.a")
								{
									enum FIELD = p.tupleof[i].stringof[2..$];
									mixin("sum."~FIELD~" += cast(typeof(sum."~FIELD~"))p."~FIELD~" * p.a;");
								}
							alphaSum += p.a;
						}
						start += hr.stride;
					}
					if (alphaSum)
					{
						auto result = cast(COLOR)(sum / alphaSum);
						result.a = cast(typeof(result.a))(alphaSum / (HR*HR));
						lr[x, y] = result;
					}
					else
					{
						static assert(COLOR.init.a == 0);
						lr[x, y] = COLOR.init;
					}
				}
				else
				{
					ExpandType!(COLOR, EXPAND_BYTES) sum;
					auto start = y*HR*hr.stride + x*HR;
					foreach (j; 0..HR)
					{
						foreach (p; hr.pixels[start..start+HR])
							sum += p;
						start += hr.stride;
					}
					lr[x, y] = cast(COLOR)(sum / (HR*HR));
				}
			}
	}

	void pixel(int x, int y, COLOR c)
	{
		pixelHR(x*HR, y*HR, c);
	}

	void pixelHR(int x, int y, COLOR c)
	{
		hr.fillRect(x, y, x+HR, y+HR, c);
	}

	void line(int x1, int y1, int x2, int y2, COLOR c)
	{
		auto xmin = min(x1, x2);
		auto xmax = max(x1, x2);
		auto ymin = min(y1, y2);
		auto ymax = max(y1, y2);

		if (xmax-xmin > ymax-ymin)
			foreach (x; xmin..xmax+1)
				pixelHR(x*HR, itpl(y1*HR, y2*HR, x, x1, x2), c);
		else
			foreach (y; ymin..ymax+1)
				pixelHR(itpl(x1*HR, x2*HR, y, y1, y2), y*HR, c);
	}

	void fineLine(int x1, int y1, int x2, int y2, COLOR c)
	{
		hr.thickLine(x1*HR+HR/2, y1*HR+HR/2, x2*HR+HR/2, y2*HR+HR/2, HR/2, c);
	}
}

private
{
	// test intantiation
	alias Image!RGB RGBImage;
}
