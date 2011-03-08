module ae.video.sdl.video;

import core.thread;

import derelict.sdl.sdl;

import ae.video.video;
import ae.core.application;
import ae.shell.sdl.shell;

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
	}

	override void stop()
	{
		stopping = true;
		while (renderThread.isRunning())
			Thread.sleep(10_000);
	}

private:
	Thread renderThread;
	bool stopping;

	void renderThreadProc()
	{
		auto surface = sdlEnforce(SDL_GetVideoSurface());
		while (!stopping)
		{
			// TODO: predict flip (vblank wait) duration and render at the last moment
			synchronized (application)
			{
				// TODO: put rendering code here
			}
			sdlEnforce(SDL_Flip(surface)==0);
		}
	}
}
