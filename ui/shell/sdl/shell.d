/**
 * ae.ui.shell.sdl.shell
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

module ae.ui.shell.sdl.shell;

import std.conv;
import std.string;

import derelict.sdl.sdl;
import derelict.util.loader;

import ae.ui.shell.shell;
import ae.ui.video.video;
import ae.ui.app.application;
public import ae.ui.shell.events;
import ae.ui.timer.timer;

version(Posix) pragma(lib, "dl"); // for Derelict

final class SDLShell : Shell
{
	Application application;

	this(Application application)
	{
		this.application = application;
		this.caption = application.getName();

		SharedLibLoader.disableAutoUnload(); // SDL MM timers may crash on exit
		DerelictSDL.load();
		auto components = SDL_INIT_VIDEO | SDL_INIT_TIMER;
		if (application.needSound())
			components |= SDL_INIT_AUDIO;
		if (application.needJoystick())
			components |= SDL_INIT_JOYSTICK;
		sdlEnforce(SDL_Init(components)==0);

		SDL_EnableKeyRepeat(SDL_DEFAULT_REPEAT_DELAY, SDL_DEFAULT_REPEAT_INTERVAL);
		SDL_EnableUNICODE(1);

		if (application.needJoystick() && SDL_NumJoysticks())
		{
			SDL_JoystickEventState(SDL_ENABLE);
			SDL_JoystickOpen(0);
		}
	}

	/// A version of SDL_WaitEvent that sleeps less than 10ms at a time.
	private int waitEvent()
	{
		while (true)
		{
			SDL_PumpEvents();
			switch (SDL_PeepEvents(null, 1, SDL_GETEVENT, SDL_ALLEVENTS))
			{
				case -1: return 0;
				case  1: return 1;
				case  0: SDL_Delay(1); break;
				default: assert(0);
			}
		}
	}

	override void run()
	{
		assert(video !is null, "Video object not set");

		video.errorCallback = AppCallback(&quit);
		quitting = false;

		// video (re-)initialization loop
		while (!quitting)
		{
			reinitPending = false;
			setCaption(caption);

			// start renderer
			video.start(application);

			// The main purpose of this call is to allow the application
			// to react to window size changes.
			application.handleInit();

			// pump events
			while (!reinitPending && !quitting)
			{
				sdlEnforce(waitEvent());

				synchronized(application)
				{
					SDL_Event event = void;
					while (SDL_PollEvent(&event))
						handleEvent(&event);
				}
			}

			// wait for renderer to stop
			video.stop();
		}
	}

	~this()
	{
		SDL_Quit();
	}

	private enum CustomEvent : int
	{
		None,
		UpdateCaption,
	}

	// Note: calling this too often seems to fill up SDL's event queue.
	// This can result in this function throwing, and SDL skipping events like SDL_QUIT.
	private void sendCustomEvent(CustomEvent code)
	{
		SDL_Event event;
		event.type = SDL_USEREVENT;
		event.user.code = code;
		sdlEnforce(SDL_PushEvent(&event) == 0, "SDL_PushEvent");
	}

	override void prod()
	{
		sendCustomEvent(CustomEvent.None);
	}

	private string caption;

	override void setCaption(string caption)
	{
		// We can't pass the string in the message because the GC won't see it
		this.caption = caption;
		// Send a message to event thread to avoid SendMessage(WM_TEXTCHANGED) deadlock
		sendCustomEvent(CustomEvent.UpdateCaption);
	}

	MouseButton translateMouseButton(ubyte sdlButton)
	{
		switch (sdlButton)
		{
		case SDL_BUTTON_LEFT:
			return MouseButton.Left;
		case SDL_BUTTON_MIDDLE:
		default:
			return MouseButton.Middle;
		case SDL_BUTTON_RIGHT:
			return MouseButton.Right;
		case SDL_BUTTON_WHEELUP:
			return MouseButton.WheelUp;
		case SDL_BUTTON_WHEELDOWN:
			return MouseButton.WheelDown;
		}
	}

	MouseButtons translateMouseButtons(ubyte sdlButtons)
	{
		MouseButtons result;
		for (ubyte i=SDL_BUTTON_LEFT; i<=SDL_BUTTON_WHEELDOWN; i++)
			if (sdlButtons & SDL_BUTTON(i))
				result |= 1<<translateMouseButton(i);
		return result;
	}

	void handleEvent(SDL_Event* event)
	{
		switch (event.type)
		{
		case SDL_KEYDOWN:
			/+if ( event.key.keysym.sym == SDLK_RETURN && (keypressed[SDLK_RALT] || keypressed[SDLK_LALT]))
			{
				if (application.toggleFullScreen())
				{
					video.stop();
					video.initialize();
					video.start();
					return false;
				}
			}+/
			return application.handleKeyDown(sdlKeys[event.key.keysym.sym], event.key.keysym.unicode);
		case SDL_KEYUP:
			return application.handleKeyUp(sdlKeys[event.key.keysym.sym]);

		case SDL_MOUSEBUTTONDOWN:
			return application.handleMouseDown(event.button.x, event.button.y, translateMouseButton(event.button.button));
		case SDL_MOUSEBUTTONUP:
			return application.handleMouseUp(event.button.x, event.button.y, translateMouseButton(event.button.button));
		case SDL_MOUSEMOTION:
			return application.handleMouseMove(event.motion.x, event.motion.y, translateMouseButtons(event.motion.state));

		case SDL_JOYAXISMOTION:
			return application.handleJoyAxisMotion(event.jaxis.axis, event.jaxis.value);
		case SDL_JOYHATMOTION:
			return application.handleJoyHatMotion (event.jhat.hat, cast(JoystickHatState)event.jhat.value);
		case SDL_JOYBUTTONDOWN:
			return application.handleJoyButtonDown(event.jbutton.button);
		case SDL_JOYBUTTONUP:
			return application.handleJoyButtonUp  (event.jbutton.button);

		case SDL_VIDEORESIZE:
		{
			auto settings = application.getShellSettings();
			settings.windowSizeX = event.resize.w;
			settings.windowSizeY = event.resize.h;
			application.setShellSettings(settings);
			reinitPending = true;
			break;
		}
		case SDL_QUIT:
			application.handleQuit();
			break;
		case SDL_USEREVENT:
			final switch (cast(CustomEvent)event.user.code)
			{
			case CustomEvent.None:
				break;
			case CustomEvent.UpdateCaption:
				auto szCaption = toStringz(caption);
				SDL_WM_SetCaption(szCaption, szCaption);
				break;
			}
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

Key[SDLK_LAST] sdlKeys;

shared static this()
{
	sdlKeys[SDLK_UP    ] = Key.up   ;
	sdlKeys[SDLK_DOWN  ] = Key.down ;
	sdlKeys[SDLK_LEFT  ] = Key.left ;
	sdlKeys[SDLK_RIGHT ] = Key.right;
	sdlKeys[SDLK_SPACE ] = Key.space;
	sdlKeys[SDLK_ESCAPE] = Key.esc  ;
}
