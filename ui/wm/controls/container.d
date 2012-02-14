/**
 * ae.ui.wm.controls.container
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

module ae.ui.wm.controls.container;

import ae.ui.wm.controls.control;
import ae.ui.shell.events;
import ae.ui.video.renderer;

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

	override void handleMouseMove(uint x, uint y, MouseButtons buttons)
	{
		auto child = controlAt(x, y);
		if (child)
			child.handleMouseMove(x-child.x, y-child.y, buttons);
	}

	abstract override void render(Renderer s, int x, int y)
	{
		// background should be rendered upstream
		foreach (child; children)
			child.render(s, x+child.x, y+child.y);
	}
}
