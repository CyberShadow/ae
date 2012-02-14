/**
 * ae.ui.wm.controls.root
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

module ae.ui.wm.controls.root;

import ae.ui.wm.controls.container;
import ae.ui.video.renderer;

/// Container for all top-level windows.
final class RootControl : ContainerControl
{
	override void render(Renderer s, int x, int y)
	{
		// TODO: fill background
		super.render(s, x, y);
	}
}
