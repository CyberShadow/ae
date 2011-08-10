module demo.test.mycontrol;

import ae.shell.shell;
import ae.shell.events;
import ae.video.surface;
import ae.wm.controls.control;
import std.conv;

import std.random;

class MyControl : Control
{
	this()
	{
		w = 800;
		h = 600;
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

	override void render(Surface s, int x, int y)
	{
		foreach (i; 0..100)
			coords ~= Coord(uniform(0, w), uniform(0, h), uniform(0, 0x1_00_00_00));
		shell.setCaption(to!string(coords.length));

		auto b = s.lock();
		foreach (coord; coords)
			b[coord.x, coord.y] = coord.c;
		s.unlock();
	}
}

