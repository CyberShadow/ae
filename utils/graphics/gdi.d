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
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2012
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

/// Utility Windows GDI code.
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

	~this()
	{
		DeleteDC(hdc);
		DeleteObject(hbm);
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
	b.TextOut(10, 10, str.ptr, str.length);

	b.SetPixel(5, 5, 0xFF0000);
	GdiFlush();
	b[6, 6] = COLOR(255, 0, 0);

	import ae.utils.graphics.image;
	Image!RGB i;
	i.size(b.w, b.h);
	i.transformDraw!`RGB(c.r,c.g,c.b)`(b, 0, 0);
	assert(i[5, 5] == RGB(0, 0, 255));
	assert(i[6, 6] == RGB(0, 0, 255));

//	i.savePNG("gditest.png");
//	i.savePNM("gditest.pnm");
}
