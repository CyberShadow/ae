/**
 * ae.ui.video.sdl.video
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.ui.video.sdl2.video;

import derelict.sdl2.sdl;

import ae.ui.shell.sdl2.shell;
import ae.ui.video.sdl2common.video;
import ae.ui.video.renderer;
import ae.ui.video.sdl2.renderer;

/// `Video` implementation backed by `SDL2SoftwareRenderer`.
class SDL2SoftwareVideo : SDL2CommonVideo
{
protected:
	override Renderer getRenderer()
	{
		return new SDL2SoftwareRenderer(renderer, screenWidth, screenHeight);
	}
}

/// `Video` implementation backed by `SDL2Renderer`.
class SDL2Video : SDL2CommonVideo
{
protected:
	override Renderer getRenderer()
	{
		return new SDL2Renderer(renderer, screenWidth, screenHeight);
	}
}
