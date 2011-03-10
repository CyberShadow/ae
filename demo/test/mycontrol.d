module demo.test.mycontrol;

import ae.shell.events;
import ae.video.surface;
import ae.wm.controls.control;

class MyControl : Control
{
	this()
	{
		w = 1024;
		h = 768;
	}

	struct Coord { uint x, y, c; }
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
		auto b = s.lock();
		foreach (coord; coords)
			b[coord.x, coord.y] = coord.c;
		s.unlock();
	}
}

