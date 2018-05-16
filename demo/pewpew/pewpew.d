/**
 * Space shooter demo.
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

module ae.demo.pewpew.pewpew;

import std.algorithm.iteration;
import std.math;
import std.random;
import std.datetime;
import std.algorithm : min;
import std.conv;
import std.range;
import std.traits, std.typecons;

import ae.ui.app.application;
import ae.ui.app.posix.main;
import ae.ui.audio.mixer.software;
import ae.ui.audio.sdl2.audio;
import ae.ui.audio.source.memory;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;
import ae.ui.video.video;
import ae.ui.video.sdl2.video;
import ae.ui.video.renderer;
import ae.utils.graphics.draw;
import ae.utils.graphics.gamma;
import ae.utils.fps;
import ae.utils.meta;
import ae.utils.sound.wave;

import ae.demo.pewpew.objects;

final class MyApplication : Application
{
	override string getName() { return "Demo/PewPew"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;
	uint ticks;
	alias GammaRamp!(COLOR.ChannelType, ubyte) MyGamma;
	MyGamma gamma;
	FPSCounter fps;

	static uint currentTick() { return TickDuration.currSystemTick().to!("msecs", uint)(); }

	enum InputSource { keyboard, joystick, max }
	enum GameKey { up, down, left, right, fire, none }

	int[InputSource.max][GameKey.max] inputMatrix;

	MemorySoundSource!short sndShoot, sndWarpIn;

	override void render(Renderer s)
	{
		fps.tick(&shell.setCaption);

		auto screenCanvas = s.lock();
		scope(exit) s.unlock();

		if (initializing)
		{
			gamma = MyGamma(ColorSpace.sRGB);
			new Game();
			foreach (i; 0..1000) step(10);
			ticks = currentTick();
			initializing = false;
		}

		foreach (i, key; EnumMembers!GameKey[0..$-1])
		{
			enum name = __traits(allMembers, GameKey)[i];
			bool pressed;
			foreach (input; inputMatrix[key])
				if (input)
					pressed = true;
			mixin(name ~ " = pressed;");
		}

		//auto destTicks = ticks+deltaTicks;
		uint destTicks = currentTick();
		// step(deltaTicks);
		while (ticks < destTicks)
			ticks++,
			step(1);

		auto canvasSize = min(screenCanvas.w, screenCanvas.h);
		canvas.size(canvasSize, canvasSize);
		canvas.fill(canvas.COLOR.init);
		foreach (ref plane; planes)
			foreach (obj; plane)
				obj.render();

		auto x = (screenCanvas.w-canvasSize)/2;
		auto y = (screenCanvas.h-canvasSize)/2;
		auto dest = screenCanvas.crop(x, y, x+canvasSize, y+canvasSize);

		import std.parallelism;
		import std.range;
		foreach (j; taskPool.parallel(iota(canvasSize)))
		{
			auto src = canvas.crop(0, j, canvasSize, j+1);
			auto ramp = gamma.lum2pixValues.ptr;
			src.colorMap!(c => Renderer.COLOR.monochrome(ramp[c.l])).blitTo(dest, 0, j);
		}

		foreach (sound; sounds)
			final switch (sound)
			{
				case Sound.fire:
					shell.audio.mixer.playSound(sndShoot);
					break;
				case Sound.warpIn:
					shell.audio.mixer.playSound(sndWarpIn);
					break;
			}
		sounds = null;
	}

	void step(uint deltaTicks)
	{
		foreach (ref plane; planes)
			foreach (obj; plane)
				obj.step(deltaTicks);
	}

	GameKey keyToGameKey(Key key)
	{
		switch (key)
		{
			case Key.up   : return GameKey.up   ;
			case Key.down : return GameKey.down ;
			case Key.left : return GameKey.left ;
			case Key.right: return GameKey.right;
			case Key.space: return GameKey.fire ;
			default       : return GameKey.none ;
		}
	}

	override void handleKeyDown(Key key, dchar character)
	{
		auto gameKey = keyToGameKey(key);
		if (gameKey != GameKey.none)
			inputMatrix[gameKey][InputSource.keyboard]++;
		else
		if (key == Key.esc)
			shell.quit();
	}

	override void handleKeyUp(Key key)
	{
		auto gameKey = keyToGameKey(key);
		if (gameKey != GameKey.none)
			inputMatrix[gameKey][InputSource.keyboard] = 0;
	}

	override bool needJoystick() { return true; }

	int[2] axisInitial;
	bool[2] axisCalibrated;

	override void handleJoyAxisMotion(int axis, short svalue)
	{
		if (axis >= 2) return;

		int value = svalue;
		if (!axisCalibrated[axis]) // assume first input event is inert
			axisInitial[axis] = value,
			axisCalibrated[axis] = true;
		value -= axisInitial[axis];

		import ae.utils.math;
		if (abs(value) > short.max/2) // hack?
			useAnalog = true;
		auto fvalue = bound(cast(float)value / short.max, -1f, 1f);
		(axis==0 ? analogX : analogY) = fvalue;
	}

	JoystickHatState lastState = cast(JoystickHatState)0;

	override void handleJoyHatMotion (int hat, JoystickHatState state)
	{
		void checkDirection(JoystickHatState direction, GameKey key)
		{
			if (!(lastState & direction) && (state & direction)) inputMatrix[key][InputSource.joystick]++;
			if ((lastState & direction) && !(state & direction)) inputMatrix[key][InputSource.joystick]--;
		}
		checkDirection(JoystickHatState.up   , GameKey.up   );
		checkDirection(JoystickHatState.down , GameKey.down );
		checkDirection(JoystickHatState.left , GameKey.left );
		checkDirection(JoystickHatState.right, GameKey.right);
		lastState = state;
	}

	override void handleJoyButtonDown(int button)
	{
		inputMatrix[GameKey.fire][InputSource.joystick]++;
	}

	override void handleJoyButtonUp  (int button)
	{
		inputMatrix[GameKey.fire][InputSource.joystick]--;
	}

	private final void genSounds()
	{
		enum sr = 44100;
		sndShoot = (sr*2/3)
			.I!(dur =>
				dur.iota.map!(n =>
					cast(short)(whiteNoise!short[cast(size_t)(n / (n / 10000.0 + 5))] / 4)
			)).retro.fade.array.memorySoundSource(sr);
		{
			enum freq = 1000;
			sndWarpIn = (sr*3).I!(dur => dur.iota.map!(n => n % freq < (freq * n / dur) ? short.init : short.max))
				.array.memorySoundSource(sr);
		}
	}

	override int run(string[] args)
	{
		genSounds();

		shell = new SDL2Shell(this);
		shell.video = new SDL2SoftwareVideo();

		shell.audio = new SDL2Audio();
		shell.audio.mixer = new SoftwareMixer();

		shell.run();
		shell.video.shutdown();
		return 0;
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
