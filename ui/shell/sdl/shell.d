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

module ae.ui.shell.sdl.shell;

import std.conv;
import std.string;

import derelict.sdl.sdl;

import ae.ui.shell.shell;
import ae.ui.shell.events;
import ae.ui.video.video;
import ae.ui.app.application;
import ae.sys.os.os;

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

			// wait for renderer to stop
			video.stop();
		}
		SDL_Quit();
	}

	private enum CustomEvents : int
	{
		SetCaption
	}

	override void setCaption(string caption)
	{
		// Send a message to event thread to avoid SendMessage(WM_TEXTCHANGED) deadlock
		auto szCaption = toStringz(caption);

		SDL_Event event;
		event.type = SDL_USEREVENT;
		event.user.code = CustomEvents.SetCaption;
		event.user.data1 = cast(void*)szCaption;
		SDL_PushEvent(&event);
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
		case SDL_MOUSEBUTTONDOWN:
			application.handleMouseDown(event.button.x, event.button.y, translateMouseButton(event.button.button));
			break;
		case SDL_MOUSEBUTTONUP:
			application.handleMouseUp(event.button.x, event.button.y, translateMouseButton(event.button.button));
			break;
		case SDL_MOUSEMOTION:
			application.handleMouseMove(event.motion.x, event.motion.y, translateMouseButtons(event.motion.state));
			break;
		case SDL_QUIT:
			application.handleQuit();
			break;
		case SDL_USEREVENT:
			switch (event.user.code)
			{
			case CustomEvents.SetCaption:
				auto szCaption = cast(char*)event.user.data1;
				SDL_WM_SetCaption(szCaption, szCaption);
				break;
			default:
				assert(0);
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
