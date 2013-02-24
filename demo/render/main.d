/**
 * ae.demo.render.main
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

		s.vline(300, 25,       75, BGRX(255, 0, 0));
		s. line(300, 25, 350,  75, BGRX(0, 255, 0));
		s.hline(300,     350,  25, BGRX(0, 0, 255));

		foreach (uint i, img; imgs)
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
