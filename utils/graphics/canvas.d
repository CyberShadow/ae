/**
 * Abstract drawing functions.
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

module ae.utils.graphics.canvas;

import std.exception;
import std.string;
import std.math;
import std.traits;
import std.conv : to; // safe numeric conversions

import ae.utils.meta;
public import ae.utils.math;

// TODO: rewrite everything to use stride in bytes, not pixels

struct Coord { int x, y; string toString() { return format("%s", [this.tupleof]); } }

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
	import std.string : format;

	// http://d.puremagic.com/issues/show_bug.cgi?id=7717
	//static assert(IsCanvas!(typeof(this)));

	alias typeof(pixels[0]) COLOR;

	ref COLOR opIndex(int x, int y)
	{
		assert(x>=0 && y>=0 && x<w && y<h);
		return pixels[y*stride+x];
	}

	COLOR opIndexAssign(COLOR value, int x, int y)
	{
		assert(x>=0 && y>=0 && x<w && y<h);
		return pixels[y*stride+x] = value;
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

	/// Draws an image. Returns this.
	typeof(this) draw(bool CHECKED=true, SRCCANVAS)(int x, int y, SRCCANVAS src)
		if (IsCanvas!SRCCANVAS && is(COLOR == SRCCANVAS.COLOR))
	{
		static if (CHECKED)
		{
			if (src.w == 0 || src.h == 0 ||
				x+src.w <= 0 || y+src.h <= 0 || x >= w || y >= h)
				return this;

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

			draw!false(x, y, r);
		}
		else
		{
			assert(src.w > 0 && src.h > 0);
			assert(x >= 0 && x+src.w <= w && y >= 0 && y+src.h <= h);

			// TODO: alpha blending
			size_t dstStart = y*stride+x, srcStart = 0;
			foreach (j; 0..src.h)
				pixels[dstStart..dstStart+src.w] = src.pixels[srcStart..srcStart+src.w],
				dstStart += stride,
				srcStart += src.stride;
		}

		return this;
	}

	/// Copy another canvas while applying a pixel transformation.
	/// Context of pred:
	///   c            = source color
	///   s            = destination color
	///   src          = source canvas
	///   extraArgs[n] = any extra arguments passed to transformDraw
	typeof(this) transformDraw(string pred, SRCCANVAS, T...)(int x, int y, ref SRCCANVAS src, T extraArgs)
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
				auto s = *dstPtr;
				*dstPtr++ = mixin(pred);
			}
			srcPtr += srcSlack;
			dstPtr += dstSlack;
		}
		return this;
	}

	void warp(string pred, SRCCANVAS, T...)(ref SRCCANVAS src, T extraArgs)
		if (IsCanvas!SRCCANVAS)
	{
		assert(src.w == w && src.h == h);
		foreach (y; 0..h)
			foreach (uint x, ref c; pixels[y*stride..y*stride+w])
			{
				mixin(pred);
			}
	}

	/// Nearest-neighbor upscale
	void upscaleDraw(int HRX, int HRY, SRCCANVAS)(ref SRCCANVAS src)
	{
		alias src  lr;
		alias this hr;

		assert(hr.w == lr.w*HRX && hr.h == lr.h*HRY, format("Size mismatch: (%d x %d) * (%d x %d) => (%d x %d)", lr.w, lr.h, HRX, HRY, hr.w, hr.h));

		foreach (y; 0..lr.h)
			foreach (x, c; lr.pixels[y*lr.w..(y+1)*lr.w])
				hr.fillRect(x*HRX, y*HRY, x*HRX+HRX, y*HRY+HRY, c);
	}

	/// Linear downscale
	void downscaleDraw(int HRX, int HRY, SRCCANVAS)(ref SRCCANVAS src)
	{
		alias this lr;
		alias src  hr;

		assert(hr.w == lr.w*HRX && hr.h == lr.h*HRY, format("Size mismatch: (%d x %d) * (%d x %d) <= (%d x %d)", lr.w, lr.h, HRX, HRY, hr.w, hr.h));

		foreach (y; 0..lr.h)
			foreach (x; 0..lr.w)
			{
				static if (HRX*HRY <= 0x100)
					enum EXPAND_BYTES = 1;
				else
				static if (HRX*HRY <= 0x10000)
					enum EXPAND_BYTES = 2;
				else
					static assert(0);
				static if (is(typeof(COLOR.init.a))) // downscale with alpha
				{
					ExpandType!(COLOR, EXPAND_BYTES+COLOR.init.a.sizeof) sum;
					ExpandType!(typeof(COLOR.init.a), EXPAND_BYTES) alphaSum;
					auto start = y*HRY*hr.stride + x*HRX;
					foreach (j; 0..HRY)
					{
						foreach (p; hr.pixels[start..start+HRX])
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
						result.a = cast(typeof(result.a))(alphaSum / (HRX*HRY));
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
					auto start = y*HRY*hr.stride + x*HRX;
					foreach (j; 0..HRY)
					{
						foreach (p; hr.pixels[start..start+HRX])
							sum += p;
						start += hr.stride;
					}
					lr[x, y] = cast(COLOR)(sum / (HRX*HRY));
				}
			}
	}

	/// Simple nearest-neighbor scale draw
	void scaleDraw(SRCCANVAS)(ref SRCCANVAS src)
	{
		foreach (y; 0..h)
			foreach (x; 0..w)
				this[x, y] = src[x * src.w / w, y * src.h / h];
	}

	/// Does not make a copy - only returns a "view" onto this canvas.
	auto window()(int x1, int y1, int x2, int y2)
	{
		assert(x1 >= 0 && y1 >= 0 && x2 <= w && y2 <= h && x1 <= x2 && y1 <= y2);

		return RefCanvas!COLOR(x2-x1, y2-y1, stride, pixelPtr(x1, y1));
	}

	/// Returns the smallest window containing all pixels that satisfy cond.
	/// Context of cond:
	///   c = color to test
	auto trim(string cond)()
	{
		int x0 = 0, y0 = 0, x1 = w, y1 = h;
	topLoop:
		while (y0 < y1)
		{
			foreach (x; 0..w)
			{
				auto c = this[x, y0];
				if (mixin(cond))
					break topLoop;
			}
			y0++;
		}
	bottomLoop:
		while (y1 > y0)
		{
			foreach (x; 0..w)
			{
				auto c = this[x, y1-1];
				if (mixin(cond))
					break bottomLoop;
			}
			y1--;
		}

	leftLoop:
		while (x0 < x1)
		{
			foreach (y; y0..y1)
			{
				auto c = this[x0, y];
				if (mixin(cond))
					break leftLoop;
			}
			x0++;
		}
	rightLoop:
		while (x1 > x0)
		{
			foreach (y; y0..y1)
			{
				auto c = this[x1-1, y];
				if (mixin(cond))
					break rightLoop;
			}
			x1--;
		}

		return window(x0, y0, x1, y1);
	}

	auto trimAlpha()()
	{
		return trim!`c.a`();
	}

	/// Construct a reference type pointing to the same data
	R getRef(R)()
	{
		R r;
		r.w = w;
		r.h = h;
		r.stride = stride;
		r.pixels = pixelPtr(0, 0);
		return r;
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
		int d  = cast(int)sqrt(cast(float)(sqr(dx)+sqr(dy)));
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
	alias SignedBitsType!(COLOR.BaseTypeBits   + CoordinateBits) fix;
	/// Type to hold temporary values for multiplication and division
	alias SignedBitsType!(COLOR.BaseTypeBits*2 + CoordinateBits) fix2;

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
	alias UnsignedBitsType!(COLOR.BaseTypeBits*2) frac2;

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

	// ************************************************************************************************************************************

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

	static if (is(COLOR == BGR))
		enum BitmapBitCount = 24;
	else
	static if (is(COLOR == BGRX) || is(COLOR == BGRA))
		enum BitmapBitCount = 32;
	else
	static if (is(COLOR == G8))
		enum BitmapBitCount = 8;
	else
		enum BitmapBitCount = 0;

	@property int bitmapPixelStride()
	{
		int pixelStride = w * cast(uint)COLOR.sizeof;
		pixelStride = (pixelStride+3) & ~3;
		return pixelStride;
	}

	void saveBMP()(string filename)
	{
		static if (COLOR.sizeof > 3)
			alias BitmapHeader!4 Header;
		else
			alias BitmapHeader!3 Header;

		auto bitmapDataSize = h*bitmapPixelStride;
		ubyte[] data = new ubyte[Header.sizeof + bitmapDataSize];
		auto header = cast(Header*)data.ptr;
		*header = Header.init;
		header.bfSize = to!uint(data.length);
		header.bfOffBits = Header.sizeof;
		header.bcWidth = w;
		header.bcHeight = -h;
		header.bcPlanes = 1;
		header.biSizeImage = bitmapDataSize;
		static assert(BitmapBitCount, "Unsupported BMP color type: " ~ COLOR.stringof);
		header.bcBitCount = BitmapBitCount;

		static if (header.VERSION >= 4)
		{
			header.biCompression = BI_BITFIELDS;

			COLOR c;
			foreach (i, f; c.tupleof)
			{
				enum CHAN = c.tupleof[i].stringof[2..$];
				enum MASK = (cast(uint)typeof(c.tupleof[i]).max) << (c.tupleof[i].offsetof*8);
				static if (CHAN=="r")
					header.bV4RedMask   |= MASK;
				else
				static if (CHAN=="g")
					header.bV4GreenMask |= MASK;
				else
				static if (CHAN=="b")
					header.bV4BlueMask  |= MASK;
				else
				static if (CHAN=="a")
					header.bV4AlphaMask |= MASK;
			}
		}

		auto pixelData = data[header.bfOffBits..$];
		auto pixelStride = bitmapPixelStride;
		auto ptr = pixelData.ptr;
		size_t pos = 0;

		foreach (y; 0..h)
		{
			(cast(COLOR*)ptr)[0..w] = pixels[y*stride..y*stride+w];
			ptr += pixelStride;
		}

		std.file.write(filename, data);
	}

	// ***********************************************************************

	void savePNG()(string filename)
	{
		import std.digest.crc;

		enum : ulong { SIGNATURE = 0x0a1a0a0d474e5089 }

		struct PNGChunk
		{
			char[4] type;
			const(void)[] data;

			uint crc32()
			{
				CRC32 crc;
				crc.put(cast(ubyte[])(type[]));
				crc.put(cast(ubyte[])data);
				ubyte[4] hash = crc.finish();
				return *cast(uint*)hash.ptr;
			}

			this(string type, const(void)[] data)
			{
				this.type[] = type[];
				this.data = data;
			}
		}

		enum PNGColourType : ubyte { G, RGB=2, PLTE, GA, RGBA=6 }
		enum PNGCompressionMethod : ubyte { DEFLATE }
		enum PNGFilterMethod : ubyte { ADAPTIVE }
		enum PNGInterlaceMethod : ubyte { NONE, ADAM7 }

		enum PNGFilterAdaptive : ubyte { NONE, SUB, UP, AVERAGE, PAETH }

		align(1)
		struct PNGHeader
		{
		align(1):
			uint width, height;
			ubyte colourDepth;
			PNGColourType colourType;
			PNGCompressionMethod compressionMethod;
			PNGFilterMethod filterMethod;
			PNGInterlaceMethod interlaceMethod;
			static assert(PNGHeader.sizeof == 13);
		}

		alias ChannelType!COLOR CHANNEL_TYPE;

		static if (StructFields!COLOR == ["g"])
			enum COLOUR_TYPE = PNGColourType.G;
		else
		static if (StructFields!COLOR == ["r","g","b"])
			enum COLOUR_TYPE = PNGColourType.RGB;
		else
		static if (StructFields!COLOR == ["g","a"])
			enum COLOUR_TYPE = PNGColourType.GA;
		else
		static if (StructFields!COLOR == ["r","g","b","a"])
			enum COLOUR_TYPE = PNGColourType.RGBA;
		else
			static assert(0, "Unsupported PNG color type: " ~ COLOR.stringof);

		PNGChunk[] chunks;
		PNGHeader header = {
			width : swapBytes(w),
			height : swapBytes(h),
			colourDepth : CHANNEL_TYPE.sizeof * 8,
			colourType : COLOUR_TYPE,
			compressionMethod : PNGCompressionMethod.DEFLATE,
			filterMethod : PNGFilterMethod.ADAPTIVE,
			interlaceMethod : PNGInterlaceMethod.NONE,
		};
		chunks ~= PNGChunk("IHDR", cast(void[])[header]);
		uint idatStride = w*COLOR.sizeof+1;
		ubyte[] idatData = new ubyte[h*idatStride];
		for (uint y=0; y<h; y++)
		{
			idatData[y*idatStride] = PNGFilterAdaptive.NONE;
			auto rowPixels = cast(COLOR[])idatData[y*idatStride+1..(y+1)*idatStride];
			rowPixels[] = pixels[y*stride..(y+1)*stride];

			static if (CHANNEL_TYPE.sizeof > 1)
				foreach (ref p; cast(CHANNEL_TYPE[])rowPixels)
					p = swapBytes(p);
		}
		chunks ~= PNGChunk("IDAT", compress(idatData, 5));
		chunks ~= PNGChunk("IEND", null);

		uint totalSize = 8;
		foreach (chunk; chunks)
			totalSize += 8 + chunk.data.length + 4;
		ubyte[] data = new ubyte[totalSize];

		*cast(ulong*)data.ptr = SIGNATURE;
		uint pos = 8;
		foreach(chunk;chunks)
		{
			uint i = pos;
			uint chunkLength = chunk.data.length;
			pos += 12 + chunkLength;
			*cast(uint*)&data[i] = swapBytes(chunkLength);
			(cast(char[])data[i+4 .. i+8])[] = chunk.type[];
			data[i+8 .. i+8+chunk.data.length] = (cast(ubyte[])chunk.data)[];
			*cast(uint*)&data[i+8+chunk.data.length] = swapBytes(chunk.crc32());
			assert(pos == i+12+chunk.data.length);
		}
		std.file.write(filename, data);
	}
}

private bool isSameType(T)()
{
	foreach (i, f; T.init.tupleof)
		if (!is(typeof(T.init.tupleof[i]) == typeof(T.init.tupleof[0])))
			return false;
	return true;
}

struct Color(FieldTuple...)
{
	struct Fields { mixin FieldList!FieldTuple; } // for iteration

	// alias this bugs out with operator overloading, so just paste the fields here
	mixin FieldList!FieldTuple;

	/// Whether or not all channel fields have the same base type.
	// Only "true" supported for now, may change in the future (e.g. for 5:6:5)
	enum SameType = isSameType!Fields();

	enum Components = Fields.init.tupleof.length;

	static if (SameType)
	{
		alias typeof(Fields.init.tupleof[0]) BaseType;
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

	/// Interpolate between two colors.
	static typeof(this) itpl(P)(typeof(this) c0, typeof(this) c1, P p, P p0, P p1)
	{
		alias UnsignedBitsType!(BaseTypeBits + P.sizeof*8) U;
		alias Signed!U S;
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if (r.tupleof[i].stringof != "r.x") // skip padding
				r.tupleof[i] = cast(BaseType).itpl(cast(U)c0.tupleof[i], cast(U)c1.tupleof[i], cast(S)p, cast(S)p0, cast(S)p1);
		return r;
	}

	/// Construct an RGB color from a typical hex string.
	static if (is(typeof(this.r) == ubyte) && is(typeof(this.g) == ubyte) && is(typeof(this.b) == ubyte))
	static typeof(this) fromHex(in char[] s)
	{
		enforce(s.length == 6, "Invalid color string");
		typeof(this) c;
		c.r = s[0..2].to!ubyte(16);
		c.g = s[2..4].to!ubyte(16);
		c.b = s[4..6].to!ubyte(16);
		return c;
	}

	/// Warning: overloaded operators preserve types and may cause overflows
	typeof(this) opUnary(string op)()
		if (op=="~" || op=="-")
	{
		typeof(this) r;
		foreach (i, f; r.tupleof)
			static if(r.tupleof[i].stringof != "r.x") // skip padding
				r.tupleof[i] = cast(typeof(r.tupleof[i])) mixin(op ~ `this.tupleof[i]`);
		return r;
	}

	/// ditto
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

	/// Sum of all channels
	UnsignedBitsType!(BaseTypeBits + ilog2(nextPowerOfTwo(Components))) sum()
	{
		typeof(return) result;
		foreach (i, f; this.tupleof)
			static if (this.tupleof[i].stringof != "this.x") // skip padding
				result += this.tupleof[i];
		return result;
	}
}

// The "x" has the special meaning of "padding" and is ignored in some circumstances
alias Color!(ubyte  , "r", "g", "b"     ) RGB    ;
alias Color!(ushort , "r", "g", "b"     ) RGB16  ;
alias Color!(ubyte  , "r", "g", "b", "x") RGBX   ;
alias Color!(ushort , "r", "g", "b", "x") RGBX16 ;
alias Color!(ubyte  , "r", "g", "b", "a") RGBA   ;
alias Color!(ushort , "r", "g", "b", "a") RGBA16 ;

alias Color!(ubyte  , "b", "g", "r"     ) BGR    ;
alias Color!(ubyte  , "b", "g", "r", "x") BGRX   ;
alias Color!(ubyte  , "b", "g", "r", "a") BGRA   ;

alias Color!(ubyte  , "g"               ) G8     ;
alias Color!(ushort , "g"               ) G16    ;
alias Color!(ubyte  , "g", "a"          ) GA     ;
alias Color!(ushort , "g", "a"          ) GA16   ;

alias Color!(byte   , "g"               ) S8     ;
alias Color!(short  , "g"               ) S16    ;

private
{
	static assert(RGB.sizeof == 3);
	RGB[2] test;
	static assert(test.sizeof == 6);
}

unittest
{
	RGB a = RGB.fromHex("123456");
	assert(a.r == 0x12 && a.g == 0x34 && a.b == 0x56);
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
				enum fields = StructFields!T;

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
				foreach (field; StructFields!T)
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

/// Evaluates to array of strings with name for each field.
template StructFields(T)
{
	string[] structFields()
	{
		string[] fields;
		foreach (i, f; T.init.tupleof)
		{
			string field = T.tupleof[i].stringof;
			field = field.split(".")[$-1];
			if (field != "x") // HACK
				fields ~= field;
		}
		return fields;
	}

	enum StructFields = structFields();
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
	// test instantiation
	RefCanvas!RGB    testRGB;
	RefCanvas!RGBX   testRGBX;
	RefCanvas!RGBA   testRGBA;
	//RefCanvas!RGBX16 testRGBX16;
	//RefCanvas!RGBA16 testRGBA16;
	RefCanvas!GA     testGA;
	RefCanvas!GA16   testGA16;

	static assert(IsCanvas!(RefCanvas!RGB));
}
