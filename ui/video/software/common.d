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
	override void putPixel(int x, int y, COLOR color)
	{
		bitmap.safePut(x, y, color);
	}

	override void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
			bitmap.safePut(pixel.x, pixel.y, pixel.color);
	}

	override void line(float x0, float y0, float x1, float y1, COLOR color)
	{
		bitmap.aaLine(x0, y0, x1, y1, color);
	}

	override void vline(int x, int y0, int y1, COLOR color)
	{
		bitmap.vline(x, y0, y1, color);
	}

	override void hline(int x0, int x1, int y, COLOR color)
	{
		bitmap.hline(x0, x1, y, color);
	}

	override void fillRect(int x0, int y0, int x1, int y1, COLOR color)
	{
		bitmap.fillRect(x0, y0, x1, y1, color);
	}

	override void fillRect(float x0, float y0, float x1, float y1, COLOR color)
	{
		bitmap.aaFillRect(x0, y0, x1, y1, color);
	}

	override void clear()
	{
		bitmap.clear(COLOR.init);
	}

	override void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1)
	{
		auto w = bitmap.window(x, y, x+(u1-u0), y+(v1-v0));
		source.drawTo(w);
	}

	override void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1)
	{
		// assert(0, "TODO");
	}
}
