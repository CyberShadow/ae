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

/// Wrapper around two images with up/downscaling functions.
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
