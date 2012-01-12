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
		dest.draw(image, 0, 0);
	}

	override TextureCanvas getPixels()
	{
		return image.getRef!TextureCanvas();
	}
}
