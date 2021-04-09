/**
 * Drawing functions.
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

module ae.utils.graphics.draw;

import std.algorithm : sort;
import std.traits;

import ae.utils.geometry : TAU;
import ae.utils.graphics.view;
import ae.utils.graphics.color : solidStorageUnit;
import ae.utils.math;
import ae.utils.meta : structFields, SignedBitsType, UnsignedBitsType;

version(unittest) import ae.utils.graphics.image;

// Constraints could be simpler if this was fixed:
// https://issues.dlang.org/show_bug.cgi?id=12386

/// Get the pixel color at the specified coordinates,
/// or fall back to the specified default value if
/// the coordinates are out of bounds.
COLOR safeGet(V, COLOR)(auto ref V v, xy_t x, xy_t y, COLOR def)
	if (isView!V && is(COLOR : ViewColor!V))
{
	if (x>=0 && y>=0 && x<v.w && y<v.h)
		return v[x, y];
	else
		return def;
}

unittest
{
	auto v = onePixel(7);
	assert(v.safeGet(0, 0, 0) == 7);
	assert(v.safeGet(0, 1, 0) == 0);
}

/// Set the pixel color at the specified coordinates
/// if the coordinates are not out of bounds.
void safePut(V, COLOR)(auto ref V v, xy_t x, xy_t y, COLOR value)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	if (x>=0 && y>=0 && x<v.w && y<v.h)
		v[x, y] = value;
}

unittest
{
	auto v = Image!int(1, 1);
	v.safePut(0, 0, 7);
	v.safePut(0, 1, 9);
	assert(v[0, 0] == 7);
}

/// Forwards to safePut or opIndex, depending on the
/// CHECKED parameter. Allows propagation of a
/// CHECKED parameter from other callers.
void putPixel(bool CHECKED, V, COLOR)(auto ref V v, xy_t x, xy_t y, COLOR value)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	static if (CHECKED)
		v.safePut(x, y, value);
	else
		v[x, y] = value;
}

unittest
{
	auto v = Image!int(1, 1);
	v.putPixel!false(0, 0, 7);
	v.putPixel!true(0, 1, 9);
	assert(v[0, 0] == 7);
}

/// Gets a pixel's address from a direct view.
ViewColor!V* pixelPtr(V)(auto ref V v, xy_t x, xy_t y)
if (isDirectView!V && is(typeof(&v.scanline(0)[0][0])))
{
	return &v.scanline(y)[x][0];
}

unittest
{
	auto v = Image!xy_t(1, 1);
	v[0, 0] = 7;
	auto p = v.pixelPtr(0, 0);
	assert(*p == 7);
}

/// Fills a writable view with a solid color.
void fill(V, COLOR)(auto ref V v, COLOR c)
	if (isWritableView!V
	 && is(COLOR : ViewColor!V))
{
	static if (isDirectView!V)
	{
		auto s = solidStorageUnit!(ViewStorageType!V)(c);
		foreach (y; 0..v.h)
			v.scanline(y)[] = s;
	}
	else
	{
		foreach (y; 0..v.h)
			foreach (x; 0..v.w)
				v[x, y] = c;
	}
}
deprecated alias clear = fill;

unittest
{
	auto i = onePixel(0).copy();
	i.fill(1);
	assert(i[0, 0] == 1);
	auto t = i.tile(10, 10);
	t.fill(2);
	assert(i[0, 0] == 2);
}

// ***************************************************************************

private enum CheckHLine =
q{
	static if (CHECKED)
	{
		if (x1 >= v.w || x2 <= 0 || y < 0 || y >= v.h || x1 >= x2) return;
		if (x1 <    0) x1 =   0;
		if (x2 >= v.w) x2 = v.w;
	}
	assert(x1 <= x2);
};

private enum CheckVLine =
q{
	static if (CHECKED)
	{
		if (x < 0 || x >= v.w || y1 >= v.h || y2 <= 0 || y1 >= y2) return;
		if (y1 <    0) y1 =   0;
		if (y2 >= v.h) y2 = v.h;
	}
	assert(y1 <= y2);
};

/// Draw a horizontal line.
void hline(bool CHECKED=true, V, COLOR)(auto ref V v, xy_t x1, xy_t x2, xy_t y, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	mixin(CheckHLine);
	static if (isDirectView!V && ViewStorageType!V.length == 1)
	{
		auto s = solidStorageUnit!(ViewStorageType!V)(c);
		v.scanline(y)[x1..x2] = s;
	}
	else
		foreach (x; x1..x2)
			v[x, y] = c;
}

/// Draw a vertical line.
void vline(bool CHECKED=true, V, COLOR)(auto ref V v, xy_t x, xy_t y1, xy_t y2, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	mixin(CheckVLine);
	foreach (y; y1..y2) // TODO: optimize
		v[x, y] = c;
}

/// Draw a line.
void line(bool CHECKED=true, V, COLOR)(auto ref V v, xy_t x1, xy_t y1, xy_t x2, xy_t y2, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	mixin FixMath;
	import std.algorithm.mutation : swap;

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
		assert(b0 < (1L<<coordinateBits) && b1 < (1L<<coordinateBits));
		auto bPos = cast(SignedBitsType!(coordinateBits*2))(b0 << coordinateBits);
		auto bOff = cast(SignedBitsType!(coordinateBits*2))(((b1-b0) << coordinateBits) / (a1-a0));

		foreach (a; a0..a1+1)
		{
			xy_t b = (bPos += bOff) >> coordinateBits;
			mixin(DrawPixel);
		}
	};

	import std.math : abs;

	if (abs(x2-x1) > abs(y2-y1))
	{
		alias x1 a0;
		alias x2 a1;
		alias y1 b0;
		alias y2 b1;
		enum DrawPixel = q{ v.putPixel!CHECKED(a, b, c); };
		mixin(DrawLine);
	}
	else
	{
		alias y1 a0;
		alias y2 a1;
		alias x1 b0;
		alias x2 b1;
		enum DrawPixel = q{ v.putPixel!CHECKED(b, a, c); };
		mixin(DrawLine);
	}
}

/// Draws a rectangle with a solid line.
/// The coordinates represent bounds (open on the right) for the outside of the rectangle.
void rect(bool CHECKED=true, V, COLOR)(auto ref V v, xy_t x1, xy_t y1, xy_t x2, xy_t y2, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	sort2(x1, x2);
	sort2(y1, y2);
	v.hline!CHECKED(x1, x2, y1  , c);
	v.hline!CHECKED(x1, x2, y2-1, c);
	v.vline!CHECKED(x1  , y1, y2, c);
	v.vline!CHECKED(x2-1, y1, y2, c);
}

/// Draw a filled rectangle.
void fillRect(bool CHECKED=true, V, COLOR)(auto ref V v, xy_t x1, xy_t y1, xy_t x2, xy_t y2, COLOR b) // [)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	sort2(x1, x2);
	sort2(y1, y2);
	static if (CHECKED)
	{
		if (x1 >= v.w || y1 >= v.h || x2 <= 0 || y2 <= 0 || x1==x2 || y1==y2) return;
		if (x1 <    0) x1 =   0;
		if (y1 <    0) y1 =   0;
		if (x2 >= v.w) x2 = v.w;
		if (y2 >= v.h) y2 = v.h;
	}
	foreach (y; y1..y2)
		v.hline!false(x1, x2, y, b);
}

/// Draw a filled rectangle with an outline.
void fillRect(bool CHECKED=true, V, COLOR)(auto ref V v, xy_t x1, xy_t y1, xy_t x2, xy_t y2, COLOR c, COLOR b) // [)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	v.rect!CHECKED(x1, y1, x2, y2, c);
	if (x2-x1>2 && y2-y1>2)
		v.fillRect!CHECKED(x1+1, y1+1, x2-1, y2-1, b);
}

/// Recursively replace the color of all adjacent pixels of the same color,
/// starting with the given coordinates.
/// Unchecked! Make sure area is bounded.
void uncheckedFloodFill(V, COLOR)(auto ref V v, xy_t x, xy_t y, COLOR c)
	if (isDirectView!V && is(COLOR : ViewColor!V))
{
	v.floodFillPtr(&v[x, y], c, v[x, y]);
}

private void floodFillPtr(V, COLOR)(auto ref V v, COLOR* pp, COLOR c, COLOR f)
	if (isDirectView!V && is(COLOR : ViewColor!V))
{
	COLOR* p0 = pp; while (*p0==f) p0--; p0++;
	COLOR* p1 = pp; while (*p1==f) p1++; p1--;
	auto stride = v.scanline(1).ptr-v.scanline(0).ptr;
	for (auto p=p0; p<=p1; p++)
		*p = c;
	p0 -= stride; p1 -= stride;
	for (auto p=p0; p<=p1; p++)
		if (*p == f)
			v.floodFillPtr(p, c, f);
	p0 += stride*2; p1 += stride*2;
	for (auto p=p0; p<=p1; p++)
		if (*p == f)
			v.floodFillPtr(p, c, f);
}

/// Draw a filled circle.
void fillCircle(V, COLOR)(auto ref V v, xy_t x, xy_t y, xy_t r, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	import std.algorithm.comparison : min;

	xy_t x0 = x>r?x-r:0;
	xy_t y0 = y>r?y-r:0;
	xy_t x1 = min(x+r, v.w-1);
	xy_t y1 = min(y+r, v.h-1);
	xy_t rs = sqr(r);
	// TODO: optimize
	foreach (py; y0..y1+1)
		foreach (px; x0..x1+1)
			if (sqr(x-px) + sqr(y-py) < rs)
				v[px, py] = c;
}

/// Draw a filled sector (circle slice).
void fillSector(V, COLOR)(auto ref V v, xy_t x, xy_t y, xy_t r0, xy_t r1, real a0, real a1, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	import std.algorithm.comparison : min;
	import std.math : atan2;

	xy_t x0 = x>r1?x-r1:0;
	xy_t y0 = y>r1?y-r1:0;
	xy_t x1 = min(x+r1, v.w-1);
	xy_t y1 = min(y+r1, v.h-1);
	xy_t r0s = sqr(r0);
	xy_t r1s = sqr(r1);
	if (a0 > a1)
		a1 += TAU;
	foreach (py; y0..y1+1)
		foreach (px; x0..x1+1)
		{
			xy_t dx = px-x;
			xy_t dy = py-y;
			xy_t rs = sqr(dx) + sqr(dy);
			if (r0s <= rs && rs < r1s)
			{
				real a = atan2(cast(real)dy, cast(real)dx);
				if ((a0 <= a     && a     <= a1) ||
				    (a0 <= a+TAU && a+TAU <= a1))
					v[px, py] = c;
			}
		}
}

/// Polygon point definition.
struct Coord
{
	///
	xy_t x, y;
	string toString() { import std.string; return format("%s", [this.tupleof]); } ///
}

/// Draw a filled polygon with a variable number of points.
void fillPoly(V, COLOR)(auto ref V v, Coord[] coords, COLOR f)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	import std.algorithm.comparison : min, max;

	xy_t minY, maxY;
	minY = maxY = coords[0].y;
	foreach (c; coords[1..$])
		minY = min(minY, c.y),
		maxY = max(maxY, c.y);

	foreach (y; minY..maxY+1)
	{
		xy_t[] intersections;
		for (uint i=0; i<coords.length; i++)
		{
			auto c0=coords[i], c1=coords[i==$-1?0:i+1];
			if (y==c0.y)
			{
				assert(y == coords[i%$].y);
				int pi = i-1; xy_t py;
				while ((py=coords[(pi+$)%$].y)==y)
					pi--;
				int ni = i+1; xy_t ny;
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
		intersections.sort();
		for (uint i=0; i<intersections.length; i+=2)
			v.hline!true(intersections[i], intersections[i+1], y, f);
	}
}

/// Draw a line of a given thickness.
/// Does not draw caps.
void thickLine(V, COLOR)(auto ref V v, xy_t x1, xy_t y1, xy_t x2, xy_t y2, xy_t r, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	xy_t dx = x2-x1;
	xy_t dy = y2-y1;
	xy_t d  = cast(xy_t)sqrt(cast(float)(sqr(dx)+sqr(dy)));
	if (d==0) return;

	xy_t nx = dx*r/d;
	xy_t ny = dy*r/d;

	fillPoly([
		Coord(x1-ny, y1+nx),
		Coord(x1+ny, y1-nx),
		Coord(x2+ny, y2-nx),
		Coord(x2-ny, y2+nx),
	], c);
}

/// Draw a polygon of a given thickness.
/// Does not draw caps.
void thickLinePoly(V, COLOR)(auto ref V v, Coord[] coords, xy_t r, COLOR c)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	foreach (i; 0..coords.length)
		thickLine(coords[i].tupleof, coords[(i+1)%$].tupleof, r, c);
}

// ************************************************************************************************************************************

private mixin template FixMath(ubyte coordinateBitsParam = 16)
{
	import ae.utils.meta : SignedBitsType, UnsignedBitsType;

	enum coordinateBits = coordinateBitsParam;

	static assert(COLOR.homogeneous, "Asymmetric color types not supported, fix me!");
	/// Fixed-point type, big enough to hold a coordinate, with fractionary precision corresponding to channel precision.
	alias fix  = SignedBitsType!(COLOR.channelBits   + coordinateBits);
	/// Type to hold temporary values for multiplication and division
	alias fix2 = SignedBitsType!(COLOR.channelBits*2 + coordinateBits);

	static assert(COLOR.channelBits < 32, "Shift operators are broken for shifts over 32 bits, fix me!");
	fix tofix(T:int  )(T x) { return cast(fix) (x<<COLOR.channelBits); }
	fix tofix(T:float)(T x) { return cast(fix) (x*(1<<COLOR.channelBits)); }
	T fixto(T:int)(fix x) { return cast(T)(x>>COLOR.channelBits); }

	fix fixsqr(fix x)        { return cast(fix)((cast(fix2)x*x) >> COLOR.channelBits); }
	fix fixmul(fix x, fix y) { return cast(fix)((cast(fix2)x*y) >> COLOR.channelBits); }
	fix fixdiv(fix x, fix y) { return cast(fix)((cast(fix2)x << COLOR.channelBits)/y); }

	static assert(COLOR.ChannelType.sizeof*8 == COLOR.channelBits, "COLORs with ChannelType not corresponding to native type not currently supported, fix me!");
	/// Type only large enough to hold a fractionary part of a "fix" (i.e. color channel precision). Used for alpha values, etc.
	alias COLOR.ChannelType frac;
	/// Type to hold temporary values for multiplication and division
	alias UnsignedBitsType!(COLOR.channelBits*2) frac2;

	frac tofrac(T:float)(T x) { return cast(frac) (x*(1<<COLOR.channelBits)); }
	frac fixfpart(fix x) { return cast(frac)x; }
	frac fracsqr(frac x        ) { return cast(frac)((cast(frac2)x*x) >> COLOR.channelBits); }
	frac fracmul(frac x, frac y) { return cast(frac)((cast(frac2)x*y) >> COLOR.channelBits); }

	frac tofracBounded(T:float)(T x) { return cast(frac) bound(tofix(x), 0, frac.max); }
}

// ************************************************************************************************************************************

/// Fill `v` with white noise.
void whiteNoise(V)(V v)
	if (isWritableView!V)
{
	import std.random;
	alias COLOR = ViewColor!V;

	for (xy_t y=0;y<v.h/2;y++)
		for (xy_t x=0;x<v.w/2;x++)
			v[x*2, y*2] = COLOR.monochrome(uniform!(COLOR.ChannelType)());

	// interpolate
	enum AVERAGE = q{(a+b)/2};

	for (xy_t y=0;y<v.h/2;y++)
		for (xy_t x=0;x<v.w/2-1;x++)
			v[x*2+1, y*2  ] = COLOR.op!AVERAGE(v[x*2  , y*2], v[x*2+2, y*2  ]);
	for (xy_t y=0;y<v.h/2-1;y++)
		for (xy_t x=0;x<v.w/2;x++)
			v[x*2  , y*2+1] = COLOR.op!AVERAGE(v[x*2  , y*2], v[x*2  , y*2+2]);
	for (xy_t y=0;y<v.h/2-1;y++)
		for (xy_t x=0;x<v.w/2-1;x++)
			v[x*2+1, y*2+1] = COLOR.op!AVERAGE(v[x*2+1, y*2], v[x*2+2, y*2+2]);
}

private template softRoundShape(bool RING)
{
	void softRoundShape(T, V, COLOR)(auto ref V v, T x, T y, T r0, T r1, T r2, COLOR color)
		if (isWritableView!V && isNumeric!T && is(COLOR : ViewColor!V))
	{
		mixin FixMath;

		assert(r0 <= r1);
		assert(r1 <= r2);
		assert(r2 < 256); // precision constraint - see SqrType
		//xy_t ix = cast(xy_t)x;
		//xy_t iy = cast(xy_t)y;
		//xy_t ir1 = cast(xy_t)sqr(r1-1);
		//xy_t ir2 = cast(xy_t)sqr(r2+1);
		xy_t x1 = cast(xy_t)(x-r2-1); if (x1<0) x1=0;
		xy_t y1 = cast(xy_t)(y-r2-1); if (y1<0) y1=0;
		xy_t x2 = cast(xy_t)(x+r2+1); if (x2>v.w) x2 = v.w;
		xy_t y2 = cast(xy_t)(y+r2+1); if (y2>v.h) y2 = v.h;

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

		for (xy_t cy=y1;cy<y2;cy++)
		{
			auto row = v[cy];
			for (xy_t cx=x1;cx<x2;cx++)
			{
				alias SignedBitsType!(2*(8 + COLOR.channelBits)) SqrType; // fit the square of radius expressed as fixed-point
				fix frs = cast(fix)((sqr(cast(SqrType)fx-tofix(cx)) + sqr(cast(SqrType)fy-tofix(cy))) >> COLOR.channelBits); // shift-right only once instead of once-per-sqr

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
							alpha = alphafunc(cast(frac)fixdiv(frs-fr0s, fr10));
						else
							alpha = alphafunc(cast(frac)fixdiv(frs-fr1s, fr21)).flipBits;
						row[cx] = COLOR.op!q{.blend(a, b, c)}(color, row[cx], alpha);
					}
				}
				else
				{
					if (frs<fr1s)
						row[cx] = color;
					else
					if (frs<fr2s)
					{
						frac alpha = alphafunc(cast(frac)fixdiv(frs-fr1s, fr21)).flipBits;
						row[cx] = COLOR.op!q{.blend(a, b, c)}(color, row[cx], alpha);
					}
				}
			}
		}
	}
}

/// Draw a circle using a smooth interpolated line.
void softRing(T, V, COLOR)(auto ref V v, T x, T y, T r0, T r1, T r2, COLOR color)
	if (isWritableView!V && isNumeric!T && is(COLOR : ViewColor!V))
{
	v.softRoundShape!true(x, y, r0, r1, r2, color);
}

/// ditto
void softCircle(T, V, COLOR)(auto ref V v, T x, T y, T r1, T r2, COLOR color)
	if (isWritableView!V && isNumeric!T && is(COLOR : ViewColor!V))
{
	v.softRoundShape!false(x, y, cast(T)0, r1, r2, color);
}

/// Draw a 1x1 rectangle at fractional coordinates.
/// Affects up to 4 pixels in the image.
template aaPutPixel(bool CHECKED=true, bool USE_ALPHA=true)
{
	void aaPutPixel(F:float, V, COLOR, frac)(auto ref V v, F x, F y, COLOR color, frac alpha)
		if (isWritableView!V && is(COLOR : ViewColor!V))
	{
		mixin FixMath;

		void plot(bool CHECKED2)(xy_t x, xy_t y, frac f)
		{
			static if (CHECKED2)
				if (x<0 || x>=v.w || y<0 || y>=v.h)
					return;

			COLOR* p = v.pixelPtr(x, y);
			static if (USE_ALPHA) f = fracmul(f, cast(frac)alpha);
			*p = COLOR.op!q{.blend(a, b, c)}(color, *p, f);
		}

		fix fx = tofix(x);
		fix fy = tofix(y);
		int ix = fixto!int(fx);
		int iy = fixto!int(fy);
		static if (CHECKED)
			if (ix>=0 && iy>=0 && ix+1<v.w && iy+1<v.h)
			{
				plot!false(ix  , iy  , fracmul(fixfpart(fx).flipBits, fixfpart(fy).flipBits));
				plot!false(ix  , iy+1, fracmul(fixfpart(fx).flipBits, fixfpart(fy)         ));
				plot!false(ix+1, iy  , fracmul(fixfpart(fx)         , fixfpart(fy).flipBits));
				plot!false(ix+1, iy+1, fracmul(fixfpart(fx)         , fixfpart(fy)         ));
				return;
			}
		plot!CHECKED(ix  , iy  , fracmul(fixfpart(fx).flipBits, fixfpart(fy).flipBits));
		plot!CHECKED(ix  , iy+1, fracmul(fixfpart(fx).flipBits, fixfpart(fy)         ));
		plot!CHECKED(ix+1, iy  , fracmul(fixfpart(fx)         , fixfpart(fy).flipBits));
		plot!CHECKED(ix+1, iy+1, fracmul(fixfpart(fx)         , fixfpart(fy)         ));
	}
}

/// ditto
void aaPutPixel(bool CHECKED=true, F:float, V, COLOR)(auto ref V v, F x, F y, COLOR color)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	//aaPutPixel!(false, F)(x, y, color, 0); // doesn't work, wtf
	alias aaPutPixel!(CHECKED, false) f;
	f(v, x, y, color, 0);
}

/// Draw a horizontal line
void hline(bool CHECKED=true, V, COLOR, frac)(auto ref V v, xy_t x1, xy_t x2, xy_t y, COLOR color, frac alpha)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	mixin(CheckHLine);

	if (alpha==0)
		return;
	else
	if (alpha==frac.max)
		.hline!CHECKED(v, x1, x2, y, color);
	else
		foreach (ref s; v.scanline(y)[x1..x2])
			foreach (ref p; s)
				p = COLOR.op!q{.blend(a, b, c)}(color, p, alpha);
}

/// Draw a vertical line
void vline(bool CHECKED=true, V, COLOR, frac)(auto ref V v, xy_t x, xy_t y1, xy_t y2, COLOR color, frac alpha)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	mixin(CheckVLine);

	if (alpha==0)
		return;
	else
	if (alpha==frac.max)
		foreach (y; y1..y2)
			v[x, y] = color;
	else
		foreach (y; y1..y2)
		{
			auto p = v.pixelPtr(x, y);
			*p = COLOR.op!q{.blend(a, b, c)}(color, *p, alpha);
		}
}

/// Draw a filled rectangle at fractional coordinates.
/// Edges are anti-aliased.
void aaFillRect(bool CHECKED=true, F:float, V, COLOR)(auto ref V v, F x1, F y1, F x2, F y2, COLOR color)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	mixin FixMath;

	sort2(x1, x2);
	sort2(y1, y2);
	fix x1f = tofix(x1); int x1i = fixto!int(x1f);
	fix y1f = tofix(y1); int y1i = fixto!int(y1f);
	fix x2f = tofix(x2); int x2i = fixto!int(x2f);
	fix y2f = tofix(y2); int y2i = fixto!int(y2f);

	v.vline!CHECKED(x1i, y1i+1, y2i, color, fixfpart(x1f).flipBits);
	v.vline!CHECKED(x2i, y1i+1, y2i, color, fixfpart(x2f)         );
	v.hline!CHECKED(x1i+1, x2i, y1i, color, fixfpart(y1f).flipBits);
	v.hline!CHECKED(x1i+1, x2i, y2i, color, fixfpart(y2f)         );
	v.aaPutPixel!CHECKED(x1i, y1i, color, fracmul(fixfpart(x1f).flipBits, fixfpart(y1f).flipBits));
	v.aaPutPixel!CHECKED(x1i, y2i, color, fracmul(fixfpart(x1f).flipBits, fixfpart(y2f)         ));
	v.aaPutPixel!CHECKED(x2i, y1i, color, fracmul(fixfpart(x2f)         , fixfpart(y1f).flipBits));
	v.aaPutPixel!CHECKED(x2i, y2i, color, fracmul(fixfpart(x2f)         , fixfpart(y2f)         ));

	v.fillRect!CHECKED(x1i+1, y1i+1, x2i, y2i, color);
}

/// Draw an anti-aliased line.
void aaLine(bool CHECKED=true, V, COLOR)(auto ref V v, float x1, float y1, float x2, float y2, COLOR color)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	import std.math : abs;

	// Simplistic straight-forward implementation. TODO: optimize
	if (abs(x1-x2) > abs(y1-y2))
		for (auto x=x1; sign(x1-x2)!=sign(x2-x); x += sign(x2-x1))
			v.aaPutPixel!CHECKED(x, itpl(y1, y2, x, x1, x2), color);
	else
		for (auto y=y1; sign(y1-y2)!=sign(y2-y); y += sign(y2-y1))
			v.aaPutPixel!CHECKED(itpl(x1, x2, y, y1, y2), y, color);
}

/// ditto
void aaLine(bool CHECKED=true, V, COLOR, frac)(auto ref V v, float x1, float y1, float x2, float y2, COLOR color, frac alpha)
	if (isWritableView!V && is(COLOR : ViewColor!V))
{
	import std.math : abs;

	// ditto
	if (abs(x1-x2) > abs(y1-y2))
		for (auto x=x1; sign(x1-x2)!=sign(x2-x); x += sign(x2-x1))
			v.aaPutPixel!CHECKED(x, itpl(y1, y2, x, x1, x2), color, alpha);
	else
		for (auto y=y1; sign(y1-y2)!=sign(y2-y); y += sign(y2-y1))
			v.aaPutPixel!CHECKED(itpl(x1, x2, y, y1, y2), y, color, alpha);
}

unittest
{
	// Test instantiation
	import ae.utils.graphics.color;
	auto i = Image!RGB(100, 100);
	auto c = RGB(1, 2, 3);
	i.whiteNoise();
	i.aaLine(10, 10, 20, 20, c);
	i.aaLine(10f, 10f, 20f, 20f, c, 100);
	i.rect(10, 10, 20, 20, c);
	i.fillRect(10, 10, 20, 20, c);
	i.aaFillRect(10, 10, 20, 20, c);
	i.vline(10, 10, 20, c);
	i.vline(10, 10, 20, c);
	i.line(10, 10, 20, 20, c);
	i.fillCircle(10, 10, 10, c);
	i.fillSector(10, 10, 10, 10, 0.0, TAU, c);
	i.softRing(50, 50, 10, 15, 20, c);
	i.softCircle(50, 50, 10, 15, c);
	i.fillPoly([Coord(10, 10), Coord(10, 20), Coord(20, 20)], c);
	i.uncheckedFloodFill(15, 15, RGB(4, 5, 6));
}

// ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

// Outdated code from before the overhaul.
// TODO: fix and update

version(none):

/// Draws an image. Returns this.
typeof(this) draw(bool CHECKED=true, SRCCANVAS)(xy_t x, xy_t y, SRCCANVAS v)
	if (IsCanvas!SRCCANVAS && is(COLOR == SRCCANVAS.COLOR))
{
	static if (CHECKED)
	{
		if (v.w == 0 || v.h == 0 ||
			x+v.w <= 0 || y+v.h <= 0 || x >= w || y >= h)
			return this;

		auto r = v.window(0, 0, v.w, v.h);
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
		assert(v.w > 0 && v.h > 0);
		assert(x >= 0 && x+v.w <= w && y >= 0 && y+v.h <= h);

		// TODO: alpha blending
		size_t dstStart = y*stride+x, srcStart = 0;
		foreach (j; 0..v.h)
			pixels[dstStart..dstStart+v.w] = v.pixels[srcStart..srcStart+v.w],
			dstStart += stride,
			srcStart += v.stride;
	}

	return this;
}

/// Downscale an image minding subpixel positioning on LCD screens.
void subpixelDownscale()()
	if (structFields!COLOR == ["r","g","b"] || structFields!COLOR == ["b","g","r"])
{
	Image!COLOR i;
	i.size(HRX + hr.w*3 + HRX, hr.h);
	i.draw(0, 0, hr.window(0, 0, HRX, hr.h));
	i.window(HRX, 0, HRX+hr.w*3, hr.h).upscaleDraw!(3, 1)(hr);
	i.draw(HRX + hr.w*3, 0, hr.window(hr.w-HRX, 0, hr.w, hr.h));
	alias Color!(COLOR.BaseType, "g") BASE;
	Image!BASE[3] channels;
	Image!BASE scratch;
	scratch.size(hr.w*3, hr.h);

	foreach (xy_t cx, char c; ValueTuple!('r', 'g', 'b'))
	{
		auto w = i.window(cx*HRX, 0, cx*HRX+hr.w*3, hr.h);
		scratch.transformDraw!(`COLOR(c.`~c~`)`)(0, 0, w);
		channels[cx].size(lr.w, lr.h);
		channels[cx].downscaleDraw!(3*HRX, HRY)(scratch);
	}

	foreach (y; 0..lr.h)
		foreach (x; 0..lr.w)
		{
			COLOR c;
			c.r = channels[0][x, y].g;
			c.g = channels[1][x, y].g;
			c.b = channels[2][x, y].g;
			lr[x, y] = c;
		}
}
