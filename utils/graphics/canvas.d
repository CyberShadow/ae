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
 * Portions created by the Initial Developer are Copyright (C) 2007-2012
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

/// Abstract drawing functions.
module ae.utils.graphics.canvas;

import std.string;
import std.math;
import std.traits;

public import ae.utils.math;

// TODO: rewrite everything to use stride in bytes, not pixels

struct Coord { int x, y; string toString() { return format([this.tupleof]); } }

template IsCanvas(T)
{
	enum IsCanvas =
		is(typeof(T.init.w     )) && // width
		is(typeof(T.init.h     )) && // height
		is(typeof(T.init.stride)) && // stride in pixels (not bytes), can be "w" alias
		is(typeof(T.init.pixels));   // array or pointer
}

mixin template Canvas()
{
	import ae.utils.geometry;
	import std.math : atan2, sqrt;
	import std.random: uniform;

	static assert(IsCanvas!(typeof(this)));

	alias typeof(pixels[0]) COLOR;

	ref COLOR opIndex(int x, int y)
	{
		assert(x>=0 && y>=0 && x<w && y<h);
		return pixels[y*stride+x];
	}

	void opIndexAssign(COLOR value, int x, int y)
	{
		assert(x>=0 && y>=0 && x<w && y<h);
		pixels[y*stride+x] = value;
	}

	COLOR safeGet(int x, int y, COLOR def)
	{
		if (x>=0 && y>=0 && x<w && y<h)
			return pixels[y*stride+x];
		else
			return def;
	}

	void safePut(int x, int y, COLOR value)
	{
		if (x>=0 && y>=0 && x<w && y<h)
			pixels[y*stride+x] = value;
	}

	// For easy passing of CHECKED parameter
	void putPixel(bool CHECKED)(int x, int y, COLOR value)
	{
		static if (CHECKED)
			safePut(x, y, value);
		else
			this[x, y] = value;
	}

	COLOR* scanline(int y)
	{
		assert(y>=0 && y<h);
		return &pixels[stride*y];
	}

	COLOR* pixelPtr(int x, int y)
	{
		assert(x>=0 && y>=0 && x<w && y<h);
		return &pixels[stride*y + x];
	}

	void clear(COLOR c)
	{
		static if (is(typeof(pixels[]))) // pixels is an array
			pixels[] = c;
		else
			pixels[0..h*stride] = c;
	}

	void draw(bool CHECKED=true, SRCCANVAS)(SRCCANVAS src, int x, int y)
		if (IsCanvas!SRCCANVAS && is(COLOR == SRCCANVAS.COLOR))
	{
		static if (CHECKED)
		{
			if (x+src.w <= 0 || y+src.h <= 0 || x >= w || y >= h)
				return;

			auto r = src.window(0, 0, src.w, src.h);
			if (x < 0)
				r = r.window(-x, 0, r.w, r.h),
				x = 0;
			if (y < 0)
				r = r.window(0, -y, r.w, r.h),
				y = 0;
			if (x+r.w > w)
				r = r.window(0, 0, w-x, r.h);
			if (y+r.h > h)
				r = r.window(0, 0, r.w, h-y);

			draw!false(r, x, y);
		}
		else
		{
			assert(x >= 0 && x+src.w <= w && y >= 0 && y+src.h <= h);

			// TODO: alpha blending
			size_t dstStart = y*stride+x, srcStart = 0;
			foreach (j; 0..src.h)
				pixels[dstStart..dstStart+src.w] = src.pixels[srcStart..srcStart+src.w],
				dstStart += stride,
				srcStart += src.stride;
		}
	}

	/// Copy another canvas while applying a pixel transformation.
	/// Context of pred:
	///   c            = source color
	///   src          = source canvas
	///   extraArgs[n] = any extra arguments passed to transformDraw
	void transformDraw(string pred, SRCCANVAS, T...)(ref SRCCANVAS src, int x, int y, T extraArgs)
		if (IsCanvas!SRCCANVAS)
	{
		assert(x+src.w <= w && y+src.h <= h);
		size_t dstSlack = stride-src.w, srcSlack = src.stride-src.w;
		auto dstPtr = &pixels[0] + (y*stride+x);
		auto srcPtr = &src.pixels[0];
		auto endPtr = srcPtr + src.h*src.stride;
		while (srcPtr < endPtr)
		{
			foreach (i; 0..src.w)
			{
				auto c = *srcPtr++;
				*dstPtr++ = mixin(pred);
			}
			srcPtr += srcSlack;
			dstPtr += dstSlack;
		}
	}

	void warp(string pred, SRCCANVAS, T...)(ref SRCCANVAS src, T extraArgs)
		if (IsCanvas!SRCCANVAS)
	{
		assert(src.w == w && src.h == h);
		foreach (y; 0..h)
			foreach (x, ref c; pixels[y*stride..y*stride+w])
			{
				mixin(pred);
			}
	}

	/// Does not make a copy - only returns a "view" onto this canvas.
	auto window()(int x1, int y1, int x2, int y2)
	{
		assert(x1 >= 0 && y1 >= 0 && x2 <= w && y2 <= h && x1 <= x2 && y1 <= y2);

		return RefCanvas!COLOR(x2-x1, y2-y1, stride, pixelPtr(x1, y1));
	}

	enum CheckHLine =
	q{
		static if (CHECKED)
		{
			if (x1 >= w || x2 <= 0 || y < 0 || y >= h || x1 >= x2) return;
			if (x1 <  0) x1 = 0;
			if (x2 >= w) x2 = w;
		}
		assert(x1 <= x2);
	};

	enum CheckVLine =
	q{
		static if (CHECKED)
		{
			if (x < 0 || x >= w || y1 >= h || y2 <= 0 || y1 >= y2) return;
			if (y1 <  0) y1 = 0;
			if (y2 >= h) y2 = h;
		}
		assert(y1 <= y2);
	};

	void hline(bool CHECKED=true)(int x1, int x2, int y, COLOR c)
	{
		mixin(CheckHLine);
		auto rowOffset = y*stride;
		pixels[rowOffset+x1..rowOffset+x2] = c;
	}

	void vline(bool CHECKED=true)(int x, int y1, int y2, COLOR c)
	{
		mixin(CheckVLine);
		foreach (y; y1..y2) // TODO: optimize
			pixels[y*stride+x] = c;
	}

	void line(bool CHECKED=true)(int x1, int y1, int x2, int y2, COLOR c)
	{
		enum DrawLine = q{
			// Axis-independent part. Mixin context:
			// a0 .. a1  - longer side
			// b0 .. b1  - shorter side
			// DrawPixel - mixin to draw a pixel at coordinates (a, b)

			if (a0 == a1)
				return;

			if (a0 > a1)
			{
				 swap(a0, a1);
				 swap(b0, b1);
			}

			// Use fixed-point for b position and offset per 1 pixel along "a" axis
			assert(b0 < (1L<<CoordinateBits) && b1 < (1L<<CoordinateBits));
			SignedBitsType!(CoordinateBits*2) bPos = b0 << CoordinateBits;
			SignedBitsType!(CoordinateBits*2) bOff = ((b1-b0) << CoordinateBits) / (a1-a0);

			foreach (a; a0..a1+1)
			{
				int b = (bPos += bOff) >> CoordinateBits;
				mixin(DrawPixel);
			}
		};

		if (abs(x2-x1) > abs(y2-y1))
		{
			alias x1 a0;
			alias x2 a1;
			alias y1 b0;
			alias y2 b1;
			enum DrawPixel = q{ putPixel!CHECKED(a, b, c); };
			mixin(DrawLine);
		}
		else
		{
			alias y1 a0;
			alias y2 a1;
			alias x1 b0;
			alias x2 b1;
			enum DrawPixel = q{ putPixel!CHECKED(b, a, c); };
			mixin(DrawLine);
		}
	}

	void rect(bool CHECKED=true)(int x1, int y1, int x2, int y2, COLOR c) // [)
	{
		sort2(x1, x2);
		sort2(y1, y2);
		hline!CHECKED(x1, x2-1, y1, c);
		hline!CHECKED(x1, x2-1, y2, c);
		vline!CHECKED(x1, y1, y2-1, c);
		vline!CHECKED(x2, y1, y2-1, c);
	}

	void fillRect(bool CHECKED=true)(int x1, int y1, int x2, int y2, COLOR b) // [)
	{
		sort2(x1, x2);
		sort2(y1, y2);
		static if (CHECKED)
		{
			if (x1 >= w || y1 >= h || x2 <= 0 || y2 <= 0 || x1==x2 || y1==y2) return;
			if (x1 <  0) x1 = 0;
			if (y1 <  0) y1 = 0;
			if (x2 >= w) x2 = w;
			if (y2 >= h) y2 = h;
		}
		foreach (y; y1..y2)
			pixels[y*stride+x1..y*stride+x2] = b;
	}

	void fillRect(bool CHECKED=true)(int x1, int y1, int x2, int y2, COLOR c, COLOR b) // [)
	{
		rect!CHECKED(x1, y1, x2, y2, c);
		if (x2-x1>2 && y2-y1>2)
			fillRect!CHECKED(x1+1, y1+1, x2-1, y2-1, b);
	}

	/// Unchecked! Make sure area is bounded.
	void uncheckedFloodFill(int x, int y, COLOR c)
	{
		floodFillPtr(&this[x, y], c, this[x, y]);
	}

	private void floodFillPtr(COLOR* pp, COLOR c, COLOR f)
	{
		COLOR* p0 = pp; while (*p0==f) p0--; p0++;
		COLOR* p1 = pp; while (*p1==f) p1++; p1--;
		for (auto p=p0; p<=p1; p++)
			*p = c;
		p0 -= stride; p1 -= stride;
		for (auto p=p0; p<=p1; p++)
			if (*p == f)
				floodFillPtr(p, c, f);
		p0 += stride*2; p1 += stride*2;
		for (auto p=p0; p<=p1; p++)
			if (*p == f)
				floodFillPtr(p, c, f);
	}

	void fillCircle(int x, int y, int r, COLOR c)
	{
		int x0 = x>r?x-r:0;
		int y0 = y>r?y-r:0;
		int x1 = min(x+r, w-1);
		int y1 = min(y+r, h-1);
		int rs = sqr(r);
		// TODO: optimize
		foreach (py; y0..y1+1)
			foreach (px; x0..x1+1)
				if (sqr(x-px) + sqr(y-py) < rs)
					this[px, py] = c;
	}

	void fillSector(int x, int y, int r0, int r1, real a0, real a1, COLOR c)
	{
		int x0 = x>r1?x-r1:0;
		int y0 = y>r1?y-r1:0;
		int x1 = min(x+r1, w-1);
		int y1 = min(y+r1, h-1);
		int r0s = sqr(r0);
		int r1s = sqr(r1);
		if (a0 > a1)
			a1 += TAU;
		foreach (py; y0..y1+1)
			foreach (px; x0..x1+1)
			{
				int dx = px-x;
				int dy = py-y;
				int rs = sqr(dx) + sqr(dy);
				if (r0s <= rs && rs < r1s)
				{
					real a = atan2(cast(real)dy, cast(real)dx);
					if ((a0 <= a && a <= a1) ||
					    (a += TAU,
					    (a0 <= a && a <= a1)))
						this[px, py] = c;
				}
			}
	}

	void fillPoly(Coord[] coords, COLOR f)
	{
		int minY, maxY;
		minY = maxY = coords[0].y;
		foreach (c; coords[1..$])
			minY = min(minY, c.y),
			maxY = max(maxY, c.y);

		foreach (y; minY..maxY+1)
		{
			int[] intersections;
			for (uint i=0; i<coords.length; i++)
			{
				auto c0=coords[i], c1=coords[i==$-1?0:i+1];
				if (y==c0.y)
				{
					assert(y == coords[i%$].y);
					int pi = i-1; int py;
					while ((py=coords[(pi+$)%$].y)==y)
						pi--;
					int ni = i+1; int ny;
					while ((ny=coords[ni%$].y)==y)
						ni++;
					if (ni > coords.length)
						continue;
					if ((py>y) == (y>ny))
						intersections ~= coords[i%$].x;
					i = ni-1;
				}
				else
				if (c0.y<y && y<c1.y)
					intersections ~= itpl(c0.x, c1.x, y, c0.y, c1.y);
				else
				if (c1.y<y && y<c0.y)
					intersections ~= itpl(c1.x, c0.x, y, c1.y, c0.y);
			}

			assert(intersections.length % 2==0);
			intersections.sort;
			for (uint i=0; i<intersections.length; i+=2)
				hline!true(intersections[i], intersections[i+1], y, f);
		}
	}

	// No caps
	void thickLine(int x1, int y1, int x2, int y2, int r, COLOR c)
	{
		int dx = x2-x1;
		int dy = y2-y1;
		int d  = cast(int)sqrt(sqr(dx)+sqr(dy));
		if (d==0) return;

		int nx = dx*r/d;
		int ny = dy*r/d;

		fillPoly([
			Coord(x1-ny, y1+nx),
			Coord(x1+ny, y1-nx),
			Coord(x2+ny, y2-nx),
			Coord(x2-ny, y2+nx),
		], c);
	}

	// No caps
	void thickLinePoly(Coord[] coords, int r, COLOR c)
	{
		foreach (i; 0..coords.length)
			thickLine(coords[i].tupleof, coords[(i+1)%$].tupleof, r, c);
	}

	// ************************************************************************************************************************************

	/// Maximum number of bits used in a coordinate (assumption)
	enum CoordinateBits = 16;

	static assert(COLOR.SameType, "Asymmetric color types not supported, fix me!");
	/// Fixed-point type, big enough to hold a coordinate, with fractionary precision corresponding to channel precision.
	typedef SignedBitsType!(COLOR.BaseTypeBits   + CoordinateBits) fix;
	/// Type to hold temporary values for multiplication and division
	typedef SignedBitsType!(COLOR.BaseTypeBits*2 + CoordinateBits) fix2;

	static assert(COLOR.BaseTypeBits < 32, "Shift operators are broken for shifts over 32 bits, fix me!");
	fix tofix(T:int  )(T x) { return cast(fix) (x<<COLOR.BaseTypeBits); }
	fix tofix(T:float)(T x) { return cast(fix) (x*(1<<COLOR.BaseTypeBits)); }
	T fixto(T:int)(fix x) { return cast(T)(x>>COLOR.BaseTypeBits); }

	fix fixsqr(fix x)        { return cast(fix)((cast(fix2)x*x) >> COLOR.BaseTypeBits); }
	fix fixmul(fix x, fix y) { return cast(fix)((cast(fix2)x*y) >> COLOR.BaseTypeBits); }
	fix fixdiv(fix x, fix y) { return cast(fix)((cast(fix2)x << COLOR.BaseTypeBits)/y); }

	static assert(COLOR.BaseType.sizeof*8 == COLOR.BaseTypeBits, "COLORs with BaseType not corresponding to native type not currently supported, fix me!");
	/// Type only large enough to hold a fractionary part of a "fix" (i.e. color channel precision). Used for alpha values, etc.
	alias COLOR.BaseType frac;
	/// Type to hold temporary values for multiplication and division
	typedef UnsignedBitsType!(COLOR.BaseTypeBits*2) frac2;

	frac tofrac(T:float)(T x) { return cast(frac) (x*(1<<COLOR.BaseTypeBits)); }
	frac fixfpart(fix x) { return cast(frac)x; }
	frac fracsqr(frac x        ) { return cast(frac)((cast(frac2)x*x) >> COLOR.BaseTypeBits); }
	frac fracmul(frac x, frac y) { return cast(frac)((cast(frac2)x*y) >> COLOR.BaseTypeBits); }

	frac tofracBounded(T:float)(T x) { return cast(frac) bound(tofix(x), 0, frac.max); }

	// ************************************************************************************************************************************

	void whiteNoise()
	{
		for (int y=0;y<h/2;y++)
			for (int x=0;x<w/2;x++)
				pixels[y*2  *stride + x*2  ] = COLOR.monochrome(uniform!(COLOR.BaseType)());

		// interpolate
		enum AVERAGE = q{(a+b)/2};

		for (int y=0;y<h/2;y++)
			for (int x=0;x<w/2-1;x++)
				pixels[y*2  *stride + x*2+1] = COLOR.op!AVERAGE(pixels[y*2*stride + x*2], pixels[y*2*stride + x*2+2]);
		for (int y=0;y<h/2-1;y++)
			for (int x=0;x<w/2;x++)
				pixels[(y*2+1)*stride + x*2  ] = COLOR.op!AVERAGE(pixels[y*2*stride + x*2], pixels[(y*2+2)*stride + x*2]);
		for (int y=0;y<h/2-1;y++)
			for (int x=0;x<w/2-1;x++)
				pixels[(y*2+1)*stride + x*2+1] = COLOR.op!AVERAGE(pixels[y*2*stride + x*2+1], pixels[(y*2+2)*stride + x*2+2]);
	}

	private void softRoundShape(bool RING, T)(T x, T y, T r0, T r1, T r2, COLOR color)
		if (is(T : int) || is(T : float))
	{
		assert(r0 <= r1);
		assert(r1 <= r2);
		assert(r2 < 256); // precision constraint - see SqrType
		//int ix = cast(int)x;
		//int iy = cast(int)y;
		//int ir1 = cast(int)sqr(r1-1);
		//int ir2 = cast(int)sqr(r2+1);
		int x1 = cast(int)(x-r2-1); if (x1<0) x1=0;
		int y1 = cast(int)(y-r2-1); if (y1<0) y1=0;
		int x2 = cast(int)(x+r2+1); if (x2>w ) x2 = w;
		int y2 = cast(int)(y+r2+1); if (y2>h) y2 = h;

		static if (RING)
		auto r0s = r0*r0;
		auto r1s = r1*r1;
		auto r2s = r2*r2;
		//float rds = r2s - r1s;

		fix fx = tofix(x);
		fix fy = tofix(y);

		static if (RING)
		fix fr0s = tofix(r0s);
		fix fr1s = tofix(r1s);
		fix fr2s = tofix(r2s);

		static if (RING)
		fix fr10 = fr1s - fr0s;
		fix fr21 = fr2s - fr1s;

		for (int cy=y1;cy<y2;cy++)
		{
			auto row = scanline(cy);
			for (int cx=x1;cx<x2;cx++)
			{
				alias SignedBitsType!(2*(8 + COLOR.BaseTypeBits)) SqrType; // fit the square of radius expressed as fixed-point
				fix frs = cast(fix)((sqr(cast(SqrType)fx-tofix(cx)) + sqr(cast(SqrType)fy-tofix(cy))) >> COLOR.BaseTypeBits); // shift-right only once instead of once-per-sqr

				//static frac alphafunc(frac x) { return fracsqr(x); }
				static frac alphafunc(frac x) { return x; }

				static if (RING)
				{
					if (frs<fr0s)
						{}
					else
					if (frs<fr2s)
					{
						frac alpha;
						if (frs<fr1s)
							alpha =  alphafunc(cast(frac)fixdiv(frs-fr0s, fr10));
						else
							alpha = ~alphafunc(cast(frac)fixdiv(frs-fr1s, fr21));
						row[cx] = COLOR.op!q{blend(a, b, c)}(color, row[cx], alpha);
					}
				}
				else
				{
					if (frs<fr1s)
						row[cx] = color;
					else
					if (frs<fr2s)
					{
						frac alpha = ~alphafunc(cast(frac)fixdiv(frs-fr1s, fr21));
						row[cx] = COLOR.op!q{blend(a, b, c)}(color, row[cx], alpha);
					}
				}
			}
		}
	}

	void softRing(T)(T x, T y, T r0, T r1, T r2, COLOR color)
		if (is(T : int) || is(T : float))
	{
		softRoundShape!(true, T)(x, y, r0, r1, r2, color);
	}

	void softCircle(T)(T x, T y, T r1, T r2, COLOR color)
		if (is(T : int) || is(T : float))
	{
		softRoundShape!(false, T)(x, y, 0, r1, r2, color);
	}

	void aaPutPixel(bool CHECKED=true, bool USE_ALPHA=true, F:float)(F x, F y, COLOR color, frac alpha)
	{
		void plot(bool CHECKED2)(int x, int y, frac f)
		{
			static if (CHECKED2)
				if (x<0 || x>=w || y<0 || y>=h)
					return;

			COLOR* p = pixelPtr(x, y);
			static if (USE_ALPHA) f = fracmul(f, alpha);
			*p = COLOR.op!q{blend(a, b, c)}(color, *p, f);
		}

		fix fx = tofix(x);
		fix fy = tofix(y);
		int ix = fixto!int(fx);
		int iy = fixto!int(fy);
		static if (CHECKED)
			if (ix>=0 && iy>=0 && ix+1<w && iy+1<h)
			{
				plot!false(ix  , iy  , fracmul(~fixfpart(fx), ~fixfpart(fy)));
				plot!false(ix  , iy+1, fracmul(~fixfpart(fx),  fixfpart(fy)));
				plot!false(ix+1, iy  , fracmul( fixfpart(fx), ~fixfpart(fy)));
				plot!false(ix+1, iy+1, fracmul( fixfpart(fx),  fixfpart(fy)));
				return;
			}
		plot!CHECKED(ix  , iy  , fracmul(~fixfpart(fx), ~fixfpart(fy)));
		plot!CHECKED(ix  , iy+1, fracmul(~fixfpart(fx),  fixfpart(fy)));
		plot!CHECKED(ix+1, iy  , fracmul( fixfpart(fx), ~fixfpart(fy)));
		plot!CHECKED(ix+1, iy+1, fracmul( fixfpart(fx),  fixfpart(fy)));
	}

	void aaPutPixel(bool CHECKED=true, F:float)(F x, F y, COLOR color)
	{
		//aaPutPixel!(false, F)(x, y, color, 0); // doesn't work, wtf
		alias aaPutPixel!(CHECKED, false, F) f;
		f(x, y, color, 0);
	}

	void hline(bool CHECKED=true)(int x1, int x2, int y, COLOR color, frac alpha)
	{
		mixin(CheckHLine);

		if (alpha==0)
			return;
		else
		if (alpha==frac.max)
			pixels[y*stride + x1 .. (y)*stride + x2] = color;
		else
			foreach (ref p; pixels[y*stride + x1 .. y*stride + x2])
				p = COLOR.op!q{blend(a, b, c)}(color, p, alpha);
	}

	void vline(bool CHECKED=true)(int x, int y1, int y2, COLOR color, frac alpha)
	{
		mixin(CheckVLine);

		if (alpha==0)
			return;
		else
		if (alpha==frac.max)
			foreach (y; y1..y2)
				this[x, y] = color;
		else
			foreach (y; y1..y2)
			{
				auto p = pixelPtr(x, y);
				*p = COLOR.op!q{blend(a, b, c)}(color, *p, alpha);
			}
	}

	void aaFillRect(bool CHECKED=true, F:float)(F x1, F y1, F x2, F y2, COLOR color)
	{
		sort2(x1, x2);
		sort2(y1, y2);
		fix x1f = tofix(x1); int x1i = fixto!int(x1f);
		fix y1f = tofix(y1); int y1i = fixto!int(y1f);
		fix x2f = tofix(x2); int x2i = fixto!int(x2f);
		fix y2f = tofix(y2); int y2i = fixto!int(y2f);

		vline!CHECKED(x1i, y1i+1, y2i, color, ~fixfpart(x1f));
		vline!CHECKED(x2i, y1i+1, y2i, color,  fixfpart(x2f));
		hline!CHECKED(x1i+1, x2i, y1i, color, ~fixfpart(y1f));
		hline!CHECKED(x1i+1, x2i, y2i, color,  fixfpart(y2f));
		aaPutPixel!CHECKED(x1i, y1i, color, fracmul(~fixfpart(x1f), ~fixfpart(y1f)));
		aaPutPixel!CHECKED(x1i, y2i, color, fracmul(~fixfpart(x1f),  fixfpart(y2f)));
		aaPutPixel!CHECKED(x2i, y1i, color, fracmul( fixfpart(x2f), ~fixfpart(y1f)));
		aaPutPixel!CHECKED(x2i, y2i, color, fracmul( fixfpart(x2f),  fixfpart(y2f)));

		fillRect!CHECKED(x1i+1, y1i+1, x2i, y2i, color);
	}

	void aaLine(bool CHECKED=true)(float x1, float y1, float x2, float y2, COLOR color)
	{
		// Simplistic straight-forward implementation. TODO: optimize
		if (abs(x1-x2) > abs(y1-y2))
			for (auto x=x1; sign(x1-x2)!=sign(x2-x); x += sign(x2-x1))
				aaPutPixel!CHECKED(x, itpl(y1, y2, x, x1, x2), color);
		else
			for (auto y=y1; sign(y1-y2)!=sign(y2-y); y += sign(y2-y1))
				aaPutPixel!CHECKED(itpl(x1, x2, y, y1, y2), y, color);
	}

	void aaLine(bool CHECKED=true)(float x1, float y1, float x2, float y2, COLOR color, frac alpha)
	{
		// ditto
		if (abs(x1-x2) > abs(y1-y2))
			for (auto x=x1; sign(x1-x2)!=sign(x2-x); x += sign(x2-x1))
				aaPutPixel!CHECKED(x, itpl(y1, y2, x, x1, x2), color, alpha);
		else
			for (auto y=y1; sign(y1-y2)!=sign(y2-y); y += sign(y2-y1))
				aaPutPixel!CHECKED(itpl(x1, x2, y, y1, y2), y, color, alpha);
	}
}

private bool isSameType(T)()
{
	foreach (i, f; T.init.tupleof)
		if (!is(typeof(T.init.tupleof[i]) == typeof(T.init.tupleof[0])))
			return false;
	return true;
}

struct Color(string FIELDS)
{
	struct Fields { mixin(FIELDS); } // for iteration

	// alias this bugs out with operator overloading, so just paste the fields here
	mixin(FIELDS);

	/// Whether or not all channel fields have the same base type.
	// Only "true" supported for now, may change in the future (e.g. for 5:6:5)
	enum SameType = isSameType!Fields();

	static if (SameType)
	{
		alias typeof(this.init.tupleof[0]) BaseType;
		enum BaseTypeBits = BaseType.sizeof*8;
	}

	/// Return a Color instance with all fields set to "value".
	static typeof(this) monochrome(BaseType value)
	{
		typeof(this) r;
		foreach (i, f; r.tupleof)
			r.tupleof[i] = value;
		return r;
	}

	/// Warning: overloaded operators preserve types and may cause overflows
	typeof(this) opBinary(string op, T)(T o)
		if (is(T == typeof(this)))
	{
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if(r.tupleof[i].stringof != "r.x") // skip padding
				r.tupleof[i] = cast(typeof(r.tupleof[i])) mixin(`this.tupleof[i]` ~ op ~ `o.tupleof[i]`);
		return r;
	}

	/// ditto
	typeof(this) opBinary(string op)(int o)
	{
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if(r.tupleof[i].stringof != "r.x") // skip padding
				r.tupleof[i] = cast(typeof(r.tupleof[i])) mixin(`this.tupleof[i]` ~ op ~ `o`);
		return r;
	}

	/// Apply a custom operation for each channel. Example:
	/// COLOR.op!q{(a + b) / 2}(colorA, colorB);
	static typeof(this) op(string expr, T...)(T values)
	{
		static assert(values.length <= 10);

		string genVars(string channel)
		{
			string result;
			foreach (j, Tj; T)
			{
				static if (is(Tj == struct)) // TODO: tighter constraint (same color channels)?
					result ~= "auto " ~ cast(char)('a' + j) ~ " = values[" ~ cast(char)('0' + j) ~ "]." ~  channel ~ ";\n";
				else
					result ~= "auto " ~ cast(char)('a' + j) ~ " = values[" ~ cast(char)('0' + j) ~ "];\n";
			}
			return result;
		}

		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if(r.tupleof[i].stringof != "r.x") // skip padding
			{
				mixin(genVars(r.tupleof[i].stringof[2..$]));
				r.tupleof[i] = mixin(expr);
			}
		return r;
	}
}

// The "x" has the special meaning of "padding" and is ignored in some circumstances
alias Color!q{ubyte  r, g, b;    } RGB    ;
alias Color!q{ushort r, g, b;    } RGB16  ;
alias Color!q{ubyte  r, g, b, x; } RGBX   ;
//alias Color!q{ushort r, g, b, x; } RGBX16 ;
alias Color!q{ubyte  r, g, b, a; } RGBA   ;
//alias Color!q{ushort r, g, b, a; } RGBA16 ;

alias Color!q{ubyte  b, g, r;    } BGR    ;
alias Color!q{ubyte  b, g, r, x; } BGRX   ;
alias Color!q{ubyte  b, g, r, a; } BGRA   ;

alias Color!q{ubyte  g;          } G8     ;
alias Color!q{ushort g;          } G16    ;
alias Color!q{ubyte  g, a;       } GA     ;
alias Color!q{ushort g, a;       } GA16   ;

alias Color!q{byte   g;          } S8     ;
alias Color!q{short  g;          } S16    ;

private
{
	static assert(RGB.sizeof == 3);
	RGB[2] test;
	static assert(test.sizeof == 6);
}

// *****************************************************************************

/// Unsigned integer type big enough to fit N bits of precision.
template UnsignedBitsType(uint BITS)
{
	static if (BITS <= 8)
		alias ubyte UnsignedBitsType;
	else
	static if (BITS <= 16)
		alias ushort UnsignedBitsType;
	else
	static if (BITS <= 32)
		alias uint UnsignedBitsType;
	else
	static if (BITS <= 64)
		alias ulong UnsignedBitsType;
	else
		static assert(0, "No integer type big enough to fit " ~ BITS.stringof ~ " bits");
}

template SignedBitsType(uint BITS)
{
	alias Signed!(UnsignedBitsType!BITS) SignedBitsType;
}

/// Create a type where each integer member of T is expanded by BYTES bytes.
template ExpandType(T, uint BYTES)
{
	static if (is(T : ulong))
		alias UnsignedBitsType!((T.sizeof + BYTES) * 8) ExpandType;
	else
	static if (is(T==struct))
		struct ExpandType
		{
			static string mixFields()
			{
				string s;
				string[] fields = structFields!T;

				foreach (field; fields)
					s ~= "ExpandType!(typeof(T.init." ~ field ~ "), "~BYTES.stringof~") " ~ field ~ ";\n";
				s ~= "\n";

				s ~= "void opOpAssign(string OP)(" ~ T.stringof ~ " color) if (OP==`+`)\n";
				s ~= "{\n";
				foreach (field; fields)
					s ~= "	"~field~" += color."~field~";\n";
				s ~= "}\n\n";

				s ~= T.stringof ~ " opBinary(string OP, T)(T divisor) if (OP==`/`)\n";
				s ~= "{\n";
				s ~= "	"~T.stringof~" color;\n";
				foreach (field; fields)
					s ~= "	color."~field~" = cast(typeof(color."~field~")) ("~field~" / divisor);\n";
				s ~= "	return color;\n";
				s ~= "}\n\n";

				return s;
			}

			//pragma(msg, mixFields());
			mixin(mixFields());
		}
	else
		static assert(0);
}

/// Recursively replace each type in T from FROM to TO.
template ReplaceType(T, FROM, TO)
{
	static if (is(T == FROM))
		alias TO ReplaceType;
	else
	static if (is(T==struct))
		struct ReplaceType
		{
			static string mixFields()
			{
				string s;
				foreach (field; structFields!T)
					s ~= "ReplaceType!(typeof(T.init." ~ field ~ "), FROM, TO) " ~ field ~ ";\n";
				return s;
			}

			//pragma(msg, mixFields());
			mixin(mixFields());
		}
	else
		static assert(0, "Can't replace " ~ T.stringof);
}

// *****************************************************************************

// TODO: type expansion?
T blend(T)(T f, T b, T a) { return cast(T) ( ((f*a) + (b*~a)) / T.max ); }

string[] structFields(T)()
{
	string[] fields;
	foreach (i, f; T.init.tupleof)
	{
		string field = T.tupleof[i].stringof;
		while (field[0] != '.')
			field = field[1..$];
		field = field[1..$];
		if (field != "x") // HACK
			fields ~= field;
	}
	return fields;
}

// *****************************************************************************

struct RefCanvas(COLOR)
{
	int w, h, stride;
	COLOR* pixels;

	mixin Canvas;
}

// *****************************************************************************

private
{
	// test intantiation
	struct TestCanvas(COLOR)
	{
		int w, h, stride;
		COLOR* pixels;
		mixin Canvas;
	}

	TestCanvas!RGB    testRGB;
	TestCanvas!RGBX   testRGBX;
	TestCanvas!RGBA   testRGBA;
	//TestCanvas!RGBX16 testRGBX16;
	//TestCanvas!RGBA16 testRGBA16;
	TestCanvas!GA     testGA;
	TestCanvas!GA16   testGA16;
}
