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
import ae.ui.video.surface;
import ae.ui.video.canvas;
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

	override void render(Surface s)
	{
		fps.tick(&shell.setCaption);

		auto canvas = BitmapCanvas(s.lock());
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
				return canvas[randX(), randY()] = randColor();

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
