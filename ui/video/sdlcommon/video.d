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
 * Portions created by the Initial Developer are Copyright (C) 2011-2012
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

/// Common code shared by SDL-based video drivers.
module ae.ui.video.sdlcommon.video;

import core.thread;
import std.process : environment;

import derelict.sdl.sdl;

import ae.ui.video.video;
import ae.ui.app.application;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.renderer;

// On Windows, OpenGL commands must come from the same thread that initialized video,
// since SDL does not expose anything like wglMakeCurrent.
// However, on X11 (and probably other platforms) video initialization must happen in the main thread.
version (Windows)
	enum InitializeVideoInRenderThread = true;
else
	enum InitializeVideoInRenderThread = false;

class SDLCommonVideo : Video
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

protected:
	abstract uint getSDLFlags();
	abstract Renderer getRenderer();
	void prepare() {}

private:
	void wait()
	{
		if (error)
			renderThread.join(); // collect exception
		SDL_Delay(1);
		SDL_PumpEvents();
	}

	uint screenWidth, screenHeight, flags;
	bool firstStart = true;

	final void configure(Application application)
	{
		flags = getSDLFlags();

		if (application.isFullScreen())
		{
			application.getFullScreenResolution(screenWidth, screenHeight);
			flags |= SDL_FULLSCREEN;
		}
		else
			application.getWindowSize(screenWidth, screenHeight);

		if (application.isResizable())
			flags |= SDL_RESIZABLE;

		if (firstStart)
			environment["SDL_VIDEO_CENTERED"] = "1";
		else
			environment.remove("SDL_VIDEO_CENTERED");

		renderCallback.bind(&application.render);

		firstStart = false;
	}

	final void initialize()
	{
		prepare();
		sdlEnforce(SDL_SetVideoMode(screenWidth, screenHeight, 32, flags), "can't set video mode");
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
			if (stopCallback)
				stopCallback.call();
			stopped = true;
			stopping = false;
		}
	}
}
