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
import ae.utils.meta;

struct HRImage(COLOR, int HRX, int HRY=HRX)
{
	Image!COLOR hr, lr;

	this(int w, int h)
	{
		lr.size(w, h);
		hr.size(w*HRX, h*HRY);
	}

	void upscale()
	{
		hr.upscaleDraw!(HRX, HRY)(lr);
	}

	void downscale()
	{
		lr.downscaleDraw!(HRX, HRY)(hr);
	}

	void pixel(int x, int y, COLOR c)
	{
		pixelHR(x*HRX, y*HRY, c);
	}

	void pixelHR(int x, int y, COLOR c)
	{
		hr.fillRect(x, y, x+HRX, y+HRY, c);
	}

	void line(int x1, int y1, int x2, int y2, COLOR c)
	{
		auto xmin = min(x1, x2);
		auto xmax = max(x1, x2);
		auto ymin = min(y1, y2);
		auto ymax = max(y1, y2);

		if (xmax-xmin > ymax-ymin)
			foreach (x; xmin..xmax+1)
				pixelHR(x*HRX, itpl(y1*HRY, y2*HRY, x, x1, x2), c);
		else
			foreach (y; ymin..ymax+1)
				pixelHR(itpl(x1*HRX, x2*HRX, y, y1, y2), y*HRY, c);
	}

	static if (HRX == HRY)
	void fineLine(int x1, int y1, int x2, int y2, COLOR c)
	{
		hr.thickLine(x1*HRX+HRX/2, y1*HRY+HRY/2, x2*HRX+HRX/2, y2*HRY+HRY/2, HRX/2, c);
	}
}

private
{
	// test instantiation
	alias HRImage!(RGB, 8) RGBHRImage;
}
