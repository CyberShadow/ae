/**
 * ae.ui.shell.sdl2.shell
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

module ae.ui.shell.sdl2.shell;

import std.conv;
import std.string;

import derelict.sdl2.sdl;
import derelict.util.loader;

import ae.ui.shell.shell;
//import ae.ui.video.video;
import ae.ui.video.sdl2common.video;
import ae.ui.app.application;
public import ae.ui.shell.events;
import ae.ui.timer.timer;

//!!version(Posix) pragma(lib, "dl"); // for Derelict

final class SDL2Shell : Shell
{
	Application application;
	SDL2CommonVideo sdlVideo;

	this(Application application)
	{
		this.application = application;

		//!!SharedLibLoader.disableAutoUnload(); // SDL MM timers may crash on exit
		DerelictSDL2.load();
		auto components = SDL_INIT_VIDEO | SDL_INIT_TIMER;
		if (application.needSound())
			components |= SDL_INIT_AUDIO;
		if (application.needJoystick())
			components |= SDL_INIT_JOYSTICK;
		sdlEnforce(SDL_Init(components)==0);

		//!!SDL_EnableKeyRepeat(SDL_DEFAULT_REPEAT_DELAY, SDL_DEFAULT_REPEAT_INTERVAL);
		//!!SDL_EnableUNICODE(1);

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
			synchronized(this)
				if (mainThreadQueue.length)
					return 1;

			SDL_PumpEvents();
			switch (SDL_PeepEvents(null, 1, SDL_GETEVENT, 0, uint.max))
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
		assert(video, "Video object not set");
		sdlVideo = cast(SDL2CommonVideo)video;
		assert(sdlVideo, "Video is non-SDL");

		video.errorCallback = AppCallback(&quit);
		quitting = false;

		// video (re-)initialization loop
		while (!quitting)
		{
			reinitPending = false;

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
					if (mainThreadQueue.length)
					{
						foreach (fn; mainThreadQueue)
							if (fn)
								fn();
						mainThreadQueue = null;
					}

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

	private void delegate()[] mainThreadQueue;

	private void runInMainThread(void delegate() fn)
	{
		synchronized(this)
			mainThreadQueue ~= fn;
	}

	override void prod()
	{
		runInMainThread(null);
	}

	override void setCaption(string caption)
	{
		runInMainThread({ SDL_SetWindowTitle(sdlVideo.window, toStringz(caption)); });
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
		}
	}

	enum SDL_BUTTON_LAST = SDL_BUTTON_X2;

	MouseButtons translateMouseButtons(ubyte sdlButtons)
	{
		MouseButtons result;
		for (ubyte i=SDL_BUTTON_LEFT; i<=SDL_BUTTON_LAST; i++)
			if (sdlButtons & SDL_BUTTON(i))
				result |= 1<<translateMouseButton(i);
		return result;
	}

	void handleEvent(SDL_Event* event)
	{
		switch (event.type)
		{
		case SDL_KEYDOWN:
			/+if ( event.key.keysym.scancode == SDL_SCANCODE_RETURN && (keypressed[SDL_SCANCODE_RALT] || keypressed[SDL_SCANCODE_LALT]))
			{
				if (application.toggleFullScreen())
				{
					video.stop();
					video.initialize();
					video.start();
					return false;
				}
			}+/
			return application.handleKeyDown(sdlKeys[event.key.keysym.scancode], event.key.keysym.unicode);
		case SDL_KEYUP:
			return application.handleKeyUp(sdlKeys[event.key.keysym.scancode]);

		case SDL_MOUSEBUTTONDOWN:
			return application.handleMouseDown(event.button.x, event.button.y, translateMouseButton(event.button.button));
		case SDL_MOUSEBUTTONUP:
			return application.handleMouseUp(event.button.x, event.button.y, translateMouseButton(event.button.button));
		case SDL_MOUSEMOTION:
			return application.handleMouseMove(event.motion.x, event.motion.y, translateMouseButtons(event.motion.state));

		case SDL_JOYAXISMOTION:
			return application.handleJoyAxisMotion(event.jaxis.axis, cast(short)event.jaxis.value);
		case SDL_JOYHATMOTION:
			return application.handleJoyHatMotion (event.jhat.hat, cast(JoystickHatState)event.jhat.value);
		case SDL_JOYBUTTONDOWN:
			return application.handleJoyButtonDown(event.jbutton.button);
		case SDL_JOYBUTTONUP:
			return application.handleJoyButtonUp  (event.jbutton.button);

		case SDL_WINDOWEVENT:
			switch (event.window.event)
			{
				case SDL_WINDOWEVENT_MOVED:
					auto settings = application.getShellSettings();
					settings.windowPosX = event.window.data1;
					settings.windowPosY = event.window.data2;
					application.setShellSettings(settings);
					break;
				case SDL_WINDOWEVENT_SIZE_CHANGED:
					auto settings = application.getShellSettings();
					settings.windowSizeX = event.window.data1;
					settings.windowSizeY = event.window.data2;
					application.setShellSettings(settings);
					reinitPending = true;
					break;
				case SDL_WINDOWEVENT_CLOSE:
					event.type = SDL_QUIT;
					SDL_PushEvent(event);
					break;
				default:
					break;
			}
			break;
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

Key[SDL_NUM_SCANCODES] sdlKeys;

shared static this()
{
	sdlKeys[SDL_SCANCODE_UP    ] = Key.up   ;
	sdlKeys[SDL_SCANCODE_DOWN  ] = Key.down ;
	sdlKeys[SDL_SCANCODE_LEFT  ] = Key.left ;
	sdlKeys[SDL_SCANCODE_RIGHT ] = Key.right;
	sdlKeys[SDL_SCANCODE_SPACE ] = Key.space;
	sdlKeys[SDL_SCANCODE_ESCAPE] = Key.esc  ;
}
