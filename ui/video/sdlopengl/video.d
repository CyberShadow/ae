/**
 * ae.ui.video.sdlopengl.video
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

module ae.ui.video.sdlopengl.video;

import derelict.sdl.sdl;
import derelict.opengl.gl;
import derelict.opengl.glu;

import ae.ui.app.application;
import ae.ui.shell.sdl.shell;
import ae.ui.video.sdlcommon.video;
import ae.ui.video.renderer;
import ae.ui.video.sdlopengl.renderer;

class SDLOpenGLVideo : SDLCommonVideo
{
	bool vsync = true;
	bool aa = true;
	uint aaSamples = 4;

	this()
	{
		DerelictGL.load();
		DerelictGLU.load();
	}

protected:
	override uint getSDLFlags()
	{
		return SDL_OPENGL;
	}

	override Renderer getRenderer()
	{
		auto s = sdlEnforce(SDL_GetVideoSurface());
		return new SDLOpenGLRenderer(s.w, s.h);
	}

	override void prepare()
	{
		SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
		SDL_GL_SetAttribute(SDL_GL_SWAP_CONTROL, vsync ? 1 : 0);

		if (aa)
		{
			SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
			SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, aaSamples);
		}
	}
}
