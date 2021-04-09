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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.graphics.gdi;

version(Windows):

import std.exception;
import std.typecons;

import ae.sys.windows.imports;
mixin(importWin32!(q{wingdi}, q{public}));
mixin(importWin32!q{winuser});
mixin(importWin32!q{windef});

import ae.utils.graphics.color;
import ae.utils.graphics.draw;
import ae.utils.graphics.image : bitmapPixelStride;
import ae.utils.graphics.view;

pragma(lib, "gdi32");

/// A canvas with added GDI functionality.
struct GDICanvas(COLOR)
{
	/// Storage type used by the GDI buffer.
	static if (is(COLOR == bool))
		alias StorageType = OneBitStorageBE;
	else
		alias StorageType = PlainStorageUnit!COLOR;

	/// Wraps and owns the Windows API objects.
	struct Data
	{
		HDC hdc;     /// Windows GDI DC handle.
		HBITMAP hbm; /// Windows GDI bitmap handle.

		@disable this(this);

		~this() nothrow @nogc
		{
			alias DeleteDC_t     = extern(Windows) void function(HDC    ) nothrow @nogc;
			alias DeleteObject_t = extern(Windows) void function(HBITMAP) nothrow @nogc;
			auto pDeleteDC     = cast(DeleteDC_t    )&DeleteDC;
			auto pDeleteObject = cast(DeleteObject_t)&DeleteObject;
			pDeleteDC(hdc);     hdc = null;
			pDeleteObject(hbm); hbm = null;
		}
	}

	RefCounted!Data data; /// Reference to the Windows API objects.

	/// Geometry.
	xy_t w, h;
	StorageType* pixelData;
	sizediff_t pixelStride;

	/// `DirectView` interface.
	inout(StorageType)[] scanline(xy_t y) inout
	{
		assert(y>=0 && y<h);
		auto row = cast(void*)pixelData + y * pixelStride;
		auto storageUnitsPerRow = (w + StorageType.length - 1) / StorageType.length;
		return (cast(inout(StorageType)*)row)[0 .. storageUnitsPerRow];
	}

	mixin DirectView;

	this(uint w, uint h)
	{
		this.w = w;
		this.h = h;

		auto hddc = GetDC(null);
		scope(exit) ReleaseDC(null, hddc);
		data.hdc = CreateCompatibleDC(hddc);

		BITMAPINFO bmi;
		bmi.bmiHeader.biSize        = bmi.bmiHeader.sizeof;
		bmi.bmiHeader.biWidth       = w;
		bmi.bmiHeader.biHeight      = -h;
		bmi.bmiHeader.biPlanes      = 1;
		bmi.bmiHeader.biBitCount    = StorageType.sizeof * 8 / StorageType.length;
		bmi.bmiHeader.biCompression = BI_RGB;
		void* pvBits;
		data.hbm = CreateDIBSection(data.hdc, &bmi, DIB_RGB_COLORS, &pvBits, null, 0);
		enforce(data.hbm && pvBits, "CreateDIBSection");
		SelectObject(data.hdc, data.hbm);
		pixelData = cast(StorageType*)pvBits;
		pixelStride = bitmapPixelStride!StorageType(w);
	} ///

	/// Forwards Windows GDI calls.
	auto opDispatch(string F, A...)(A args)
		if (is(typeof(mixin(F~"(data.hdc, args)"))))
	{
		mixin("return "~F~"(data.hdc, args);");
	}
}

///
unittest
{
	alias RGB = ae.utils.graphics.color.RGB;

//	alias BGR COLOR;
	alias BGRX COLOR;
	auto b = GDICanvas!COLOR(100, 100);
	b.fill(COLOR(255, 255, 255));

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
	auto i = b.copy.colorMap!(c => RGB(c.r,c.g,c.b))();
	assert(i[5, 5] == RGB(0, 0, 255));
	assert(i[6, 6] == RGB(0, 0, 255));
	assert(i[7, 7] == RGB(255, 255, 255));

//	i.savePNG("gditest.png");
//	i.savePNM("gditest.pnm");
}

unittest
{
	auto b = GDICanvas!bool(100, 100);
	b.fill(true);

	b.SetPixel(5, 5, 0x000000);
	GdiFlush();
	b[6, 6] = false;

	import ae.utils.graphics.image : copy;
	auto i = b.copy.colorMap!(c => L8(c * 0xFF))();
	assert(i[5, 5] == L8(0));
	assert(i[6, 6] == L8(0));
	assert(i[7, 7] == L8(255));
}
