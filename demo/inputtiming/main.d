/**
 * ae.demo.inputtiming.main
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

module ae.demo.inputtiming.main;

import core.time;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.sdlopengl.video;
import ae.ui.video.renderer;
import ae.utils.fps;
import ae.utils.graphics.image;

alias ae.utils.math.abs abs; // Issue 314?

final class MyApplication : Application
{
	override string getName() { return "Demo/Input"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;

	enum BAND_WIDTH = 800;
	enum BAND_INTERVAL = 100;
	enum BAND_TOP = 50;
	enum BAND_HEIGHT = 30;
	enum BAND_HNSECS_PER_PIXEL = 200_000;
	enum HISTORY_TOP = 200;
	enum HISTORY_HEIGHT = 50;

	enum Device : int { keyboard, joypad, mouse, max }
	enum SampleType : int { precision, duration, max }

	int[] history[Device.max][SampleType.max];
	enum SAMPLE_COLORS = [BGRX(0, 0, 255), BGRX(0, 255, 0)];

	/// Some (precise) time value of the moment, in hnsecs.
	@property long now() { return MonoTime.currTime.to!("hnsecs", long); }

	override void render(Renderer s)
	{
		auto x = now / BAND_HNSECS_PER_PIXEL;

		s.clear();
		s.line(BAND_WIDTH/2, BAND_TOP, BAND_WIDTH/2, BAND_TOP + BAND_HEIGHT, BGRX(0, 0, 255));
		foreach (lx; 0..BAND_WIDTH)
			if ((lx+x)%BAND_INTERVAL == 0)
				s.line(lx, BAND_TOP+BAND_HEIGHT, lx, BAND_TOP+BAND_HEIGHT*2, BGRX(0, 255, 0));

		foreach (device, deviceSamples; history)
			foreach (sampleType, samples; deviceSamples)
			{
				auto y = HISTORY_TOP + HISTORY_HEIGHT * (device*2 + sampleType + 1);
				foreach (index, sample; samples)
				{
					if (sample > HISTORY_HEIGHT)
						sample = HISTORY_HEIGHT;
					s.line(index, y - sample, index, y, SAMPLE_COLORS[sampleType]);
				}
			}
	}

	override int run(string[] args)
	{
		shell = new SDLShell(this);
		shell.video = new SDLOpenGLVideo();
		shell.run();
		shell.video.shutdown();
		return 0;
	}

	long pressed;

	void keyDown(Device device)
	{
		pressed = now;
		auto x = cast(int)(pressed / BAND_HNSECS_PER_PIXEL + BAND_WIDTH/2) % BAND_INTERVAL;
		if (x > BAND_INTERVAL/2)
			x -= BAND_INTERVAL;
		history[device][SampleType.precision] ~= abs(x);
	}

	void keyUp(Device device)
	{
		auto duration = now - pressed;
		history[device][SampleType.duration] ~= cast(int)(duration / BAND_HNSECS_PER_PIXEL);
	}

	override void handleKeyDown(Key key, dchar character)
	{
		if (key == Key.esc)
			shell.quit();
		else
			keyDown(Device.keyboard);
	}

	override void handleKeyUp(Key key)
	{
		keyUp  (Device.keyboard);
	}

	override bool needJoystick() { return true; }

	override void handleJoyButtonDown(int button)
	{
		keyDown(Device.joypad);
	}

	override void handleJoyButtonUp  (int button)
	{
		keyUp  (Device.joypad);
	}

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		keyDown(Device.mouse);
	}

	override void handleMouseUp(uint x, uint y, MouseButton button)
	{
		keyUp  (Device.mouse);
	}

	override void handleQuit()
	{
		shell.quit();
	}
}

shared static this()
{
	createApplication!MyApplication();
}
