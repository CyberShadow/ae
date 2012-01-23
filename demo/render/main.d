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

module ae.demo.render.main;

import std.random;

import ae.ui.app.application;
import ae.ui.app.posix.main;
import ae.ui.shell.shell;
import ae.ui.shell.sdl.shell;
import ae.ui.video.sdl.video;
import ae.ui.video.sdlopengl.video;
import ae.ui.video.renderer;
import ae.ui.timer.sdl.timer;
import ae.ui.timer.thread.timer;
import ae.utils.fps;
import ae.utils.graphics.image;

final class MyApplication : Application
{
	override string getName() { return "Demo/Render"; }
	override string getCompanyName() { return "CyberShadow"; }

	Shell shell;
	Timer timer;
	FPSCounter fps;
	Renderer.Pixel[] pixels;
	bool useOpenGL, switching;
	float x=0f, y=0f, dx=0f, dy=0f;
	enum DELTA = 1f / 256;
	ImageTextureSource[5] imgs;
	ImageTextureSource imgT;

	this()
	{
		foreach (x; 0..256)
			foreach (y; 0..256)
				pixels ~= Renderer.Pixel(x, y, BGRX(cast(ubyte)x, cast(ubyte)y, 0));

		foreach (ubyte r; 0..2)
		foreach (ubyte g; 0..2)
		foreach (ubyte b; 0..2)
		pixels ~= Renderer.Pixel(300 + r*3 + b*12, 100 + g*3, BGRX(cast(ubyte)(r*255), cast(ubyte)(g*255), cast(ubyte)(b*255)));
	}

	void updateFPS(string fps)
	{
		shell.setCaption((useOpenGL ? "SDL/OpenGL" : "SDL/Software") ~ " - " ~ fps);
	}

	override void render(Renderer s)
	{
		fps.tick(&updateFPS);

		//pixels ~= Renderer.Pixel(uniform(0, s.width), uniform(0, s.height), BGRX(uniform!ubyte(), uniform!ubyte(), uniform!ubyte()));
		s.clear();
		s.putPixels(pixels);

		foreach (i, img; imgs)
		{
			s.draw(i*128, 300, img, 0, 0, img.image.w, img.image.h);
			s.draw(
				i*128 + x+img.image.w/4  , 428 + img.image.h/4  ,
				i*128 + x+img.image.w/4*3, 428 + img.image.h/4*3,
				img, 0, 0, img.image.w, img.image.h);
		}

		static int offset;
		offset++;
		auto w = imgT.image.window(0, 0, imgT.image.w, imgT.image.h);
		for (int l=5; l>=0; l--)
		{
			checker(w, l, l%2 ? 0 : (offset%60==0?offset+0:offset) >> (3-l/2));
			w = w.window(w.w/4, w.h/4, w.w/4*3, w.h/4*3);
		}
		imgT.textureVersion++;
		s.draw(400, 50, imgT, 0, 0, imgT.image.w, imgT.image.h);
	}

	void checker(CANVAS)(CANVAS img, int level, int offset)
	{
		foreach (y; 0..img.h)
			foreach (x; 0..img.w)
				if (x==0 || y==0 || x==img.w-1 || y==img.h-1)
					img[x, y] = BGRX(255, 0, 0);
				else
				if (level && ((x+offset)/(1<<(level-1))+y/(1<<(level-1)))%2)
					img[x, y] = BGRX(255, 255, 255);
				else
					img[x, y] = BGRX(0, 0, 0);
	}

	override int run(string[] args)
	{
		{
			enum W = 96, H = 96;

			foreach (i, ref img; imgs)
			{
				img = new ImageTextureSource;
				img.image.size(W, H);
				checker(img.image, i, 0);
			}

			imgT = new ImageTextureSource;
			imgT.image.size(W*2, H*2);
		}

		shell = new SDLShell(this);
		auto sdl    = new SDLVideo();
		auto opengl = new SDLOpenGLVideo();
	//	opengl.aa = false;

		timer = new SDLTimer();
		//timer = new ThreadTimer();
		timer.setInterval(AppCallback({ x += dx; y += dy; }), 10);

		do
		{
			switching = false;
			useOpenGL = !useOpenGL;
			shell.video = useOpenGL ? opengl : sdl;
			updateFPS("?");
			shell.run();
		} while (switching);
		sdl.shutdown();
		opengl.shutdown();
		return 0;
	}

	override void handleKeyDown(Key key, dchar character)
	{
		switch (key)
		{
		case Key.space:
			switching = true;
			goto case;
		case Key.esc:
			shell.quit();
			break;
		case Key.left : dx = -DELTA; break;
		case Key.right: dx = +DELTA; break;
		case Key.up   : dy = -DELTA; break;
		case Key.down : dy = +DELTA; break;
		default:
			break;
		}
	}

	override void handleKeyUp(Key key)
	{
		switch (key)
		{
		case Key.left : dx = 0f; break;
		case Key.right: dx = 0f; break;
		case Key.up   : dy = 0f; break;
		case Key.down : dy = 0f; break;
		default:
			break;
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
