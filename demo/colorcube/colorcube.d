/**
 * 3D visualizer of used colors in an image
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

module ae.demo.colorcube.colorcube;

import std.datetime;
import std.parallelism;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.video;
import ae.ui.video.sdl.video;
import ae.ui.video.renderer;
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

	override void render(Renderer s)
	{
		fps.tick(&shell.setCaption);

		auto canvas = s.lock();
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
		shell.video.shutdown();
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
