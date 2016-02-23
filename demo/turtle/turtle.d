/**
 * Simple turtle graphics API
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

module ae.demo.turtle.turtle;

import std.math;

import ae.utils.graphics.draw;
import ae.utils.graphics.view;

struct Turtle(View)
	if (isWritableView!View)
{
	alias Color = ViewColor!View;

	/// View to draw on. This will usually be a reference.
	View view;

	/// How many pixels is one unit (as used by `forward`).
	float scale;

	/// Current turtle coordinates.
	float x = 0, y = 0;

	/// Current turtle orientation (in degrees).
	/// Initially, the turtle is facing upwards.
	float orientation = 270;

	/// Current turtle color.
	Color color;

	/// Is the pen currently down?
	bool penActive = false;

	/// Put the pen up or down.
	void penUp  () { penActive = false; }
	void penDown() { penActive = true;  } /// ditto

	/// Change the turtle orientation by the given number of degrees.
	void turnLeft (float deg) { orientation -= deg; }
	void turnRight(float deg) { orientation += deg; } /// ditto
	void turnAround() { orientation += 180; }

	/// Move the turtle forward by the given number of units.
	/// If the pen is down, draw a line with the configured color.
	void forward(float distance)
	{
		// Angle in radians.
		float rad = orientation / 180 * PI;

		// Convert distance from units to pixels.
		distance *= scale;

		// Endpoint coordinates.
		float x0 = this.x;
		float y0 = this.y;
		float x1 = x0 + distance * cos(rad);
		float y1 = y0 + distance * sin(rad);

		// Draw a line if needed.
		if (penActive)
			view.aaLine(x0, y0, x1, y1, color);

		// Update coordinates.
		this.x = x1;
		this.y = y1;
	}
}

auto turtle(View)(ref View view)
	if (isWritableView!View)
{
	import std.typecons;
	alias R = NullableRef!View;
	R r = R(&view);
	return Turtle!R(r);
}
