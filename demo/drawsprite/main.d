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
 * Portions created by the Initial Developer are Copyright (C) 2012
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
		canvas.draw(image, x0, y0);
	}

	override int run(string[] args)
	{
		Image!BGR lena;
		lena.loadBMP("lena.bmp");
		image = lena.convert!`BGRX(c.b, c.g, c.r)`();

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
