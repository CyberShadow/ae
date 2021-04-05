/**
 * ae.demo.drawsprite.main
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.demo.drawsprite.main;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl2.shell;
import ae.ui.video.sdl2.video;
import ae.ui.video.renderer;
import ae.utils.fps;
import ae.utils.graphics.image;

final class MyApplication : Application
{
	override string getName() { return "Demo/DrawSprite"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;
	FPSCounter fps;
	Image!BGRX image;
	enum SCALE_BASE = 0x10000;

	ImageTextureSource source;

	override void render(Renderer s)
	{
		fps.tick(&shell.setCaption);

		//auto canvas = s.lock();
		//scope(exit) s.unlock();

		xy_t x0 = (s.width  - image.w) / 2;
		xy_t y0 = (s.height - image.h) / 2;
		//image.blitTo(canvas, x0, y0);
		s.draw(cast(int)x0, cast(int)y0, source, 0, 0, cast(int)image.w, cast(int)image.h);
	}

	override int run(string[] args)
	{
		import std.file : read;
		image = read("lena.bmp")
			.parseBMP!BGR()
			.colorMap!(c => BGRX(c.b, c.g, c.r))
			.copy();
		source = new ImageTextureSource;
		source.image = image;

		shell = new SDL2Shell(this);
		shell.video = new SDL2Video();
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
