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

module ae.demo.canvas.main;

import std.random;
import std.algorithm : min, max;
import std.datetime, std.conv;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.video;
import ae.ui.video.sdl.video;
import ae.ui.video.surface;
import ae.ui.video.canvas;
import ae.utils.math;

final class MyApplication : Application
{
	override string getName() { return "Demo/Canvas"; }
	override string getCompanyName() { return "CyberShadow"; }

	int frames, lastSecond;

	override void render(Surface s)
	{
		frames++;
		auto thisSecond = Clock.currTime().second;
		if (thisSecond != lastSecond)
		{
			shell.setCaption(to!string(frames));
			frames = 0;
			lastSecond = thisSecond;
		}

		auto canvas = BitmapCanvas(s.lock());
		scope(exit) s.unlock();

		ubyte randByte() { return cast(ubyte)uniform(0, 256); }
		BGRX randColor() { return BGRX(randByte(), randByte(), randByte()); }
		int randX() { return uniform(0, canvas.w); }
		int randY() { return uniform(0, canvas.h); }

		static bool first = true;
		if (first)
			canvas.whiteNoise(),
			first = false;

		enum Shape
		{
			pixel, hline, vline, rect, fillRect, fillRect2, circle, sector, poly,
			softEdgedCircle, aaLine,
		}
		final switch (cast(Shape) uniform!"[]"(0, Shape.max))
		{
			case Shape.pixel:
				return canvas[randX(), randY()] = randColor();

			case Shape.hline:
				return canvas.hline(randX(), randX(), randY(), randColor());
			case Shape.vline:
				return canvas.vline(randX(), randY(), randY(), randColor());

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
			case Shape.softEdgedCircle:
			{
				int r1 = uniform(10, 100);
				int r0 = uniform(0, r1-5);
				return canvas.softEdgedCircle(uniform(r1, canvas.w-r1), uniform(r1, canvas.h-r1), r0, r1, randColor());
			}
			case Shape.aaLine:
				return canvas.aaLine(randX(), randY(), randX(), randY(), randColor());
		}
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
