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

import core.thread;
import std.process : environment;
import std.string;

import derelict.sdl2.sdl;

import ae.ui.video.video;
import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;
import ae.ui.video.renderer;

// On Windows, OpenGL commands must come from the same thread that initialized video,
// since SDL does not expose anything like wglMakeCurrent.
// However, on X11 (and probably other platforms) video initialization must happen in the main thread.
version (Windows)
	enum InitializeVideoInRenderThread = true;
else
	enum InitializeVideoInRenderThread = false;

class SDL2CommonVideo : Video
{
	this()
	{
		starting = false;
		renderThread = new Thread(&renderThreadProc);
		renderThread.start();
	}

	override void shutdown()
	{
		stopping = quitting = true;
		renderThread.join();
	}

	override void start(Application application)
	{
		configure(application);

		static if (!InitializeVideoInRenderThread)
			initialize();

		started = stopping = false;
		starting = true;
		while (!started) wait();
	}

	override void stop()
	{
		stopped = false;
		stopping = true;
		while (!stopped) wait();
	}

	override void stopAsync(AppCallback callback)
	{
		stopCallback = callback;
		stopped = false;
		stopping = true;
	}

	override void getScreenSize(out uint width, out uint height)
	{
		width = screenWidth;
		height = screenHeight;
	}

	SDL_Window* window;
	SDL_Renderer* renderer;

protected:
	uint getSDLFlags     () { return 0; }
	uint getRendererFlags() { return 0; }
	abstract Renderer getRenderer();
	void prepare() {}

	uint screenWidth, screenHeight;

private:
	void wait()
	{
		if (error)
			renderThread.join(); // collect exception
		SDL_Delay(1);
		SDL_PumpEvents();
	}

	uint flags;
	int windowPosX, windowPosY;
	string caption;
	bool firstStart = true;

	final void configure(Application application)
	{
		flags = SDL_WINDOW_SHOWN;
		flags |= getSDLFlags();

		auto settings = application.getShellSettings();
		screenWidth = screenHeight = 0;
		windowPosX = windowPosY = SDL_WINDOWPOS_UNDEFINED;
		caption = application.getName();

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

		renderCallback.bind(&application.render);

		firstStart = false;
	}

	final void initialize()
	{
		prepare();
		window = sdlEnforce(SDL_CreateWindow(toStringz(caption), windowPosX, windowPosY, screenWidth, screenHeight, flags), "Can't create window");
		renderer = sdlEnforce(SDL_CreateRenderer(window, -1, getRendererFlags()), "Can't create renderer");
	}

	Thread renderThread;
	shared bool starting, started, stopping, stopped, quitting, quit, error;
	AppCallback stopCallback;
	AppCallbackEx!(Renderer) renderCallback;

	final void renderThreadProc()
	{
		scope(failure) error = true;

		// SDL expects that only one thread across the program's lifetime will do OpenGL initialization.
		// Thus, re-initialization must happen from only one thread.
		// This thread sleeps and polls while it's not told to run.
	outer:
		while (!quitting)
		{
			while (!starting)
			{
				// TODO: use proper semaphores
				if (quitting) return;
				SDL_Delay(1);
			}
			started = true;
			starting = false;

			scope(failure) if (errorCallback) try { errorCallback.call(); } catch {}

			static if (InitializeVideoInRenderThread)
				initialize();

			auto renderer = getRenderer();
			while (!stopping)
			{
				// TODO: predict flip (vblank wait) duration and render at the last moment
				renderCallback.call(renderer);
				renderer.present();
			}
			renderer.shutdown();
			if (stopCallback)
				stopCallback.call();
			stopped = true;
			stopping = false;
		}
	}
}
