module ae.wm.controls.control;

import ae.shell.events;

/// Root control class.
class Control
{
	uint x, y, w, h;

	void handleMouseDown(uint x, uint y, MouseButton button) {}
	void handleMouseUp(uint x, uint y, MouseButton button) {}
}
