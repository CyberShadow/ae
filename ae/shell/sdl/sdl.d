module ae.shell.sdl.sdl;

import core.thread;
import std.conv;

import derelict.sdl.sdl;

import ae.shell.shell;
import ae.core.application;
import ae.os.os;

final class SDLShell : Shell
{
	void initVideo()
	{
		auto surface = SDL_GetVideoSurface();
		if (surface)
			SDL_FreeSurface(surface);

		uint screenWidth, screenHeight, flags;
		if (application.isFullScreen())
		{
		    application.getFullScreenResolution(screenWidth, screenHeight);
		    flags = SDL_HWSURFACE | SDL_FULLSCREEN;
		}
		else
		{
			application.getWindowSize(screenWidth, screenHeight);
			flags = SDL_HWSURFACE;
		}

		sdlEnforce(SDL_SetVideoMode(screenWidth, screenHeight, 32, flags), "can't set video mode");
	}

	override void run()
	{
		// global initialization
		DerelictSDL.load();
		sdlEnforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)==0);
		SDL_EnableKeyRepeat(SDL_DEFAULT_REPEAT_DELAY, SDL_DEFAULT_REPEAT_INTERVAL);

		// video (re-)initialization loop
		while (!quitting)
		{	
			reinitPending = false;
			initVideo();
			
			// start render thread
			auto renderThread = new Thread(&renderThreadProc);

			// pump events
			while (!reinitPending && !quitting)
			{
				SDL_Event event = void;
				while (SDL_PollEvent(&event))
					handleEvent(&event);

				sdlEnforce(SDL_WaitEvent(null));
			}

			// wait for render thread
			while (renderThread.isRunning())
				Thread.sleep(10_000);
		}
		SDL_Quit();
	}

	void handleEvent(SDL_Event* event)
	{
	}

	bool reinitPending;

	void renderThreadProc()
	{
		auto surface = sdlEnforce(SDL_GetVideoSurface());
		while (!reinitPending)
		{
			synchronized (application)
			{
				// TODO: put rendering code here
			}
			sdlEnforce(SDL_Flip(surface)==0);
		}
	}
}

class SdlException : Exception
{
	this(string message) { super(message); }
}

T sdlEnforce(T)(T result, string message = null)
{
	if (!result)
		throw new SdlException("SDL error: " ~ (message ? message ~ ": " : "") ~ to!string(SDL_GetError()));
	return result;
}
