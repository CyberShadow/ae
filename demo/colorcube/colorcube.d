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

/// 3D visualizer of used colors in an image
module ae.demo.colorcube.colorcube;

import std.datetime;
import std.parallelism;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.video;
import ae.ui.video.sdl.video;
import ae.ui.video.surface;
import ae.ui.video.canvas;
import ae.utils.fps;
import ae.utils.graphics.image;
import ae.utils.array;

final class MyApplication : Application
{
	override string getName() { return "Demo/ColorCube"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;
	FPSCounter fps;

	int dx, dy;
	real ax=0, ay=0;

	struct Pixel
	{
		BGRX color;
		int x0, y0, z0;
		int x, y, z;

		this(ubyte r, ubyte g, ubyte b)
		{
			color = BGRX(b, g, r);
			x0 = r-128;
			y0 = g-128;
			z0 = b-128;
		}

		void rotate(real sinx, real cosx, real siny, real cosy)
		{
			auto z1 = x0 *-siny + z0 * cosy;
			x = cast(int)(10000 + x0 * cosy + z0 * siny) - 10000; // hack: this is faster than lrint
			y = cast(int)(10000 + y0 * cosx - z1 * sinx) - 10000;
			z = cast(int)(10000 + y0 * sinx + z1 * cosx) - 10000;
		}
	}

	Pixel[] pixels;

	SysTime lastFrame;

	/// Angular rotation speed (radians per second)
	enum RV = PI; // per second

	override void render(Surface s)
	{
		fps.tick(&shell.setCaption);

		auto canvas = BitmapCanvas(s.lock());
		scope(exit) s.unlock();

		auto now = Clock.currTime();
		auto frameDuration = (now - lastFrame).total!"usecs" / 1_000_000f; // fractionary seconds
		lastFrame = now;

		ay += dx*RV*frameDuration;
		ax += dy*RV*frameDuration;

		auto sinx = sin(ax);
		auto cosx = cos(ax);
		auto siny = sin(ay);
		auto cosy = cos(ay);

		foreach (ref pixel; parallel(pixels))
			pixel.rotate(sinx, cosx, siny, cosy);
		auto newPixels = countSort!`a.z`(pixels);
		delete pixels; pixels = newPixels; // avoid memory leak

		canvas.clear(BGRX.init);
		foreach (ref pixel; pixels)
			canvas.safePut(
				canvas.w/2 + pixel.x,
				canvas.h/2 + pixel.y,
				pixel.color);
	}

	override int run(string[] args)
	{
		if (args.length < 2)
			throw new Exception("No file specified - please specify a 24-bit .BMP file");

		Image!BGR image;
		image.loadBMP(args[1]);

		//static bool havePixel[256][256][256];
		auto havePixel = new bool[256][256][256];

		static bool extreme(uint b) { return b==0 || b==255; }

		// Uncomment for bounding axes
		/*foreach (r; 0..256)
			foreach (g; 0..256)
				foreach (b; 0..256)
					havePixel[r][g][b] =
						//(r+g+b)%101 == 0 ||
						(extreme(r) && extreme(g)) ||
						(extreme(r) && extreme(b)) ||
						(extreme(g) && extreme(b));*/

		foreach (y; 0..image.h)
			foreach (x; 0..image.w)
			{
				auto c = image[x, y];
				havePixel[c.r][c.g][c.b] = true;
			}

		foreach (r; 0..256)
			foreach (g; 0..256)
				foreach (b; 0..256)
					if (havePixel[r][g][b])
						pixels ~= Pixel(cast(ubyte)r, cast(ubyte)g, cast(ubyte)b);

		shell = new SDLShell(this);
		shell.video = new SDLVideo();
		shell.run();
		return 0;
	}

	override void handleKeyDown(Key key, dchar character)
	{
		switch (key)
		{
			case Key.up   : dy = -1; break;
			case Key.down : dy = +1; break;
			case Key.left : dx = -1; break;
			case Key.right: dx = +1; break;
			case Key.esc  : shell.quit(); break;
			default       : break;
		}
	}

	override void handleKeyUp(Key key)
	{
		switch (key)
		{
			case Key.up   :
			case Key.down : dy = 0; break;
			case Key.left :
			case Key.right: dx = 0; break;
			default       : break;
		}
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
