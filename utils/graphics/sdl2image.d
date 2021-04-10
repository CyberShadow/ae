/**
 * SDL_Image support.
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

module ae.utils.graphics.sdl2image;

import ae.utils.graphics.color;
import ae.utils.graphics.image;

import derelict.sdl2.sdl;
import derelict.sdl2.image;

import std.exception;
import std.string : toStringz, format;
static import std.string;

static this()
{
	DerelictSDL2.load();
	DerelictSDL2Image.load();

	IMG_Init(IMG_INIT_JPG | IMG_INIT_PNG);
}

/// Loads an `Image` using `SDL_Image`.
auto loadImage(string path, ref Image!RGBX target = *new Image!RGBX)
{
	auto surface = IMG_Load(toStringz(path));
	enforce(surface, "Failed to load image " ~ path);
	scope(exit) SDL_FreeSurface(surface);
	target.size(surface.w, surface.h);

	if (surface.format.palette)
	{
		switch (surface.format.BitsPerPixel)
		{
			case 1: depalettize!1(cast(ubyte*)surface.pixels, cast(RGBX*)target.pixels.ptr, surface.format.palette, surface.w, surface.h, surface.pitch); break;
			case 2: depalettize!2(cast(ubyte*)surface.pixels, cast(RGBX*)target.pixels.ptr, surface.format.palette, surface.w, surface.h, surface.pitch); break;
			case 4: depalettize!4(cast(ubyte*)surface.pixels, cast(RGBX*)target.pixels.ptr, surface.format.palette, surface.w, surface.h, surface.pitch); break;
			case 8: depalettize!8(cast(ubyte*)surface.pixels, cast(RGBX*)target.pixels.ptr, surface.format.palette, surface.w, surface.h, surface.pitch); break;
			default:
				enforce(false, format("Don't know how to depalettize image with %d bits per pixel", surface.format.BitsPerPixel));
		}
	}
	else
		rgbTransform(cast(ubyte*)surface.pixels, cast(RGBX*)target.pixels.ptr, surface.format, surface.w, surface.h, surface.pitch);

	return target;
}

private:

void depalettize(int BITS)(ubyte* src, RGBX* dst, SDL_Palette *palette, uint w, uint h, int pitch)
{
	static assert(BITS <= 8);

	auto ncolors = palette.ncolors;
	foreach (y; 0..h)
	{
		auto p = src;
		foreach (x; 0..w)
		{
			ubyte c;
			static if (BITS == 8)
				c = *p++;
			else
				c = p[x / (8/BITS)] & (((1<<BITS)-1) << (x % (8/BITS)));

			if (c >= ncolors)
				throw new Exception("Color index exceeds number of colors in palette");
			*dst++ = cast(RGBX)(palette.colors[c]);
		}
		src += pitch;
	}
}

void rgbTransform(ubyte* src, RGBX* dst, SDL_PixelFormat *format, uint w, uint h, int pitch)
{
	auto bpp = format.BitsPerPixel;
	enforce(bpp%8 == 0 && bpp >= 8 && bpp <= 32, std.string.format("Don't know how to process unpalettized image with %d bits per pixel", bpp));

	if (bpp == 32
	 && format.Rmask == 0x00_00_00_FF && format.Rshift== 0
	 && format.Gmask == 0x00_00_FF_00 && format.Rshift== 8
	 && format.Bmask == 0x00_FF_00_00 && format.Rshift==16)
	{
		// Everything is already in our desired format.
		foreach (y; 0..h)
		{
			auto p = cast(RGBX*)src;
			dst[0..w] = p[0..w];
			src += pitch;
			dst += w;
		}
	}
	else
	{
		// Use SDL_GetRGB for whatever weird formats.
		auto Bpp = format.BytesPerPixel;
		foreach (y; 0..h)
		{
			auto p = src;
			foreach (x; 0..w)
			{
				RGBX c;
				SDL_GetRGB(*cast(uint*)p, format, &c.r, &c.g, &c.b);
				*dst++ = c;
				p += Bpp;
			}
			src += pitch;
		}
	}
}
