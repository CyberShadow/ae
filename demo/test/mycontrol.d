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

	struct Coord { uint x, y; }
	Coord[] coords;

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		coords ~= Coord(x, y);
	}

	override void render(Surface s, int x, int y)
	{
		auto b = s.lock();
		foreach (coord; coords)
			b[coord.x, coord.y] = 0xFFFFFF;
		s.unlock();
	}
}

