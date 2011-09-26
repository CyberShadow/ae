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
 * Portions created by the Initial Developer are Copyright (C) 2007-2011
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

//import std.file;
import std.string;
//import std.ascii;
//import std.exception;
//import std.conv;
import std.math;
//import std.traits;
//import std.zlib;
//import crc32;
//static import core.bitop;

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
	import std.algorithm : min, max;
	import std.math : atan2, sqrt;

	alias typeof(this) SELF;
	static assert(IsCanvas!(SELF));

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

	void clear(COLOR c)
	{
		static if (is(typeof(pixels[]))) // pixels is an array
			pixels[] = c;
		else
			pixels[0..h*stride] = c;
	}

	void draw(OTHER)(OTHER canvas, int x, int y)
		if (IsCanvas!OTHER && is(COLOR == OTHER.COLOR))
	{
		// TODO: alpha blending
		size_t dstStart = y*stride+x, srcStart = 0;
		foreach (j; 0..canvas.h)
			pixels[dstStart..dstStart+canvas.stride] = canvas.pixels[srcStart..srcStart+canvas.stride],
			dstStart += stride,
			srcStart += canvas.stride;
	}

	void hline(bool CHECKED=false)(int x1, int x2, int y, COLOR c)
	{
		static if (CHECKED)
		{
			if (x1 >= w || x2 < 0 || y < 0 || y>=h) return;
			if (x1 <  0) x1=0;
			if (x2 >= w) x2=w;
		}
		if (x1 >= x2) return;
		auto rowOffset = y*stride;
		pixels[rowOffset+x1..rowOffset+x2] = c;
	}

	void vline(int x, int y1, int y2, COLOR c)
	{
		foreach (y; y1..y2) // TODO: optimize
			pixels[y*stride+x] = c;
	}

	void rect(int x1, int y1, int x2, int y2, COLOR c) // []
	{
		hline(x1, x2+1, y1, c);
		hline(x1, x2+1, y2, c);
		vline(x1, y1, y2+1, c);
		vline(x2, y1, y2+1, c);
	}

	void fillRect(int x1, int y1, int x2, int y2, COLOR b) // [)
	{
		foreach (y; y1..y2)
			pixels[y*stride+x1..y*stride+x2] = b;
	}

	void fillRect(int x1, int y1, int x2, int y2, COLOR c, COLOR b) // []
	{
		rect(x1, y1, x2, y2, c);
		if (x1 <= x2 || y1 <= y2) return;
		foreach (y; y1+1..y2)
			pixels[y*stride+x1+1..y*stride+x2] = b;
	}

	// Unchecked! Make sure area is bounded.
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
}

struct RGB    { ubyte  r, g, b; }
struct RGB16  { ushort r, g, b; }
struct RGBX   { ubyte  r, g, b, x; }
struct RGBX16 { ushort r, g, b, x; }
struct RGBA   { ubyte  r, g, b, a; }
struct RGBA16 { ushort r, g, b, a; }
struct GA     { ubyte  g, a; }
struct GA16   { ushort g, a; }

private
{
	static assert(RGB.sizeof == 3);
	RGB[2] test;
	static assert(test.sizeof == 6);
}

// *****************************************************************************

/// Create a type where each integer member of T is expanded by BYTES bytes.
template ExpandType(T, uint BYTES)
{
	static if (is(T : ulong))
	{
		static if (T.sizeof + BYTES <= 2)
			alias ushort ExpandType;
		else
		static if (T.sizeof + BYTES <= 4)
			alias uint ExpandType;
		else
		static if (T.sizeof + BYTES <= 8)
			alias ulong ExpandType;
		else
			static assert(0, "No type big enough to fit " ~ T.sizeof.stringof ~ " + " ~ BYTES.stringof ~ " bytes");
	}
	else
	static if (is(T==struct))
		struct ExpandType
		{
			static string mixFields()
			{
				string s;
				string[] fields = structFields!T;

				foreach (field; fields)
					s ~= "ExpandType!(typeof(" ~ T.stringof ~ ".init." ~ field ~ "), "~BYTES.stringof~") " ~ field ~ ";\n";
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
					s ~= "ReplaceType!(typeof(" ~ T.stringof ~ ".init." ~ field ~ "), FROM, TO) " ~ field ~ ";\n";
				return s;
			}

			//pragma(msg, mixFields());
			mixin(mixFields());
		}
	else
		static assert(0, "Can't replace " ~ T.stringof);
}

// *****************************************************************************

enum TAU = 2*PI;

T itpl(T, U)(T low, T high, U r, U rLow, U rHigh)
{
	import std.traits;
	return cast(T)(low + (cast(Signed!T)high-cast(Signed!T)low) * (cast(Signed!U)r - cast(Signed!U)rLow) / (cast(Signed!U)rHigh - cast(Signed!U)rLow));
}

T sqr(T)(T x) { return x*x; }

private string[] structFields(T)()
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
