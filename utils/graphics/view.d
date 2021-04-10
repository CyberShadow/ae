/**
 * Image maps.
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

module ae.utils.graphics.view;

import std.functional;
import std.typetuple;

/// This is the type used for image sizes and coordinates.
/// Rationale:
/// - Signed, because operations with image coordinates
///   often involve subtraction, and subtraction with
///   unsigned numbers often leads to trouble.
/// - Same size as size_t, in order to use the CPU word size
///   and enable seamless interoperability with the
///   .length property of arrays / ranges.
alias xy_t = sizediff_t;

/// A view is any type which provides a width, height,
/// and can be indexed to get the color at a specific
/// coordinate.
enum isView(T) =
	is(typeof(T.init.w) : xy_t) && // width
	is(typeof(T.init.h) : xy_t) && // height
	is(typeof(T.init[0, 0])   );   // color information

/// Returns the color type of the specified view.
/// By convention, colors are structs with numeric
/// fields named after the channel they indicate.
alias ViewColor(T) = typeof(T.init[0, 0]);

/// Views can be read-only or writable.
enum isWritableView(T) =
	isView!T &&
	is(typeof(T.init[0, 0] = ViewColor!T.init));

/// Optionally, a view can also provide direct pixel
/// access. We call these "direct views".
enum isDirectView(T) =
	isView!T &&
	is(typeof(T.init.scanline(0)[0][0]) : ViewColor!T);

/// Mixin which implements view primitives on top of
/// existing direct view primitives.
mixin template DirectView()
{
	import std.traits : Unqual;
	alias StorageType = Unqual!(typeof(scanline(0)[0])); ///
	alias COLOR = Unqual!(typeof(StorageType.init[0])); ///

	/// Implements the view[x, y] operator.
	auto ref inout(COLOR) opIndex(xy_t x, xy_t y) inout
	{
		return scanline(y)[x / StorageType.length][x % StorageType.length];
	}

	/// Allows array-like view[y][x] access.
	static struct Row
	{
		StorageType[] scanline; ///
		auto ref inout(COLOR) opIndex(xy_t x) inout
		{
			return scanline[x / StorageType.length][x % StorageType.length];
		} ///
	}
	Row opIndex(xy_t y)
	{
		return Row(scanline(y));
	} /// ditto

	/// Implements the view[x, y] = c operator.
	COLOR opIndexAssign(COLOR value, xy_t x, xy_t y)
	{
		return scanline(y)[x / StorageType.length][x % StorageType.length] = value;
	}
}

/// Get the storage type of a direct view.
template ViewStorageType(V)
if (isDirectView!V)
{
	alias ViewStorageType = typeof({ V v = void; return v.scanline(0)[0]; }());
}

// ***************************************************************************

/// Returns a view which calculates pixels
/// on-demand using the specified formula.
template procedural(alias formula)
{
	alias fun = binaryFun!(formula, "x", "y");
	alias COLOR = typeof(fun(xy_t.init, xy_t.init));

	auto procedural(xy_t w, xy_t h)
	{
		struct Procedural
		{
			xy_t w, h;

			auto ref COLOR opIndex(xy_t x, xy_t y)
			{
				assert(x >= 0 && y >= 0 && x < w && y < h);
				return fun(x, y);
			}
		}
		return Procedural(w, h);
	}
}

/// Returns a view of the specified dimensions
/// and same solid color.
auto solid(COLOR)(COLOR c, xy_t w, xy_t h)
{
	return procedural!((x, y) => c)(w, h);
}

/// Return a 1x1 view of the specified color.
/// Useful for testing.
auto onePixel(COLOR)(COLOR c)
{
	return solid(c, 1, 1);
}

unittest
{
	assert(onePixel(42)[0, 0] == 42);
}

// ***************************************************************************

/// Blits a view onto another.
/// The views must have the same size.
void blitTo(SRC, DST)(auto ref SRC src, auto ref DST dst)
	if (isView!SRC && isWritableView!DST)
{
	assert(src.w == dst.w && src.h == dst.h, "View size mismatch");
	foreach (y; 0..src.h)
	{
		static if (isDirectView!SRC && isDirectView!DST && is(ViewStorageType!SRC == ViewStorageType!DST))
			dst.scanline(y)[] = src.scanline(y)[];
		else
		{
			foreach (x; 0..src.w)
				dst[x, y] = src[x, y];
		}
	}
}

/// Helper function to blit an image onto another at a specified location.
void blitTo(SRC, DST)(auto ref SRC src, auto ref DST dst, xy_t x, xy_t y)
{
	src.blitTo(dst.crop(x, y, x+src.w, y+src.h));
}

/// Like `blitTo`, but only the intersecting part of the two images.
void safeBlitTo(SRC, DST)(auto ref SRC src, auto ref DST dst, xy_t x, xy_t y)
{
	// TODO: refactor into safeCrop
	xy_t sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1;
	sx1 = src.w;
	sy1 = src.h;
	dx0 = x;
	dy0 = y;
	dx1 = x + src.w;
	dy1 = y + src.h;
	if (dx0 < 0) { auto v = -dx0; sx0 += v; dx0 += v; }
	if (dy0 < 0) { auto v = -dy0; sy0 += v; dy0 += v; }
	if (dx1 > dst.w) { auto v = dx1 - dst.w; sx1 -= v; dx1 -= v; }
	if (dy1 > dst.h) { auto v = dy1 - dst.h; sy1 -= v; dy1 -= v; }
	if (dx0 > dx1) { dx1 = dx0; sx1 = sx0; }
	if (dy0 > dy1) { dy1 = dy0; sy1 = sy0; }
	assert(sx1 - sx0 == dx1 - dx0);
	assert(sy1 - sy0 == dy1 - dy0);
	blitTo(
		src.crop(sx0, sy0, sx1, sy1),
		dst.crop(dx0, dy0, dx1, dy1),
	);
}

/// Default implementation for the .size method.
/// Asserts that the view has the desired size.
void size(V)(auto ref V src, xy_t w, xy_t h)
	if (isView!V)
{
	import std.string : format;
	assert(src.w == w && src.h == h,
		"Wrong size for %s: need (%s,%s), have (%s,%s)"
		.format(V.stringof, w, h, src.w, src.h));
}

// ***************************************************************************

/// Mixin which implements view primitives on top of
/// another view, using a coordinate transform function.
mixin template Warp(V)
	if (isView!V)
{
	V src; /// Underlying source view.

	auto ref ViewColor!V opIndex(xy_t x, xy_t y)
	{
		warp(x, y);
		return src[x, y];
	} ///

	static if (isWritableView!V)
	ViewColor!V opIndexAssign(ViewColor!V value, xy_t x, xy_t y)
	{
		warp(x, y);
		return src[x, y] = value;
	} ///
}

/// Crop a view to the specified rectangle.
auto crop(V)(auto ref V src, xy_t x0, xy_t y0, xy_t x1, xy_t y1)
	if (isView!V)
{
	assert( 0 <=    x0 &&  0 <=    y0);
	assert(x0 <=    x1 && y0 <=    y1);
	assert(x1 <= src.w && y1 <= src.h);

	static struct Crop
	{
		mixin Warp!V;

		xy_t x0, y0, x1, y1;

		@property xy_t w() { return x1-x0; }
		@property xy_t h() { return y1-y0; }

		void warp(ref xy_t x, ref xy_t y)
		{
			x += x0;
			y += y0;
		}

		static if (isDirectView!V)
		auto scanline(xy_t y)
		{
			return src.scanline(y0+y)[x0..x1];
		}
	}

	static assert(isDirectView!V == isDirectView!Crop);

	return Crop(src, x0, y0, x1, y1);
}

unittest
{
	auto g = procedural!((x, y) => y)(1, 256);
	auto c = g.crop(0, 10, 1, 20);
	assert(c[0, 0] == 10);
}

/// Tile another view.
auto tile(V)(auto ref V src, xy_t w, xy_t h)
	if (isView!V)
{
	static struct Tile
	{
		mixin Warp!V;

		xy_t w, h;

		void warp(ref xy_t x, ref xy_t y)
		{
			assert(x >= 0 && y >= 0 && x < w && y < h);
			x = x % src.w;
			y = y % src.h;
		}
	}

	return Tile(src, w, h);
}

unittest
{
	auto i = onePixel(4);
	auto t = i.tile(100, 100);
	assert(t[12, 34] == 4);
}

/// Present a resized view using nearest-neighbor interpolation.
auto nearestNeighbor(V)(auto ref V src, xy_t w, xy_t h)
	if (isView!V)
{
	static struct NearestNeighbor
	{
		mixin Warp!V;

		xy_t w, h;

		void warp(ref xy_t x, ref xy_t y)
		{
			x = cast(xy_t)(cast(long)x * src.w / w);
			y = cast(xy_t)(cast(long)y * src.h / h);
		}
	}

	return NearestNeighbor(src, w, h);
}

unittest
{
	auto g = procedural!((x, y) => x+10*y)(10, 10);
	auto n = g.nearestNeighbor(100, 100);
	assert(n[12, 34] == 31);
}

/// Swap the X and Y axes (flip the image diagonally).
auto flipXY(V)(auto ref V src)
{
	static struct FlipXY
	{
		mixin Warp!V;

		@property xy_t w() { return src.h; }
		@property xy_t h() { return src.w; }

		void warp(ref xy_t x, ref xy_t y)
		{
			import std.algorithm;
			swap(x, y);
		}
	}

	return FlipXY(src);
}

// ***************************************************************************

/// Return a view of src with the coordinates transformed
/// according to the given formulas
template warp(string xExpr, string yExpr)
{
	auto warp(V)(auto ref V src)
		if (isView!V)
	{
		static struct Warped
		{
			mixin Warp!V;

			@property xy_t w() { return src.w; }
			@property xy_t h() { return src.h; }

			void warp(ref xy_t x, ref xy_t y)
			{
				auto nx = mixin(xExpr);
				auto ny = mixin(yExpr);
				x = nx; y = ny;
			}

			private void testWarpY()()
			{
				xy_t y;
				y = mixin(yExpr);
			}

			/// If the x coordinate is not affected and y does not
			/// depend on x, we can transform entire scanlines.
			static if (xExpr == "x" &&
				__traits(compiles, testWarpY()) &&
				isDirectView!V)
			auto scanline(xy_t y)
			{
				return src.scanline(mixin(yExpr));
			}
		}

		return Warped(src);
	}
}

/// ditto
template warp(alias pred)
{
	auto warp(V)(auto ref V src)
		if (isView!V)
	{
		struct Warped
		{
			mixin Warp!V;

			@property xy_t w() { return src.w; }
			@property xy_t h() { return src.h; }

			alias warp = binaryFun!(pred, "x", "y");
		}

		return Warped(src);
	}
}

/// Return a view of src with the x coordinate inverted.
alias hflip = warp!(q{w-x-1}, q{y});

/// Return a view of src with the y coordinate inverted.
alias vflip = warp!(q{x}, q{h-y-1});

/// Return a view of src with both coordinates inverted.
alias flip = warp!(q{w-x-1}, q{h-y-1});

unittest
{
	import ae.utils.graphics.image;
	auto vband = procedural!((x, y) => y)(1, 256).copy();
	auto flipped = vband.vflip();
	assert(flipped[0, 1] == 254);
	static assert(isDirectView!(typeof(flipped)));

	import std.algorithm;
	auto w = vband.warp!((ref x, ref y) { swap(x, y); });
}

/// Rotate a view 90 degrees clockwise.
auto rotateCW(V)(auto ref V src)
{
	return src.flipXY().hflip();
}

/// Rotate a view 90 degrees counter-clockwise.
auto rotateCCW(V)(auto ref V src)
{
	return src.flipXY().vflip();
}

unittest
{
	auto g = procedural!((x, y) => x+10*y)(10, 10);
	xy_t[] corners(V)(V v) { return [v[0, 0], v[9, 0], v[0, 9], v[9, 9]]; }
	assert(corners(g          ) == [ 0,  9, 90, 99]);
	assert(corners(g.flipXY   ) == [ 0, 90,  9, 99]);
	assert(corners(g.rotateCW ) == [90,  0, 99,  9]);
	assert(corners(g.rotateCCW) == [ 9, 99,  0, 90]);
}

// ***************************************************************************

/// Return a view with the given views concatenated vertically.
/// Assumes all views have the same width.
/// Creates an index for fast row -> source view lookup.
auto vjoiner(V)(V[] views)
	if (isView!V)
{
	static struct VJoiner
	{
		struct Child { V view; xy_t y; }
		Child[] children;
		size_t[] index;

		@property xy_t w() { return children[0].view.w; }
		xy_t h;

		this(V[] views)
		{
			children = new Child[views.length];
			xy_t y = 0;
			foreach (i, ref v; views)
			{
				assert(v.w == views[0].w, "Inconsistent width");
				children[i] = Child(v, y);
				y += v.h;
			}

			h = y;

			index = new size_t[h];

			foreach (i, ref child; children)
				index[child.y .. child.y + child.view.h] = i;
		}

		auto ref ViewColor!V opIndex(xy_t x, xy_t y)
		{
			auto child = &children[index[y]];
			return child.view[x, y - child.y];
		}

		static if (isWritableView!V)
		ViewColor!V opIndexAssign(ViewColor!V value, xy_t x, xy_t y)
		{
			auto child = &children[index[y]];
			return child.view[x, y - child.y] = value;
		}

		static if (isDirectView!V)
		auto scanline(xy_t y)
		{
			auto child = &children[index[y]];
			return child.view.scanline(y - child.y);
		}
	}

	return VJoiner(views);
}

unittest
{
	import std.algorithm : map;
	import std.array : array;
	import std.range : iota;

	auto v = 10.iota.map!onePixel.array.vjoiner();
	foreach (i; 0..10)
		assert(v[0, i] == i);
}

// ***************************************************************************

/// Overlay the view fg over bg at a certain coordinate.
/// The resulting view inherits bg's size.
auto overlay(BG, FG)(auto ref BG bg, auto ref FG fg, xy_t x, xy_t y)
	if (isView!BG && isView!FG && is(ViewColor!BG == ViewColor!FG))
{
	alias COLOR = ViewColor!BG;

	static struct Overlay
	{
		BG bg;
		FG fg;

		xy_t ox, oy;

		@property xy_t w() { return bg.w; }
		@property xy_t h() { return bg.h; }

		auto ref COLOR opIndex(xy_t x, xy_t y)
		{
			if (x >= ox && y >= oy && x < ox + fg.w && y < oy + fg.h)
				return fg[x - ox, y - oy];
			else
				return bg[x, y];
		}

		static if (isWritableView!BG && isWritableView!FG)
		COLOR opIndexAssign(COLOR value, xy_t x, xy_t y)
		{
			if (x >= ox && y >= oy && x < ox + fg.w && y < oy + fg.h)
				return fg[x - ox, y - oy] = value;
			else
				return bg[x, y] = value;
		}
	}

	return Overlay(bg, fg, x, y);
}

/// Add a solid-color border around an image.
/// The parameters indicate the border's thickness around each side
/// (left, top, right, bottom in order).
auto border(V, COLOR)(auto ref V src, xy_t x0, xy_t y0, xy_t x1, xy_t y1, COLOR color)
	if (isView!V && is(COLOR == ViewColor!V))
{
	return color
		.solid(
			x0 + src.w + x1,
			y0 + src.h + y1,
		)
		.overlay(src, x0, y0);
}

unittest
{
	auto g = procedural!((x, y) => cast(int)(x+10*y))(10, 10);
	auto b = g.border(5, 5, 5, 5, 42);
	assert(b.w == 20);
	assert(b.h == 20);
	assert(b[1, 2] == 42);
	assert(b[5, 5] == 0);
	assert(b[14, 14] == 99);
	assert(b[14, 15] == 42);
}

// ***************************************************************************

/// Alpha-blend a number of views.
/// The order is bottom-to-top.
auto blend(SRCS...)(SRCS sources)
	if (allSatisfy!(isView, SRCS)
	 && sources.length > 0)
{
	alias COLOR = ViewColor!(SRCS[0]);

	foreach (src; sources)
		assert(src.w == sources[0].w && src.h == sources[0].h,
			"Mismatching layer size");

	static struct Blend
	{
		SRCS sources;

		@property xy_t w() { return sources[0].w; }
		@property xy_t h() { return sources[0].h; }

		COLOR opIndex(xy_t x, xy_t y)
		{
			COLOR c = sources[0][x, y];
			foreach (ref src; sources[1..$])
				c = COLOR.blend(c, src[x, y]);
			return c;
		}
	}

	return Blend(sources);
}

unittest
{
	import ae.utils.graphics.color : LA;
	auto v0 = onePixel(LA(  0, 255));
	auto v1 = onePixel(LA(255, 100));
	auto vb = blend(v0, v1);
	assert(vb[0, 0] == LA(100, 255));
}

// ***************************************************************************

/// Similar to Warp, but allows warped coordinates to go out of bounds.
mixin template SafeWarp(V)
{
	V src; /// Underlying source view.
	ViewColor!V defaultColor; /// Return this color when out-of-bounds.

	auto ref ViewColor!V opIndex(xy_t x, xy_t y)
	{
		warp(x, y);
		if (x >= 0 && y >= 0 && x < w && y < h)
			return src[x, y];
		else
			return defaultColor;
	} ///

	static if (isWritableView!V)
	ViewColor!V opIndexAssign(ViewColor!V value, xy_t x, xy_t y)
	{
		warp(x, y);
		if (x >= 0 && y >= 0 && x < w && y < h)
			return src[x, y] = value;
		else
			return defaultColor;
	} ///
}

/// Rotate a view at an arbitrary angle (specified in radians),
/// around the specified point. Rotated points that fall outside of
/// the specified view resolve to defaultColor.
auto rotate(V, COLOR)(auto ref V src, double angle, COLOR defaultColor,
		double ox, double oy)
	if (isView!V && is(COLOR : ViewColor!V))
{
	static struct Rotate
	{
		mixin SafeWarp!V;
		double theta, ox, oy;

		@property xy_t w() { return src.w; }
		@property xy_t h() { return src.h; }

		void warp(ref xy_t x, ref xy_t y)
		{
			import std.math;
			auto vx = x - ox;
			auto vy = y - oy;
			x = cast(xy_t)round(ox + cos(theta) * vx - sin(theta) * vy);
			y = cast(xy_t)round(oy + sin(theta) * vx + cos(theta) * vy);
		}
	}

	return Rotate(src, defaultColor, angle, ox, oy);
}

/// Rotate a view at an arbitrary angle (specified in radians) around
/// its center.
auto rotate(V, COLOR)(auto ref V src, double angle,
		COLOR defaultColor = ViewColor!V.init)
	if (isView!V && is(COLOR : ViewColor!V))
{
	return src.rotate(angle, defaultColor, src.w / 2.0 - 0.5, src.h / 2.0 - 0.5);
}

// https://issues.dlang.org/show_bug.cgi?id=7016
version(unittest) static import ae.utils.geometry;

unittest
{
	import ae.utils.graphics.image;
	import ae.utils.geometry;
	auto i = Image!xy_t(3, 3);
	i[1, 0] = 1;
	auto r = i.rotate(cast(double)TAU/4, 0);
	assert(r[1, 0] == 0);
	assert(r[0, 1] == 1);
}

// ***************************************************************************

/// Return a view which applies a predicate over the
/// underlying view's pixel colors.
template colorMap(alias fun)
{
	auto colorMap(V)(auto ref V src)
		if (isView!V)
	{
		alias OLDCOLOR = ViewColor!V;
		alias NEWCOLOR = typeof(fun(OLDCOLOR.init));

		struct Map
		{
			V src;

			@property xy_t w() { return src.w; }
			@property xy_t h() { return src.h; }

			/*auto ref*/ NEWCOLOR opIndex(xy_t x, xy_t y)
			{
				return fun(src[x, y]);
			}
		}

		return Map(src);
	}
}

/// Two-way colorMap which allows writing to the returned view.
template colorMap(alias getFun, alias setFun)
{
	auto colorMap(V)(auto ref V src)
		if (isView!V)
	{
		alias OLDCOLOR = ViewColor!V;
		alias NEWCOLOR = typeof(getFun(OLDCOLOR.init));

		struct Map
		{
			V src;

			@property xy_t w() { return src.w; }
			@property xy_t h() { return src.h; }

			NEWCOLOR opIndex(xy_t x, xy_t y)
			{
				return getFun(src[x, y]);
			}

			static if (isWritableView!V)
			NEWCOLOR opIndexAssign(NEWCOLOR c, xy_t x, xy_t y)
			{
				return src[x, y] = setFun(c);
			}
		}

		return Map(src);
	}
}

/// Returns a view which inverts all channels.
// TODO: skip alpha and padding
alias invert = colorMap!(c => ~c, c => ~c);

unittest
{
	import ae.utils.graphics.color;
	import ae.utils.graphics.image;

	auto i = onePixel(L8(1));
	assert(i.invert[0, 0].l == 254);
}

// ***************************************************************************

/// Returns the smallest window containing all
/// pixels that satisfy the given predicate.
template trim(alias fun)
{
	auto trim(V)(auto ref V src)
	{
		xy_t x0 = 0, y0 = 0, x1 = src.w, y1 = src.h;
	topLoop:
		while (y0 < y1)
		{
			foreach (x; 0..src.w)
				if (fun(src[x, y0]))
					break topLoop;
			y0++;
		}
	bottomLoop:
		while (y1 > y0)
		{
			foreach (x; 0..src.w)
				if (fun(src[x, y1-1]))
					break bottomLoop;
			y1--;
		}

	leftLoop:
		while (x0 < x1)
		{
			foreach (y; y0..y1)
				if (fun(src[x0, y]))
					break leftLoop;
			x0++;
		}
	rightLoop:
		while (x1 > x0)
		{
			foreach (y; y0..y1)
				if (fun(src[x1-1, y]))
					break rightLoop;
			x1--;
		}

		return src.crop(x0, y0, x1, y1);
	}
}

/// Returns the smallest window containing all
/// pixels that are not fully transparent.
alias trimAlpha = trim!(c => c.a);

// ***************************************************************************

/// Splits a view into segments and
/// calls fun on each segment in parallel.
/// Returns an array of segments which
/// can be joined using vjoin or vjoiner.
template parallel(alias fun)
{
	auto parallel(V)(auto ref V src, size_t chunkSize = 0)
		if (isView!V)
	{
		import std.parallelism : taskPool, parallel;

		auto processSegment(R)(R rows)
		{
			auto y0 = rows[0];
			auto y1 = y0 + cast(typeof(y0))rows.length;
			auto segment = src.crop(0, y0, src.w, y1);
			return fun(segment);
		}

		import std.range : iota, chunks;
		if (!chunkSize)
			chunkSize = taskPool.defaultWorkUnitSize(src.h);

		auto range = src.h.iota.chunks(chunkSize);
		alias Result = typeof(processSegment(range.front));
		auto result = new Result[range.length];
		foreach (n; range.length.iota.parallel(1))
			result[n] = processSegment(range[n]);
		return result;
	}
}

unittest
{
	import ae.utils.graphics.image;
	auto g = procedural!((x, y) => x+10*y)(10, 10);
	auto i = g.parallel!(s => s.invert.copy).vjoiner;
	assert(i[0, 0] == ~0);
	assert(i[9, 9] == ~99);
}
