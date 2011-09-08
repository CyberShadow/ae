/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the ArmageddonEngine library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

module ae.video.sdl.video;

import core.thread;

import derelict.sdl.sdl;

import ae.video.video;
import ae.app.application;
import ae.shell.sdl.shell;
import ae.video.sdl.surface;

class SDLVideo : Video
{
	override void initialize()
	{
		auto surface = SDL_GetVideoSurface();
		if (surface)
			SDL_FreeSurface(surface);

		uint screenWidth, screenHeight, flags;
		if (application.isFullScreen())
		{
		    application.getFullScreenResolution(screenWidth, screenHeight);
		    flags = SDL_HWSURFACE | SDL_DOUBLEBUF | SDL_FULLSCREEN;
		}
		else
		{
			application.getWindowSize(screenWidth, screenHeight);
			flags = SDL_HWSURFACE | SDL_DOUBLEBUF;
		}

		sdlEnforce(SDL_SetVideoMode(screenWidth, screenHeight, 32, flags), "can't set video mode");
	}

	override void start()
	{
		stopping = false;
		renderThread = new Thread(&renderThreadProc);
		renderThread.start();
	}

	override void stop()
	{
		stopping = true;
		renderThread.join();
	}

private:
	Thread renderThread;
	bool stopping;

	void renderThreadProc()
	{
		auto surface = new SDLSurface(sdlEnforce(SDL_GetVideoSurface()));
		while (!stopping)
		{
			// TODO: predict flip (vblank wait) duration and render at the last moment
			synchronized (application)
			{
				application.render(surface);
			}
			surface.flip();
		}
	}
}
