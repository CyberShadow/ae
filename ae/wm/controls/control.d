module ae.wm.controls.control;

import ae.shell.events;
import ae.video.surface;

/// Root control class.
class Control
{
	uint x, y, w, h;

	void handleMouseDown(uint x, uint y, MouseButton button) {}
	void handleMouseUp(uint x, uint y, MouseButton button) {}

	abstract void render(Surface s, int x, int y);
}
