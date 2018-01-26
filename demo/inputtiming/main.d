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

import std.conv;
import std.format;
import std.math;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.audio.mixer.software;
import ae.ui.audio.sdl2.audio;
import ae.ui.audio.source.base;
import ae.ui.audio.source.memory;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;
import ae.ui.video.bmfont;
import ae.ui.video.renderer;
import ae.ui.video.sdl2.video;
import ae.utils.fps;
import ae.utils.graphics.fonts.draw;
import ae.utils.graphics.fonts.font8x8;
import ae.utils.math;
import ae.utils.graphics.image;
import ae.utils.meta;

final class MyApplication : Application
{
	override string getName() { return "Demo/Input"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;

	enum BAND_WIDTH = 800;
	enum BAND_INTERVAL = 100;
	enum BAND_TOP = 50;
	enum BAND_HEIGHT = 30;
	enum BAND_HNSECS_PER_PIXEL = 10_000_0;
	enum HISTORY_TOP = 150;
	enum HISTORY_HEIGHT = 50;
	enum HISTORY_LEFT = 150;

	enum Mode { video, audio }
	enum Device : int { keyboard, joypad, mouse }
	enum SampleType : int { precision, duration }

	int[][enumLength!SampleType][enumLength!Device] history;
	Mode mode;
	enum SAMPLE_COLORS = [BGRX(0, 0, 255), BGRX(0, 255, 0)];

	/// Some (precise) time value of the moment, in hnsecs.
	@property long now() { return TickDuration.currSystemTick.to!("hnsecs", long); }

	FontTextureSource!Font8x8 font;
	MemorySoundSource!SoundSample tick;

	this()
	{
		font = new FontTextureSource!Font8x8(font8x8, BGRX(128, 128, 128));
		tick = memorySoundSource([short.max, short.min], 44100);
	}

	override bool needSound() { return true; }

	static long lastTick;

	override void render(Renderer s)
	{
		s.clear();
		auto t = now;

		if (!lastTick)
		{
			shell.setCaption("Press m to switch mode, Esc to exit, any other key to measure latency");
			lastTick = t;
		}

		final switch (mode)
		{
			case Mode.video:
			{
				auto x = t / BAND_HNSECS_PER_PIXEL;
				s.line(BAND_WIDTH/2, BAND_TOP, BAND_WIDTH/2, BAND_TOP + BAND_HEIGHT, BGRX(0, 0, 255));
				foreach (lx; 0..BAND_WIDTH)
					if ((lx+x)%BAND_INTERVAL == 0)
						s.line(lx, BAND_TOP+BAND_HEIGHT, lx, BAND_TOP+BAND_HEIGHT*2, BGRX(0, 255, 0));
				break;
			}
			case Mode.audio:
			{
				auto str = "Press a key when you hear the tick sound";
				font.drawText(s, (BAND_WIDTH - str.length.to!int * font.font.maxWidth)/2, BAND_TOP+BAND_HEIGHT, str);
				enum sampleInterval = BAND_HNSECS_PER_PIXEL * BAND_INTERVAL;
				if (t / sampleInterval != lastTick / sampleInterval)
					shell.audio.mixer.playSound(tick);
				break;
			}
		}

		foreach (device, deviceSamples; history)
			foreach (sampleType, samples; deviceSamples)
			{
				auto y = HISTORY_TOP + HISTORY_HEIGHT * (device*3 + sampleType*2 + 1);
				s.line(0, y - HISTORY_HEIGHT, s.width, y - HISTORY_HEIGHT, BGRX.monochrome(0x40));
				foreach (index, sample; samples)
				{
					if (sample > HISTORY_HEIGHT)
						sample = HISTORY_HEIGHT;
					s.line(HISTORY_LEFT + index, y - sample, HISTORY_LEFT + index, y, SAMPLE_COLORS[sampleType]);
				}
			}

		foreach (Device device, deviceSamples; history)
			foreach (SampleType sampleType, samples; deviceSamples)
			{
				auto y = HISTORY_TOP + HISTORY_HEIGHT * (device*3 + sampleType*2 + 1);
				if (sampleType == SampleType.duration) y -= HISTORY_HEIGHT/2;
				y -= font.font.height / 2;
				font.drawText(s, 2, y.to!int, "%8s %-9s".format(device, sampleType));
			}

		lastTick = t;
	}

	override int run(string[] args)
	{
		shell = new SDL2Shell(this);
		shell.video = new SDL2Video();

		shell.audio = new SDL2Audio();
		shell.audio.mixer = new SoftwareMixer();

		shell.run();
		shell.video.shutdown();
		return 0;
	}

	long pressed;

	void keyDown(Device device)
	{
		// Skip keyDown events without corresponding keyUp
		if (history[device][SampleType.precision].length > history[device][SampleType.duration].length)
			return;

		pressed = now;
		auto x = cast(int)(pressed / BAND_HNSECS_PER_PIXEL + BAND_WIDTH/2) % BAND_INTERVAL;
		if (x > BAND_INTERVAL/2)
			x -= BAND_INTERVAL;
		history[device][SampleType.precision] ~= x;
	}

	void keyUp(Device device)
	{
		auto duration = now - pressed;
		history[device][SampleType.duration] ~= cast(int)(duration / BAND_HNSECS_PER_PIXEL);
	}

	bool ignoreKeyUp;

	override void handleKeyDown(Key key, dchar character)
	{
		ignoreKeyUp = true;
		if (key == Key.esc)
			shell.quit();
		else
		if (character == 'm')
			mode++, mode %= enumLength!Mode;
		else
		if (character == 's')
			shell.audio.mixer.playSound(tick);
		else
		{
			keyDown(Device.keyboard);
			ignoreKeyUp = false;
		}
	}

	override void handleKeyUp(Key key)
	{
		if (ignoreKeyUp)
			ignoreKeyUp = false;
		else
			keyUp(Device.keyboard);
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
