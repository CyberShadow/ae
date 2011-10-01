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

/// Space shooter demo.
module ae.demo.pewpew.pewpew;

import std.random;
import std.datetime;
import std.algorithm : min;
import std.conv;

import ae.ui.app.application;
import ae.ui.app.posix.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.video;
import ae.ui.video.sdl.video;
import ae.ui.video.surface;
import ae.ui.video.canvas;
import ae.utils.graphics.gamma;
import ae.utils.fps;

import ae.demo.pewpew.objects;

final class MyApplication : Application
{
	override string getName() { return "Demo/PewPew"; }
	override string getCompanyName() { return "CyberShadow"; }

	uint ticks;
	alias GammaRamp!(COLOR.BaseType, ubyte) MyGamma;
	MyGamma gamma;
	FPSCounter fps;

	static uint currentTick() { return TickDuration.currSystemTick().to!("msecs", uint)(); }

	override void render(Surface s)
	{
		fps.tick(&shell.setCaption);

		auto screenCanvas = BitmapCanvas(s.lock());
		scope(exit) s.unlock();

		if (initializing)
		{
			gamma = MyGamma(ColorSpace.sRGB);
			new Game();
			foreach (i; 0..1000) step(10);
			ticks = currentTick();
			initializing = false;
		}

		//auto destTicks = ticks+deltaTicks;
		uint destTicks = currentTick();
		// step(deltaTicks);
		while (ticks < destTicks)
			ticks++,
			step(1);

		auto canvasSize = min(screenCanvas.w, screenCanvas.h);
		canvas.size(canvasSize, canvasSize);
		canvas.clear(canvas.COLOR.init);
		foreach (plane; planes)
			foreach_reverse (obj; plane)
				obj.render();

		auto x = (screenCanvas.w-canvasSize)/2;
		auto y = (screenCanvas.h-canvasSize)/2;
		auto dest = screenCanvas.window(x, y, x+canvasSize, y+canvasSize);

		import std.parallelism;
		import std.range;
		foreach (j; taskPool.parallel(iota(canvasSize)))
		{
			auto src = canvas.window(0, j, canvasSize, j+1);
			dest.transformDraw!q{
				//COLOR.monochrome(extraArgs[0][c.g]) // won't inline
				COLOR(extraArgs[0][c.g], extraArgs[0][c.g], extraArgs[0][c.g])
			}(src, 0, j, gamma.lum2pixValues.ptr);// +/
		}
	}

	void step(uint deltaTicks)
	{
		foreach (plane; planes)
			foreach_reverse (obj; plane.dup)
				obj.step(deltaTicks);
	}

	override void handleKeyDown(Key key, dchar character)
	{
		switch (key)
		{
			case Key.up   : up   ++; break;
			case Key.down : down ++; break;
			case Key.left : left ++; break;
			case Key.right: right++; break;
			case Key.space: fire ++; break;
			case Key.esc  : shell.quit(); break;
			default       : break;
		}
	}

	override void handleKeyUp(Key key)
	{
		switch (key)
		{
			case Key.up   : up   --; break;
			case Key.down : down --; break;
			case Key.left : left --; break;
			case Key.right: right--; break;
			case Key.space: fire --; break;
			default       : break;
		}
	}

	override bool needJoystick() { return true; }

	int axisInitial[2];
	bool axisCalibrated[2];

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
		void checkDirection(JoystickHatState direction, ref int var)
		{
			if (!(lastState & direction) && (state & direction)) var++;
			if ((lastState & direction) && !(state & direction)) var--;
		}
		checkDirection(JoystickHatState.up   , up   );
		checkDirection(JoystickHatState.down , down );
		checkDirection(JoystickHatState.left , left );
		checkDirection(JoystickHatState.right, right);
		lastState = state;
	}

	override void handleJoyButtonDown(int button)
	{
		fire++;
	}

	override void handleJoyButtonUp  (int button)
	{
		fire--;
	}

	override int run(string[] args)
	{
		shell = new SDLShell();
		video = new SDLVideo();
		shell.run();
		return 0;
	}

	override void handleQuit()
	{
		shell.quit();
	}
}

shared static this()
{
	application = new MyApplication;
}
