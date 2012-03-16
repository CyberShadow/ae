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
}
