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
 *   Vladimir Panteleev <ae@cy.md>
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
import ae.utils.regex : escapeRE;

version (linux)
{
	/// Are X11 bindings available?
	enum haveX11 = is(typeof({ import deimos.X11.X; }));
	//version = HAVE_X11;

	static if (haveX11)
	{
		pragma(lib, "X11");

		import deimos.X11.X;
		import deimos.X11.Xlib;
		import deimos.X11.Xutil;
	}

	import std.conv;
	import std.process;

	static if (haveX11)
	{
		private static Display* dpy;

		/// Get X Display, connecting to the X server first
		/// if that hasn't been done yet in this thread.
		/// The connection is closed automatically on thread exit.
		Display* getDisplay()
		{
			if (!dpy)
				dpy = XOpenDisplay(null);
			enforce(dpy, "Can't open display!");
			return dpy;
		}
		static ~this()
		{
			if (dpy)
				XCloseDisplay(dpy);
			dpy = null;
		}
	}

	/// Move the mouse cursor.
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
			enforce(spawnProcess(["xdotool", "mousemove", text(x), text(y)]).wait() == 0, "xdotool failed");
	}

	/// Type used for window IDs.
	static if (haveX11)
		alias Window = deimos.X11.X.Window;
	else
		alias Window = uint;

	/// Return a screen capture of the given window.
	auto captureWindow(Window window)
	{
		static if (haveX11)
		{
			auto g = getWindowGeometry(window);
			return captureWindowRect(window, Rect!int(0, 0, g.w, g.h));
		}
		else
		{
			auto result = execute(["import", "-window", text(window), "bmp:-"]);
			enforce(result.status == 0, "ImageMagick import failed");
			return result.output.parseBMP!BGR();
		}
	}

	/// Return a screen capture of some sub-rectangle of the given window.
	void captureWindowRect(Window window, Rect!int r, ref Image!BGRA image)
	{
		static if (haveX11)
		{
			auto dpy = getDisplay();
			auto ximage = XGetImage(dpy, window, r.x0, r.y0, r.w, r.h, AllPlanes, ZPixmap).xEnforce("XGetImage");
			scope(exit) XDestroyImage(ximage);

			enforce(ximage.format == ZPixmap, "Wrong image format (expected ZPixmap)");
			enforce(ximage.bits_per_pixel == 32, "Wrong image bits_per_pixel (expected 32)");

			alias COLOR = BGRA;
			ImageRef!COLOR(ximage.width, ximage.height, ximage.chars_per_line, cast(PlainStorageUnit!COLOR*) ximage.data).copy(image);
		}
		else
			assert(false, "TODO");
	}

	/// ditto
	auto captureWindowRect(Window window, Rect!int r)
	{
		Image!BGRA image;
		captureWindowRect(window, r, image);
		return image;
	}

	/// Return a capture of some sub-rectangle of the screen.
	auto captureRect(Rect!int r, ref Image!BGRA image)
	{
		static if (haveX11)
		{
			auto dpy = getDisplay();
			return captureWindowRect(RootWindow(dpy, DefaultScreen(dpy)), r, image);
		}
		else
			assert(false, "TODO");
	}

	/// ditto
	auto captureRect(Rect!int r)
	{
		Image!BGRA image;
		captureRect(r, image);
		return image;
	}

	/// Read a single pixel.
	auto getPixel(int x, int y)
	{
		static if (haveX11)
		{
			static Image!BGRA r;
			captureRect(Rect!int(x, y, x+1, y+1), r);
			return r[0, 0];
		}
		else
			assert(false, "TODO");
	}

	/// Find a window using its name.
	/// Throws an exception if there are no results, or there is more than one match.
	Window findWindowByName(string name)
	{
		// TODO haveX11
		auto result = execute(["xdotool", "search", "--name", "^" ~ escapeRE(name) ~ "$"]);
		enforce(result.status == 0, "xdotool failed");
		return result.output.chomp.to!Window;
	}

	/// Obtain a window's coordinates on the screen.
	static if (haveX11)
	Rect!int getWindowGeometry(Window window)
	{
		auto dpy = getDisplay();
		Window child;
		XWindowAttributes xwa;
		XGetWindowAttributes(dpy, window, &xwa).xEnforce("XGetWindowAttributes");
		XTranslateCoordinates(dpy, window, XRootWindow(dpy, 0), xwa.x, xwa.y, &xwa.x, &xwa.y, &child).xEnforce("XTranslateCoordinates");
		return Rect!int(xwa.x, xwa.y, xwa.x + xwa.width, xwa.y + xwa.height);
	}

	private float ease(float t, float speed)
	{
		import std.math : pow, abs;
		speed = 0.3f + speed * 0.4f;
		t = t * 2 - 1;
		t = (1-pow(1-abs(t), 1/speed)) * sign(t);
		t = (t + 1) / 2;
		return t;
	}

	static if (haveX11)
	private T xEnforce(T)(T cond, string msg)
	{
		return enforce(cond, msg);
	}

	/// Smoothly move the mouse from one coordinate to another.
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

	/// Send a mouse button press or release.
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
