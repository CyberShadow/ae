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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.demo.drawsprite.main;

import ae.ui.app.application;
import ae.ui.app.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.sdl.video;
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

	override void render(Renderer s)
	{
		fps.tick(&shell.setCaption);

		auto canvas = s.lock();
		scope(exit) s.unlock();

		int x0 = (canvas.w - image.w) / 2;
		int y0 = (canvas.h - image.h) / 2;
		canvas.draw(x0, y0, image);
	}

	override int run(string[] args)
	{
		Image!BGR lena;
		lena.loadBMP("lena.bmp");
		image = lena.convert!`BGRX(c.b, c.g, c.r)`();

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
