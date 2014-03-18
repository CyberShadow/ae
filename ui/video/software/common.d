/**
 * ae.ui.video.software.common
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

module ae.ui.video.software.common;


/// Mixin implementing Renderer methods using Canvas.
/// Mixin context: "bitmap" must return a Canvas-like object.
mixin template SoftwareRenderer()
{
	import gd = ae.utils.graphics.draw;

	override void putPixel(int x, int y, COLOR color)
	{
		gd.safePut(bitmap, x, y, color);
	}

	override void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
			gd.safePut(bitmap, pixel.x, pixel.y, pixel.color);
	}

	override void line(float x0, float y0, float x1, float y1, COLOR color)
	{
		gd.aaLine(bitmap, x0, y0, x1, y1, color);
	}

	override void vline(int x, int y0, int y1, COLOR color)
	{
		gd.vline(bitmap, x, y0, y1, color);
	}

	override void hline(int x0, int x1, int y, COLOR color)
	{
		gd.hline(bitmap, x0, x1, y, color);
	}

	override void fillRect(int x0, int y0, int x1, int y1, COLOR color)
	{
		gd.fillRect(bitmap, x0, y0, x1, y1, color);
	}

	override void fillRect(float x0, float y0, float x1, float y1, COLOR color)
	{
		gd.aaFillRect(bitmap, x0, y0, x1, y1, color);
	}

	override void clear()
	{
		gd.clear(bitmap, COLOR.init);
	}

	override void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1)
	{
		auto w = bitmap.crop(x, y, x+(u1-u0), y+(v1-v0));
		source.drawTo(w.toRef());
	}

	override void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1)
	{
		// assert(0, "TODO");
	}
}

unittest
{
	import ae.utils.graphics.color;
	import ae.utils.graphics.image;

	import ae.ui.video.renderer;

	class C : Renderer
	{
		Image!COLOR bitmap;

		mixin SoftwareRenderer;
	}
}
