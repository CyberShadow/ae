/**
 * ae.demo.test.mycontrol
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

module ae.demo.test.mycontrol;

import ae.ui.shell.shell;
import ae.ui.shell.events;
import ae.ui.video.renderer;
import ae.ui.wm.controls.control;
import std.conv;

import std.random;

class MyControl : Control
{
	Shell shell;

	this(Shell shell)
	{
		w = 800;
		h = 600;
		this.shell = shell;
	}

	struct Coord { uint x, y, c; void* dummy; }
	Coord[] coords;

	override void handleMouseMove(uint x, uint y, MouseButtons buttons)
	{
		if (buttons)
		{
			uint b = cast(uint)buttons;
			b = (b&1)|((b&2)<<7)|((b&4)<<14);
			b |= b<<4;
			b |= b<<2;
			b |= b<<1;
			coords ~= Coord(x, y, b);
		}
	}

	override void render(Renderer s, int x, int y)
	{
		//foreach (i; 0..100)
		//	coords ~= Coord(uniform(0, w), uniform(0, h), uniform(0, 0x1_00_00_00));
		static size_t oldCoordsLength;
		if (coords.length != oldCoordsLength)
		{
			shell.setCaption(to!string(coords.length));
			oldCoordsLength = coords.length;
		}

		// if (coords.length > 100) throw new Exception("derp");

		auto b = s.lock();
		foreach (coord; coords)
			if (coord.x < b.w && coord.y < b.h)
				b[coord.x, coord.y] = coord.c;
		s.unlock();
	}
}

