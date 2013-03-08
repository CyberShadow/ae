/**
 * ae.demo.test.main
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

module ae.demo.test.main;

import std.conv;

import ae.ui.app.application;
import ae.ui.app.posix.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.renderer;
import ae.ui.video.sdl.video;
import ae.ui.video.video;
import ae.ui.wm.application;
import ae.ui.wm.controls.control;

final class MyApplication : WMApplication
{
	override string getName() { return "Demo/UI"; }
	override string getCompanyName() { return "CyberShadow"; }

	override int run(string[] args)
	{
		shell = new SDLShell(this);
		shell.video = new SDLVideo();
		root.addChild(createView());
		shell.run();
		shell.video.shutdown();
		return 0;
	}

	Control createView()
	{
		return (new Table(2, 2))
			.addChild((new Pad(10.px, 5.percent)).addChild(new SetBGColor!(PaintControl, 0x002222)))
			.addChild((new Pad(10.px, 5.percent)).addChild(new SetBGColor!(PaintControl, 0x220022)))
			.addChild((new Pad(10.px, 5.percent)).addChild(new SetBGColor!(PaintControl, 0x222200)))
			.addChild((new Pad(10.px, 5.percent)).addChild(new SetBGColor!(PaintControl, 0x002200)))
		;
	}
}

shared static this()
{
	createApplication!MyApplication();
}

// ***************************************************************************

import ae.utils.meta;

/// Subclass any control to give it an arbitrary background color.
class SetBGColor(BASE : Control, uint C) : BASE
{
	mixin GenerateContructorProxies;

	enum BGRX color = BGRX(C&0xFF, (C>>8)&0xFF, C>>16);

	override void render(Renderer s, int x, int y)
	{
		s.fillRect(x, y, x+w, y+h, color);
		super.render(s, x, y);
	}
}

// ***************************************************************************

class PaintControl : Control
{
	override void arrange(int rw, int rh) { w = rw; h = rh; }

	struct Coord { uint x, y; BGRX c; void* dummy; }
	Coord[] coords;

	override void handleMouseMove(int x, int y, MouseButtons buttons)
	{
		if (buttons)
		{
			uint b = cast(uint)buttons;
			ubyte channel(ubyte m) { return ((b>>m)&1) ? 0xFF : 0; }
			coords ~= Coord(x, y, BGRX(channel(2), channel(1), channel(0)));
		}
	}

	override void render(Renderer s, int x, int y)
	{
		//foreach (i; 0..100)
		//	coords ~= Coord(uniform(0, w), uniform(0, h), uniform(0, 0x1_00_00_00));
		static size_t oldCoordsLength;
		if (coords.length != oldCoordsLength)
		{
			//shell.setCaption(to!string(coords.length));
			oldCoordsLength = coords.length;
		}

		// if (coords.length > 100) throw new Exception("derp");

		auto b = s.lock();
		foreach (coord; coords)
			if (coord.x < w && coord.y < h)
				b[x+coord.x, y+coord.y] = coord.c;
		s.unlock();
	}
}
