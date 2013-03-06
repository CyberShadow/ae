/**
 * ae.ui.wm.controls.control
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

module ae.ui.wm.controls.control;

import ae.ui.shell.events;
import ae.ui.video.renderer;

/// Root control class.
class Control
{
	uint x, y, w, h;

	void handleMouseDown(uint x, uint y, MouseButton button) {}
	void handleMouseUp(uint x, uint y, MouseButton button) {}
	void handleMouseMove(uint x, uint y, MouseButtons buttons) {}

	abstract void render(Renderer r, int x, int y);

	final @property ContainerControl parent()
	{
		return _parent;
	}

	final @property void parent(ContainerControl newParent)
	{
		if (_parent)
			_parent._removeChild(this);
		_parent = newParent;
		_parent._addChild(this);
	}

private:
	ContainerControl _parent;
}

/// An abstract base class for a control with children.
class ContainerControl : Control
{
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

	final @property Control[] children()
	{
		return _children;
	}

	final void addChild(Control control)
	{
		control.parent = this;
	}

private:
	// An array should be fine, performance-wise.
	// UI manipulations should be infrequent.
	Control[] _children;

	final void _addChild(Control target)
	{
		_children ~= target;
	}

	final void _removeChild(Control target)
	{
		foreach (i, child; _children)
			if (child is target)
			{
				_children = _children[0..i] ~ _children[i+1..$];
				return;
			}
		assert(false, "Attempting to remove inexisting child");
	}
}
