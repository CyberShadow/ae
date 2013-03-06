/**
 * ae.ui.wm.application
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

module ae.ui.wm.application;

import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.events;
import ae.ui.wm.controls.control;
import ae.ui.video.renderer;

/// Specialization of Application class which automatically handles framework messages.
class WMApplication : Application
{
	Shell shell;
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

	override void handleMouseMove(uint x, uint y, MouseButtons buttons)
	{
		root.handleMouseMove(x, y, buttons);
	}

	override void handleQuit()
	{
		shell.quit();
	}

	override void handleInit()
	{
		uint w, h;
		shell.video.getScreenSize(w, h);
		root.w = w; root.h = h;
		root.sizeChanged();
	}

	// ********************************* Rendering *********************************

	override void render(Renderer s)
	{
		root.render(s, 0, 0);
	}
}
