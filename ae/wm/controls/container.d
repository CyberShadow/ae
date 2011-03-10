module ae.wm.controls.container;

import ae.wm.controls.control;
import ae.shell.events;

/// Base class for a control with children.
class ContainerControl : Control
{
	Control[] children;
	Control focusedControl;

	final Control controlAt(uint x, uint y)
	{
		foreach (child; children)
			if (x>=child.x && x<child.x+child.w && y>=child.y && y<child.y+child.h)
				return child;
		return null;
	}

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		auto child = controlAt(x, y);
		if (child)
			child.handleMouseDown(x-child.x, y-child.y, button);
	}

	override void handleMouseUp(uint x, uint y, MouseButton button)
	{
		auto child = controlAt(x, y);
		if (child)
			child.handleMouseUp(x-child.x, y-child.y, button);
	}
}
