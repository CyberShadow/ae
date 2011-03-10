module ae.video.sdl.video;

import core.thread;

import derelict.sdl.sdl;

import ae.video.video;
import ae.core.application;
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
