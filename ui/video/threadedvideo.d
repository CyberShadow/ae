/**
 * ae.ui.video.threadedvideo
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

module ae.ui.video.threadedvideo;

import core.thread;

import ae.ui.video.video;
import ae.ui.app.application;
import ae.ui.video.renderer;

class ThreadedVideo : Video
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
		initMain(application);

		if (!initializeVideoInRenderThread)
			initVary();

		renderCallback.bind(&application.render);

		started = stopping = false;
		starting = true;
		while (!started) wait();
	}

	override void stop()
	{
		stopped = false;
		stopping = true;
		while (!stopped) wait();

		if (!initializeVideoInRenderThread)
			doneVary();
		doneMain();
	}

	override void stopAsync(AppCallback callback)
	{
		stopCallback = callback;
		stopped = false;
		stopping = true;
	}

protected:
	/// Allows varying the thread from which initVary gets called.
	abstract @property bool initializeVideoInRenderThread();

	/// When initializing video in the render thread, block main thread while video is initializing?
	/// Some renderers may require the main thread to be responsive during graphics initialization,
	/// to pump events - thus, initialization must be asynchronous.
	@property bool initializeVideoSynchronously() { return true; }

	abstract Renderer getRenderer();

	/// Main thread initialization.
	abstract void initMain(Application application);

	/// Main/render thread initialization (depends on initializeVideoInRenderThread).
	abstract void initVary();

	/// Main thread finalization.
	abstract void doneMain();

	/// Main/render thread finalization (depends on initializeVideoInRenderThread).
	abstract void doneVary();

private:
	final void wait()
	{
		if (error)
			renderThread.join(); // collect exception
		nop();
	}

	final void nop() { Thread.sleep(msecs(1)); }

	Thread renderThread;
	shared bool starting, started, stopping, stopped, quitting, quit, error;
	AppCallback stopCallback;
	AppCallbackEx!(Renderer) renderCallback;

	final void renderThreadProc()
	{
		scope(failure) error = true;

		// SDL expects that only one thread across the program's
		// lifetime will do OpenGL initialization.
		// Thus, re-initialization must happen from only one thread.
		// This thread sleeps and polls while it's not told to run.
	outer:
		while (!quitting)
		{
			while (!starting)
			{
				// TODO: use proper semaphores
				if (quitting) return;
				nop();
			}

			if (initializeVideoInRenderThread &&  initializeVideoSynchronously)
				initVary();

			started = true; starting = false;
			scope(failure) if (errorCallback) try { errorCallback.call(); } catch {}

			if (initializeVideoInRenderThread && !initializeVideoSynchronously)
				initVary();

			auto renderer = getRenderer();

			while (!stopping)
			{
				// TODO: predict flip (vblank wait) duration and render at the last moment
				renderCallback.call(renderer);
				renderer.present();
			}
			renderer.shutdown();

			if (initializeVideoInRenderThread)
				doneVary();

			if (stopCallback)
				stopCallback.call();

			stopped = true; stopping = false;
		}
	}
}
