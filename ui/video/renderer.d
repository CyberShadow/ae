/**
 * ae.ui.video.renderer
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

module ae.ui.video.renderer;

public import ae.utils.graphics.canvas;

/// Abstract class for a video renderer.
class Renderer
{
	alias BGRX COLOR;

	// TODO: can we expect all hardware surfaces to be in this format? What can we do if they aren't?
	/// BGRX/BGRA-only.
	struct Bitmap
	{
		static assert(COLOR.sizeof == uint.sizeof);

		COLOR* pixels;
		int w, h, stride;

		mixin Canvas;
	}

	/// True when this renderer can lock quickly (usually when it's rendering in software).
	/*immutable*/ bool canFastLock;

	/// Lock a 32-bit, BGRX/BGRA surface
	abstract Bitmap fastLock();

	/// ditto
	abstract Bitmap lock();

	/// Unlock what was previously locked
	abstract void unlock();

	/// Finalize rendering and present it to the user (flip buffers etc.)
	abstract void present();

	/// Destroy any bound resources
	abstract void shutdown();

	// **********************************************************************

	abstract @property uint width();
	abstract @property uint height();

	abstract void putPixel(int x, int y, COLOR color);

	struct Pixel { int x, y; COLOR color; }
	void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
			putPixel(pixel.tupleof);
	}

	abstract void line(float x0, float y0, float x1, float y1, COLOR color);
	void vline(int x, int y0, int y1, COLOR color) { line(x, y0, x, y1, color); }
	void hline(int x0, int x1, int y, COLOR color) { line(x0, y, x1, y, color); }

	abstract void fillRect(int x0, int y0, int x1, int y1, COLOR color);
	abstract void fillRect(float x0, float y0, float x1, float y1, COLOR color);

	abstract void clear();

	abstract void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1);
	abstract void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1);
}

/// Uniquely identify private data owned by different renderers
enum Renderers
{
	SDLSoftware,
	SDLOpenGL,
	SDL2,
	max
}

/// Base class for all renderer-specific texture data
class TextureRenderData
{
	bool destroyed;
	uint textureVersion = 0;

	static shared bool cleanupNeeded;
}

/// Base class for logical textures
class TextureSource
{
	TextureRenderData[Renderers.max] renderData;

	uint textureVersion = 1;

	alias RefCanvas!(Renderer.COLOR) TextureCanvas;

	/// Used when the target pixel memory is already allocated
	abstract void drawTo(TextureCanvas dest);

	/// Used when a pointer is needed to existing pixel memory
	abstract TextureCanvas getPixels();

	~this()
	{
		foreach (r; renderData)
			if (r)
				r.destroyed = true;
		TextureRenderData.cleanupNeeded = true;
	}
}

class ImageTextureSource : TextureSource
{
	import ae.utils.graphics.image;
	Image!BGRX image;

	override void drawTo(TextureCanvas dest)
	{
		dest.draw(0, 0, image);
	}

	override TextureCanvas getPixels()
	{
		return image.getRef!TextureCanvas();
	}
}
