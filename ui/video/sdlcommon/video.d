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

module ae.ui.video.sdlcommon.video;

import std.process : environment;

import derelict.sdl.sdl;

import ae.sys.desktop;
import ae.ui.video.threadedvideo;
import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;


class SDLCommonVideo : ThreadedVideo
{
	override void getScreenSize(out uint width, out uint height)
	{
		width = screenWidth;
		height = screenHeight;
	}

protected:
	abstract uint getSDLFlags();
	void prepare() {}

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

	override @property bool initializeVideoSynchronously()
	{
		// SDL 1.x needs to pump events during video initialization.
		return false;
	}

	/// Main thread initialization.
	override void initMain(Application application)
	{
		flags = getSDLFlags();

		auto settings = application.getShellSettings();

		string windowPos;
		bool centered;

		final switch (settings.screenMode)
		{
			case ScreenMode.windowed:
				screenWidth  = settings.windowSizeX;
				screenHeight = settings.windowSizeY;
				// Since SDL 1.x does not provide a way to track window coordinates,
				// just center the window
				if (firstStart)
				{
					// Center the window only on start-up.
					// We do not want to center the window if
					// e.g. the user resized it.
					centered = true;
				}
				break;
			case ScreenMode.maximized:
				// not supported - use windowed
				goto case ScreenMode.windowed;
			case ScreenMode.fullscreen:
				screenWidth  = settings.fullScreenX;
				screenHeight = settings.fullScreenY;
				flags |= SDL_FULLSCREEN;
				break;
			case ScreenMode.windowedFullscreen:
				// TODO: use SDL_GetVideoInfo
				static if (is(typeof(getDesktopResolution)))
				{
					getDesktopResolution(screenWidth, screenHeight);
					flags |= SDL_NOFRAME;
					windowPos = "0,0";
				}
				else
				{
					// not supported - use fullscreen
					goto case ScreenMode.fullscreen;
				}
				break;
		}

		if (application.isResizable())
			flags |= SDL_RESIZABLE;

		if (windowPos)
			environment["SDL_VIDEO_WINDOW_POS"] = windowPos;
		else
			environment.remove("SDL_VIDEO_WINDOW_POS");

		if (centered)
			environment["SDL_VIDEO_CENTERED"] = "1";
		else
			environment.remove("SDL_VIDEO_CENTERED");

		firstStart = false;
	}

	/// Main/render thread initialization (depends on InitializeVideoInRenderThread).
	override void initVary()
	{
		prepare();
		sdlEnforce(SDL_SetVideoMode(screenWidth, screenHeight, 32, flags), "can't set video mode");
	}

	/// Main/render thread finalization (depends on InitializeVideoInRenderThread).
	override void doneVary() {}

	/// Main thread finalization.
	override void doneMain() {}

private:
	uint screenWidth, screenHeight, flags;
	bool firstStart = true;
}
