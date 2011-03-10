module ae.wm.application;

import ae.core.application;
import ae.shell.shell;
import ae.shell.events;
import ae.wm.controls.root;
import ae.video.surface;

/// Specialization of Application class which automatically handles framework messages.
class WMApplication : Application
{
	RootControl root;

	this()
	{
		root = new RootControl();
	}

	// ****************************** Event handlers *******************************

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		root.handleMouseDown(x, y, button);
	}

	override void handleMouseUp(uint x, uint y, MouseButton button)
	{
		root.handleMouseUp(x, y, button);
	}

	override void handleQuit()
	{
		shell.quit();
	}

	// ********************************* Rendering *********************************

	override void render(Surface s)
	{
		root.render(s, 0, 0);
	}
}
