module ae.shell.sdl.shell;

import std.conv;
import std.string;

import derelict.sdl.sdl;

import ae.shell.shell;
import ae.video.video;
import ae.core.application;
import ae.os.os;

final class SDLShell : Shell
{
	this()
	{
		DerelictSDL.load();
		sdlEnforce(SDL_Init(SDL_INIT_VIDEO | SDL_INIT_AUDIO)==0);
		SDL_EnableKeyRepeat(SDL_DEFAULT_REPEAT_DELAY, SDL_DEFAULT_REPEAT_INTERVAL);
		SDL_EnableUNICODE(1);
	}

	override void run()
	{
		assert(video !is null, "Video object not set");

		// video (re-)initialization loop
		while (!quitting)
		{
			reinitPending = false;
			video.initialize();
			setCaption(application.getName());

			// start renderer
			video.start();

			// pump events
			while (!reinitPending && !quitting)
			{
				sdlEnforce(SDL_WaitEvent(null));

				synchronized(application)
				{
					SDL_Event event = void;
					while (SDL_PollEvent(&event))
						handleEvent(&event);
				}
			}

			// wait for render thread
			video.stop();
		}
		SDL_Quit();
	}

	void setCaption(string caption)
	{
		auto szCaption = toStringz(caption);
		SDL_WM_SetCaption(szCaption, szCaption);
	}

	void handleEvent(SDL_Event* event)
	{
		switch (event.type)
		{
		case SDL_QUIT:
			application.handleQuit();
			break;
		default:
			break;
		}
	}

	bool reinitPending;
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
