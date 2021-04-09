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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.ui.video.renderer;

public import ae.utils.graphics.color;
public import ae.utils.graphics.image;
public import ae.utils.graphics.view;

/// Abstract class for a video renderer.
class Renderer
{
	alias COLOR = BGRX; /// The color type we use for all rendering.

	/// BGRX/BGRA-only.
	struct Bitmap
	{
		static assert(COLOR.sizeof == uint.sizeof);
		/// `ae.utils.graphics.view` implementation.
		alias StorageType = PlainStorageUnit!COLOR;

		StorageType* pixels; /// ditto
		/// ditto
		xy_t w, h, stride;

		inout(StorageType)[] scanline(xy_t y) inout
		{
			assert(y>=0 && y<h);
			return pixels[stride*y..stride*(y+1)];
		} /// ditto

		mixin DirectView;
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

	/// Get geometry.
	abstract @property uint width();
	abstract @property uint height(); /// ditto

	/// Set a single pixel.
	abstract void putPixel(int x, int y, COLOR color);

	/// Set some pixels.
	struct Pixel { int x, /***/ y; /***/ COLOR color; /***/ }
	void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
			putPixel(pixel.tupleof);
	} /// ditto

	/// Draw a straight line.
	abstract void line(float x0, float y0, float x1, float y1, COLOR color);
	/// Draw a vertical line.
	void vline(int x, int y0, int y1, COLOR color) { line(x, y0, x, y1, color); }
	/// Draw a horizontal line.
	void hline(int x0, int x1, int y, COLOR color) { line(x0, y, x1, y, color); }

	/// Draw a filled rectangle.
	abstract void fillRect(int x0, int y0, int x1, int y1, COLOR color);
	abstract void fillRect(float x0, float y0, float x1, float y1, COLOR color); /// ditto

	/// Clear the entire surface.
	abstract void clear();

	/// Draw a texture.
	abstract void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1);

	/// Draw a texture with scaling.
	abstract void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1);
}

/// Uniquely identify private data owned by different renderers
enum Renderers
{
	SDLSoftware, ///
	SDLOpenGL,	 ///
	SDL2,		 ///
	max
}

/// Base class for all renderer-specific texture data
class TextureRenderData
{
	/// If `true`, the `TextureSource` has been destroyed,
	/// and so should this instance (in the render thread)>
	bool destroyed;

	/// Uploaded version number of the texture.
	/// If it does not match `TextureSource.textureVersion`,
	/// it needs to be updated.
	uint textureVersion = 0;

	/// Set to `true` when any `TextureRenderData`
	/// needs to be destroyed.
	static shared bool cleanupNeeded;
}

/// Base class for logical textures
class TextureSource
{
	// TODO: make this extensible for external renderer implementations.
	/// Renderer-specific texture data.
	TextureRenderData[Renderers.max] renderData;

	/// Source version number of the texture.
	uint textureVersion = 1;

	/// Common type used by `drawTo` / `getPixels`
	alias ImageRef!(Renderer.COLOR) TextureCanvas;

	/// Request the contents of this `TextureSource`.
	/// Used when the target pixel memory is already allocated
	abstract void drawTo(TextureCanvas dest);

	/// Request the contents of this `TextureSource`.
	/// Used when a pointer is needed to existing pixel memory
	abstract TextureCanvas getPixels();

	~this() @nogc
	{
		foreach (r; renderData)
			if (r)
				r.destroyed = true;
		TextureRenderData.cleanupNeeded = true;
	}
}

/// Implementation of `TextureSource`
/// using an `ae.utils.graphics.image.Image`.
class ImageTextureSource : TextureSource
{
	Image!(Renderer.COLOR) image; /// The image.

	override void drawTo(TextureCanvas dest)
	{
		image.blitTo(dest);
	} ///

	override TextureCanvas getPixels()
	{
		return image.toRef();
	} ///
}

/// Base class for `TextureSource` implementations
/// where pixel data is calculated on request.
class ProceduralTextureSource : TextureSource
{
	private Image!(Renderer.COLOR) cachedImage;

	/// Query the size of the procedural texture
	abstract void getSize(out int width, out int height);

	/// Implementation of `getPixels` using
	/// `drawTo` and a cached copy.
	override TextureCanvas getPixels()
	{
		if (!cachedImage.w)
		{
			int w, h;
			getSize(w, h);
			cachedImage.size(w, h);
			drawTo(cachedImage.toRef());
		}
		return cachedImage.toRef();
	}
}
