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

/// 2D geometry math stuff
module ae.utils.geometry;

import std.traits;

import ae.utils.math;

enum TAU = 2*PI;

auto dist (T)(T x, T y) { return sqrt(x*x+y*y); }
auto dist2(T)(T x, T y) { return      x*x+y*y ; }

struct Point(T)
{
	T x, y;
	void translate(T dx, T dy) { x += dx; y += dy; }
	Point!T getCenter() { return this; }
}
auto point(T...)(T args) { return Point!(CommonType!T)(args); }

struct Rect(T)
{
	T x0, y0, x1, y1;
	@property T w() { return x1-x0; }
	@property T h() { return y1-y0; }
	void sort() { sort2(x0, x1); sort2(y0, y1); }
	@property bool sorted() { return x0 <= x1 && y0 <= y1; }
	void translate(T dx, T dy) { x0 += dx; y0 += dy; x1 += dx; y1 += dy; }
	Point!T getCenter() { return Point!T(average(x0, x1), average(y0, y1)); }
}
auto rect(T...)(T args) { return Rect!(CommonType!T)(args); }

struct Circle(T)
{
	T x, y, r;
	@property T diameter() { return 2*r; }
	void translate(T dx, T dy) { x += dx; y += dy; }
	Point!T getCenter() { return Point!T(x, y); }
}
auto circle(T...)(T args) { return Circle!(CommonType!T)(args); }

enum ShapeKind { none, point, rect, circle }
struct Shape(T)
{
	ShapeKind kind;
	union
	{
		Point!T point;
		Rect!T rect;
		Circle!T circle;
	}

	this(Point!T point)
	{
		this.kind = ShapeKind.point;
		this.point = point;
	}

	this(Rect!T rect)
	{
		this.kind = ShapeKind.rect;
		this.rect = rect;
	}

	this(Circle!T circle)
	{
		this.kind = ShapeKind.circle;
		this.circle = circle;
	}

	auto opDispatch(string s, T...)(T args)
		if (is(typeof(mixin("point ." ~ s ~ "(args)"))) &&
		    is(typeof(mixin("rect  ." ~ s ~ "(args)"))) &&
		    is(typeof(mixin("circle." ~ s ~ "(args)"))))
	{
		switch (kind)
		{
			case ShapeKind.point:
				return mixin("point ." ~ s ~ "(args)");
			case ShapeKind.circle:
				return mixin("circle." ~ s ~ "(args)");
			case ShapeKind.rect:
				return mixin("rect  ." ~ s ~ "(args)");
			default:
				assert(0);
		}
	}
}
auto shape(T)(T shape) { return Shape!(typeof(shape.tupleof[0]))(shape); }

bool intersects(T)(Shape!T a, Shape!T b)
{
	switch (a.kind)
	{
		case ShapeKind.point:
			switch (b.kind)
			{
			case ShapeKind.point:
				return a.point.x == b.point.x && a.point.y == b.point.y;
			case ShapeKind.circle:
				return dist2(a.point.x-b.circle.x, a.point.y-b.circle.y) < sqr(b.circle.r);
			case ShapeKind.rect:
				assert(b.rect.sorted);
				return between(a.point.x, b.rect.x0, b.rect.x1) && between(a.point.y, b.rect.y0, b.rect.y1);
			default:
				assert(0);
			}
		case ShapeKind.circle:
			switch (b.kind)
			{
			case ShapeKind.point:
				return dist2(a.circle.x-b.point.x, a.circle.y-b.point.y) < sqr(a.circle.r);
			case ShapeKind.circle:
				return dist2(a.circle.x-b.circle.x, a.circle.y-b.circle.y) < sqr(a.circle.r+b.circle.r);
			case ShapeKind.rect:
				return intersects!T(a.circle, b.rect);
			default:
				assert(0);
			}
		case ShapeKind.rect:
			switch (b.kind)
			{
			case ShapeKind.point:
				assert(a.rect.sorted);
				return between(b.point.x, a.rect.x0, a.rect.x1) && between(b.point.y, a.rect.y0, a.rect.y1);
			case ShapeKind.circle:
				return intersects!T(b.circle, a.rect);
			case ShapeKind.rect:
				assert(0); // TODO
			default:
				assert(0);
			}
		default:
			assert(0);
	}
}

bool intersects(T)(Circle!T circle, Rect!T rect)
{
	// http://stackoverflow.com/questions/401847/circle-rectangle-collision-detection-intersection

	Point!T circleDistance;

	auto hw = rect.w/2, hh = rect.h/2;

	circleDistance.x = abs(circle.x - rect.x0 - hw);
	circleDistance.y = abs(circle.y - rect.y0 - hh);

	if (circleDistance.x > (hw + circle.r)) return false;
	if (circleDistance.y > (hh + circle.r)) return false;

	if (circleDistance.x <= hw) return true;
	if (circleDistance.y <= hh) return true;

	auto cornerDistance_sq =
		sqr(circleDistance.x - hw) +
		sqr(circleDistance.y - hh);

	return (cornerDistance_sq <= sqr(circle.r));
}
