/**
 * Common code shared by SDL-based video drivers.
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

module ae.ui.video.sdl2common.video;

import std.process : environment;
import std.string;

import derelict.sdl2.sdl;

import ae.ui.video.threadedvideo;
import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;

class SDL2CommonVideo : ThreadedVideo
{
	override void getScreenSize(out uint width, out uint height)
	{
		width = screenWidth;
		height = screenHeight;
	}

	override void shutdown()
	{
		super.shutdown();
		if (window)
		{
			SDL_DestroyWindow(window);
			window = null;
		}
	}

	SDL_Window* window;
	SDL_Renderer* renderer;

protected:
	override @property bool initializeVideoInRenderThread()
	{
		// On Windows, OpenGL commands must come from the same thread that initialized video,
		// since SDL does not expose anything like wglMakeCurrent.
		// However, on X11 (and probably other platforms) video initialization must happen in the main thread.
		version (Windows)
			return true;
		else
			return false;
	}

	uint getSDLFlags     () { return 0; }
	uint getRendererFlags() { return 0; }
	void prepare() {}

	uint screenWidth, screenHeight;

	/// Main thread initialization.
	override void initMain(Application application)
	{
		uint flags = SDL_WINDOW_SHOWN;
		flags |= getSDLFlags();

		auto settings = application.getShellSettings();
		screenWidth = screenHeight = 0;
		uint windowPosX = SDL_WINDOWPOS_UNDEFINED, windowPosY = SDL_WINDOWPOS_UNDEFINED;

		final switch (settings.screenMode)
		{
			case ScreenMode.windowed:
				screenWidth  = settings.windowSizeX;
				screenHeight = settings.windowSizeY;
				windowPosX = settings.windowPosX == int.min ? SDL_WINDOWPOS_CENTERED : settings.windowPosX;
				windowPosY = settings.windowPosY == int.min ? SDL_WINDOWPOS_CENTERED : settings.windowPosY;
				break;
			case ScreenMode.maximized:
				flags |= SDL_WINDOW_MAXIMIZED;
				break;
			case ScreenMode.fullscreen:
				screenWidth  = settings.fullScreenX;
				screenHeight = settings.fullScreenY;
				flags |= SDL_WINDOW_FULLSCREEN;
				break;
			case ScreenMode.windowedFullscreen:
			{
				SDL_DisplayMode dm;
				sdlEnforce(SDL_GetDesktopDisplayMode(0, &dm)==0, "Can't get desktop display mode");
				windowPosX = 0;
				windowPosY = 0;
				screenWidth  = dm.w;
				screenHeight = dm.h;
				flags |= SDL_WINDOW_BORDERLESS;
				break;
			}
		}

		if (application.isResizable())
			flags |= SDL_WINDOW_RESIZABLE;

		if (window)
		{
			// We need to recreate the window if renderer flags,
			// such as SDL_WINDOW_OPENGL, have changed.
			// Also recreate when switching fullscreen modes.
			enum recreateMask =
				SDL_WINDOW_OPENGL |
				SDL_WINDOW_FULLSCREEN |
				SDL_WINDOW_BORDERLESS |
				SDL_WINDOW_RESIZABLE;
			if ((currentFlags & recreateMask) != (flags & recreateMask)
			 || (flags & SDL_WINDOW_FULLSCREEN))
			{
				SDL_DestroyWindow(window);
				window = null;
			}
		}

		if (window)
		{
			// Adjust parameters of existing window.

			if (windowPosX != SDL_WINDOWPOS_UNDEFINED && windowPosY != SDL_WINDOWPOS_UNDEFINED)
			{
				int currentX, currentY;
				SDL_GetWindowPosition(window, &currentX, &currentY);
				if (currentX != windowPosX || currentY != windowPosY)
					SDL_SetWindowPosition(window, windowPosX, windowPosY);
			}
			if (screenWidth && screenHeight)
			{
				int currentW, currentH;
				SDL_GetWindowSize(window, &currentW, &currentH);
				if (currentW != screenWidth || currentH != screenHeight)
					SDL_SetWindowSize(window, screenWidth, screenHeight);
			}
		}
		else
		{
			// Create a new window.

			// Window must always be created in the main (SDL event) thread,
			// otherwise we get Win32 deadlocks due to messages being sent
			// to the render thread.
			// As a result, if the event thread does something that results
			// in a Windows message, the message gets put on the render thread
			// message queue. However, while waiting for the message to be
			// processed, the event thread holds the application global lock,
			// and the render thread is waiting on it - thus resulting in a
			// deadlock.

			window = sdlEnforce(
				SDL_CreateWindow(
					toStringz(application.getName()),
					windowPosX, windowPosY,
					screenWidth, screenHeight,
					flags),
				"Can't create window");
		}

		currentFlags = flags;
	}

	/// Main/render thread initialization (depends on InitializeVideoInRenderThread).
	override void initVary()
	{
		prepare();
		renderer = sdlEnforce(SDL_CreateRenderer(window, -1, getRendererFlags()), "Can't create renderer");
	}

	/// Main/render thread finalization (depends on InitializeVideoInRenderThread).
	override void doneVary()
	{
		SDL_DestroyRenderer(renderer); renderer = null;
	}

	/// Main thread finalization.
	override void doneMain() {}

private:
	uint currentFlags;
}
