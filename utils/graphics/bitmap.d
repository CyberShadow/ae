/**
 * Windows Bitmap definitions.
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

module ae.utils.graphics.bitmap;

alias int FXPT2DOT30;
struct CIEXYZ { FXPT2DOT30 ciexyzX, ciexyzY, ciexyzZ; }
struct CIEXYZTRIPLE { CIEXYZ ciexyzRed, ciexyzGreen, ciexyzBlue; }
enum { BI_BITFIELDS = 3 }

align(1)
struct BitmapHeader(uint V)
{
	enum VERSION = V;

align(1):
	// BITMAPFILEHEADER
	char[2] bfType = "BM";
	uint    bfSize;
	ushort  bfReserved1;
	ushort  bfReserved2;
	uint    bfOffBits;

	// BITMAPCOREINFO
	uint   bcSize = this.sizeof - bcSize.offsetof;
	int    bcWidth;
	int    bcHeight;
	ushort bcPlanes;
	ushort bcBitCount;
	uint   biCompression;
	uint   biSizeImage;
	uint   biXPelsPerMeter;
	uint   biYPelsPerMeter;
	uint   biClrUsed;
	uint   biClrImportant;

	// BITMAPV4HEADER
	static if (V>=4)
	{
		uint         bV4RedMask;
		uint         bV4GreenMask;
		uint         bV4BlueMask;
		uint         bV4AlphaMask;
		uint         bV4CSType;
		CIEXYZTRIPLE bV4Endpoints;
		uint         bV4GammaRed;
		uint         bV4GammaGreen;
		uint         bV4GammaBlue;
	}

	// BITMAPV5HEADER
	static if (V>=5)
	{
		uint        bV5Intent;
		uint        bV5ProfileData;
		uint        bV5ProfileSize;
		uint        bV5Reserved;
	}
}
