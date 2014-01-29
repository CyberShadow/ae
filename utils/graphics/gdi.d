/**
 * Utility Windows GDI code.
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

module ae.utils.graphics.gdi;

version(Windows):

import std.exception;

public import win32.wingdi;
import win32.winuser;
import win32.windef;

import ae.utils.graphics.canvas;

/// A canvas with added GDI functionality.
struct GDICanvas(COLOR)
{
	HDC hdc;
	HBITMAP hbm;
	
	int w, h;
	alias w stride;
	COLOR* pixels;
	mixin Canvas;

	alias std.algorithm.min min;
	alias std.algorithm.max max;

	this(uint w, uint h)
	{
		this.w = w;
		this.h = h;

		auto hddc = GetDC(null);
		scope(exit) ReleaseDC(null, hddc);
		hdc = CreateCompatibleDC(hddc);

		BITMAPINFO bmi;
		bmi.bmiHeader.biSize        = bmi.bmiHeader.sizeof;
		bmi.bmiHeader.biWidth       = w;
		bmi.bmiHeader.biHeight      = -h;
		bmi.bmiHeader.biPlanes      = 1;
		bmi.bmiHeader.biBitCount    = COLOR.sizeof * 8;
		bmi.bmiHeader.biCompression = BI_RGB;
		void* pvBits;
		hbm = CreateDIBSection(hdc, &bmi, DIB_RGB_COLORS, &pvBits, null, 0);
		enforce(hbm, "CreateDIBSection");
		SelectObject(hdc, hbm);
		pixels = cast(COLOR*)pvBits;
	}

	// TODO: make this struct refcounted / copiable
	~this()
	{
		DeleteDC(hdc);     hdc = null;
		DeleteObject(hbm); hbm = null;
	}

	auto opDispatch(string F, A...)(A args)
		if (is(typeof(mixin(F~"(hdc, args)"))))
	{
		mixin("return "~F~"(hdc, args);");
	}
}

unittest
{
//	alias BGR COLOR;
	alias BGRX COLOR;
	auto b = GDICanvas!COLOR(100, 100);
	b.clear(COLOR(255, 255, 255));

	const str = "Hello, world!";
	auto f = CreateFont(-11, 0, 0, 0, 0, 0, 0, 0, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY, DEFAULT_PITCH | FF_DONTCARE, "Tahoma"); scope(exit) DeleteObject(f);
	b.SelectObject(f);
	b.SetBkColor(0xFFFFFF);
	b.SetTextColor(0x0000FF);
	b.TextOutA(10, 10, str.ptr, cast(uint)str.length);

	b.SetPixel(5, 5, 0xFF0000);
	GdiFlush();
	b[6, 6] = COLOR(255, 0, 0);

	import ae.utils.graphics.image;
	Image!RGB i;
	i.size(b.w, b.h);
	i.transformDraw!`RGB(c.r,c.g,c.b)`(0, 0, b);
	assert(i[5, 5] == RGB(0, 0, 255));
	assert(i[6, 6] == RGB(0, 0, 255));

//	i.savePNG("gditest.png");
//	i.savePNM("gditest.pnm");
}
