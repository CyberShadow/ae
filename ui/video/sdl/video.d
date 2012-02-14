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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.ui.video.sdl.video;

import derelict.sdl.sdl;

import ae.ui.shell.sdl.shell;
import ae.ui.video.sdlcommon.video;
import ae.ui.video.renderer;
import ae.ui.video.sdl.renderer;

class SDLVideo : SDLCommonVideo
{
protected:
	override uint getSDLFlags()
	{
		return SDL_HWSURFACE | SDL_DOUBLEBUF;
	}

	override Renderer getRenderer()
	{
		return new SDLRenderer(sdlEnforce(SDL_GetVideoSurface()));
	}
}
