/**
 * Control, screen-scrape, and send input to other
 * graphical programs.
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

module ae.sys.sendinput;

import core.thread;
import core.time;

import std.exception;
import std.random;
import std.string;

import ae.utils.graphics.color;
import ae.utils.graphics.image;
import ae.utils.geometry : Rect;
import ae.utils.math;

version (linux)
{
	enum haveX11 = is(typeof({ import deimos.X11.X; }));
	//version = HAVE_X11;

	static if (haveX11)
	{
		pragma(lib, "X11");

		import deimos.X11.X;
		import deimos.X11.Xlib;
	}

	import std.conv;
	import std.process;

	private Display* getDisplay()
	{
		static Display* dpy;
		if (!dpy)
			dpy = XOpenDisplay(null);
		enforce(dpy, "Can't open display!");
		return dpy;
	}

	void setMousePos(int x, int y)
	{
		static if (haveX11)
		{
			auto dpy = getDisplay();
			auto rootWindow = XRootWindow(dpy, 0);
			XSelectInput(dpy, rootWindow, KeyReleaseMask);
			XWarpPointer(dpy, None, rootWindow, 0, 0, 0, 0, x, y);
			XFlush(dpy);
		}
		else
			enforce(spawnProcess(["xdotool", "mousemove", text(windowX + x), text(windowY + y)]).wait() == 0, "xdotool failed");
	}

	alias Window = deimos.X11.X.Window;

	Image!BGR captureWindow(Window window)
	{
		// TODO haveX11
		auto result = execute(["import", "-window", text(window), "bmp:-"]);
		enforce(result.status == 0, "ImageMagick import failed");
		return result.output.parseBMP!BGR();
	}

	Window findWindowByName(string name)
	{
		// TODO haveX11
		auto result = execute(["xdotool", "search", "--name", name]);
		enforce(result.status == 0, "xdotool failed");
		return result.output.chomp.to!Window;
	}

	Rect!int getWindowGeometry(Window window)
	{
		auto dpy = getDisplay();
		Window child;
		XWindowAttributes xwa;
		XGetWindowAttributes(dpy, window, &xwa);
		XTranslateCoordinates(dpy, window, XRootWindow(dpy, 0), xwa.x, xwa.y, &xwa.x, &xwa.y, &child);
		return Rect!int(xwa.x, xwa.y, xwa.x + xwa.width, xwa.y + xwa.height);
	}

	float ease(float t, float speed)
	{
		speed = 0.3f + speed * 0.4f;
		t = t * 2 - 1;
		t = (1-pow(1-abs(t), 1/speed)) * sign(t);
		t = (t + 1) / 2;
		return t;
	}

	void easeMousePos(int x0, int y0, int x1, int y1, Duration duration)
	{
		auto xSpeed = uniform01!float;
		auto ySpeed = uniform01!float;

		auto start = MonoTime.currTime();
		auto end = start + duration;
		while (true)
		{
			auto now = MonoTime.currTime();
			if (now >= end)
				break;
			float t = 1f * (now - start).total!"hnsecs" / duration.total!"hnsecs";
			setMousePos(
				x0 + cast(int)(ease(t, xSpeed) * (x1 - x0)),
				y0 + cast(int)(ease(t, ySpeed) * (y1 - y0)),
			);
			Thread.sleep(1.msecs);
		}
		x0 = x1;
		y0 = y1;

		setMousePos(x1, y1);
	}

	void mouseButton(int button, bool down)
	{
		// TODO haveX11
		enforce(spawnProcess(["xdotool", down ? "mousedown" : "mouseup", text(button)]).wait() == 0, "xdotool failed");
	}
}

version (Windows)
{
	// TODO
}
