/**
 * ae.demo.canvas.main
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

module ae.demo.canvas.main;

import std.random;
import std.algorithm : min, max;
import std.datetime, std.conv;

import ae.ui.app.application;
import ae.ui.app.posix.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.video;
import ae.ui.video.sdl.video;
import ae.ui.video.renderer;
import ae.utils.math;
import ae.utils.geometry;
import ae.utils.fps;

final class MyApplication : Application
{
	override string getName() { return "Demo/Canvas"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;
	FPSCounter fps;
	bool first = true;

	override void render(Renderer s)
	{
		fps.tick(&shell.setCaption);

		auto canvas = s.lock();
		scope(exit) s.unlock();

		ubyte randByte() { return cast(ubyte)uniform(0, 256); }
		BGRX randColor() { return BGRX(randByte(), randByte(), randByte()); }
		int randX() { return uniform(0, canvas.w); }
		int randY() { return uniform(0, canvas.h); }

		enum Shape
		{
			pixel, hline, vline, line, rect, fillRect, fillRect2, circle, sector, poly,
			softCircle, softRing, aaLine,
		}

		static Shape shape;
		if (first)
			canvas.whiteNoise(),
			shape = cast(Shape) uniform!"(]"(0, Shape.max),
			first = false;

		final switch (shape)
		{
			case Shape.pixel:
				canvas[randX(), randY()] = randColor();
				return;

			case Shape.hline:
				return canvas.hline(randX(), randX(), randY(), randColor());
			case Shape.vline:
				return canvas.vline(randX(), randY(), randY(), randColor());
			case Shape.line:
				return canvas.line(randX(), randY(), randX(), randY(), randColor());

			case Shape.rect:
				return canvas.rect    (randX(), randY(), randX(), randY(), randColor());
			case Shape.fillRect:
				return canvas.fillRect(randX(), randY(), randX(), randY(), randColor());
			case Shape.fillRect2:
				return canvas.fillRect(randX(), randY(), randX(), randY(), randColor(), randColor());

			case Shape.circle:
			{
				int r = uniform(10, 100);
				return canvas.fillCircle(uniform(r, canvas.w-r), uniform(r, canvas.h-r), r, randColor());
			}
			case Shape.sector:
			{
				int r1 = uniform(10, 100);
				int r0 = uniform(0, r1);
				return canvas.fillSector(uniform(r1, canvas.w-r1), uniform(r1, canvas.h-r1), r0, r1, uniform(0, TAU), uniform(0, TAU), randColor());
			}
			case Shape.poly:
			{
				auto coords = new Coord[uniform(3, 10)];
				foreach (ref coord; coords)
					coord = Coord(randX(), randY());
				return canvas.fillPoly(coords, randColor());
			}
			case Shape.softCircle:
			{
				int r1 = uniform(10, 100);
				int r0 = uniform(0, r1-5);
				return canvas.softCircle(uniform(r1, canvas.w-r1), uniform(r1, canvas.h-r1), r0, r1, randColor());
			}
			case Shape.softRing:
			{
				int r2 = uniform(15, 100);
				int r0 = uniform(0, r2-10);
				int r1 = uniform(r0+5, r2-5);
				return canvas.softRing(uniform(r2, canvas.w-r2), uniform(r2, canvas.h-r2), r0, r1, r2, randColor());
			}
			case Shape.aaLine:
				return canvas.aaLine(randX(), randY(), randX(), randY(), randColor());
		}
	}

	override void handleMouseDown(uint x, uint y, MouseButton button)
	{
		first = true;
	}

	override bool setWindowSize(uint x, uint y)
	{
		first = true;
		return super.setWindowSize(x, y);
	}

	override int run(string[] args)
	{
		shell = new SDLShell(this);
		shell.video = new SDLVideo();
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
