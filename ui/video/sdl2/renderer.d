/**
 * ae.ui.video.sdl.renderer
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

module ae.ui.video.sdl2.renderer;

import std.exception;

import derelict.sdl2.sdl;

import ae.ui.shell.sdl2.shell;
import ae.ui.video.renderer;
import ae.ui.video.software.common;

enum PIXEL_FORMAT = SDL_DEFINE_PIXELFORMAT(SDL_PIXELTYPE_PACKED32, SDL_PACKEDORDER_XRGB, SDL_PACKEDLAYOUT_8888, 32, 4);

/// Draw on a streaming SDL_Texture, and present it
final class SDL2SoftwareRenderer : Renderer
{
	SDL_Texture* t;
	SDL_Renderer* renderer;
	uint w, h;

	this(SDL_Renderer* renderer, uint w, uint h)
	{
		this.renderer = renderer;
		this.w = w;
		this.h = h;

		t = sdlEnforce(SDL_CreateTexture(renderer, PIXEL_FORMAT, SDL_TEXTUREACCESS_STREAMING, w, h), "SDL_CreateTexture failed");
	}

	override Bitmap fastLock()
	{
		assert(false, "Can't fastLock SDL2SoftwareRenderer");
	}

	override Bitmap lock()
	{
		assert(!locked);
		void* pixels;
		int pitch;
		sdlEnforce(SDL_LockTexture(t, null, &pixels, &pitch)==0, "SDL_LockTexture failed");
		_bitmap = Bitmap(cast(COLOR*)pixels, w, h, pitch / COLOR.sizeof);
		locked = true;
		return _bitmap;
	}

	override void unlock()
	{
		assert(locked);
		SDL_UnlockTexture(t);
		locked = false;
	}

	override void present()
	{
		if (locked)
			unlock();

		SDL_RenderCopy(renderer, t, null, null);
		SDL_RenderPresent(renderer);
	}

	override void shutdown()
	{
		SDL_DestroyTexture(t);
	}

	// **********************************************************************

	override @property uint width()
	{
		return w;
	}

	override @property uint height()
	{
		return h;
	}

	mixin SoftwareRenderer;

private:
	Bitmap _bitmap;
	bool locked;

	@property Bitmap bitmap()
	{
		if (!locked)
			return lock();
		return _bitmap;
	}
}

/// Use SDL 2 drawing APIs.
final class SDL2Renderer : Renderer
{
	SDL_Renderer* renderer;
	uint w, h;

	this(SDL_Renderer* renderer, uint w, uint h)
	{
		this.renderer = renderer;
		this.w = w;
		this.h = h;
	}

	override Bitmap fastLock()
	{
		assert(false, "Can't fastLock SDL2Renderer");
	}

	override Bitmap lock()
	{
		assert(false, "Not possible");
	}

	override void unlock()
	{
		assert(false, "Not possible");
	}

	override void present()
	{
		SDL_RenderPresent(renderer);
	}

	override void shutdown() {}

	// **********************************************************************

	override void putPixel(int x, int y, COLOR color)
	{
		SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.x);
		SDL_RenderDrawPoint(renderer, x, y);
	}

	override void putPixels(Pixel[] pixels)
	{
		foreach (ref pixel; pixels)
			putPixel(pixel.x, pixel.y, pixel.color);
	}

	override void line(float x0, float y0, float x1, float y1, COLOR color)
	{
		SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.x);
		SDL_RenderDrawLine(renderer, cast(int)x0, cast(int)y0, cast(int)x1, cast(int)y1);
	}

	override void vline(int x, int y0, int y1, COLOR color)
	{
		SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.x);
		SDL_RenderDrawLine(renderer, x, y0, x, y1);
	}

	override void hline(int x0, int x1, int y, COLOR color)
	{
		SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.x);
		SDL_RenderDrawLine(renderer, x0, y, x1, y);
	}

	override void fillRect(int x0, int y0, int x1, int y1, COLOR color)
	{
		SDL_SetRenderDrawColor(renderer, color.r, color.g, color.b, color.x);
		auto rect = SDL_Rect(x0, y0, x1-x0, y1-y0);
		SDL_RenderFillRect(renderer, &rect);
	}

	override void fillRect(float x0, float y0, float x1, float y1, COLOR color)
	{
		fillRect(cast(int)x0, cast(int)y0, cast(int)x1, cast(int)y1, color);
	}

	override void clear()
	{
		SDL_SetRenderDrawColor(renderer, 0, 0, 0, 0);
		SDL_RenderClear(renderer);
	}

	override void draw(int x, int y, TextureSource source, int u0, int v0, int u1, int v1)
	{
		auto data = updateTexture(source);
		auto srcRect = SDL_Rect(u0, v0, u1-u0, v1-v0);
		auto dstRect = SDL_Rect(x, y, u1-u0, v1-v0);
		sdlEnforce(SDL_RenderCopy(renderer, data.t, &srcRect, &dstRect)==0, "SDL_RenderCopy");
	}

	override void draw(float x0, float y0, float x1, float y1, TextureSource source, int u0, int v0, int u1, int v1)
	{
		auto data = updateTexture(source);
		auto srcRect = SDL_Rect(u0, v0, u1-u0, v1-v0);
		auto dstRect = SDL_Rect(cast(int)x0, cast(int)y0, cast(int)(x1-x0), cast(int)(y1-y0));
		sdlEnforce(SDL_RenderCopy(renderer, data.t, &srcRect, &dstRect)==0, "SDL_RenderCopy");
	}

	// **********************************************************************

	private SDLTextureRenderData updateTexture(TextureSource source)
	{
		auto data = cast(SDLTextureRenderData) cast(void*) source.renderData[Renderers.SDL2];
		if (data is null || data.invalid)
		{
			source.renderData[Renderers.SDL2] = data = new SDLTextureRenderData;
			data.next = SDLTextureRenderData.head;
			SDLTextureRenderData.head = data;
			rebuildTexture(data, source);
		}
		else
		{
			if (data.textureVersion != source.textureVersion)
			{
				auto pixelInfo = source.getPixels();
				SDL_UpdateTexture(data.t, null, pixelInfo.pixelPtr(0, 0), pixelInfo.stride * COLOR.sizeof);
				data.textureVersion = source.textureVersion;
			}
		}
		return data;
	}

	private void rebuildTexture(SDLTextureRenderData data, TextureSource source)
	{
		auto pixelInfo = source.getPixels();
		data.t = sdlEnforce(SDL_CreateTexture(renderer, PIXEL_FORMAT, SDL_TEXTUREACCESS_STREAMING, pixelInfo.w, pixelInfo.h), "SDL_CreateTexture failed");
		SDL_UpdateTexture(data.t, null, pixelInfo.pixelPtr(0, 0), pixelInfo.stride * COLOR.sizeof);
		data.textureVersion = source.textureVersion;
	}

	// **********************************************************************

	override @property uint width()
	{
		return w;
	}

	override @property uint height()
	{
		return h;
	}
}

private final class SDLTextureRenderData : TextureRenderData
{
	SDL_Texture* t;
	SDLTextureRenderData next;
	static SDLTextureRenderData head;
	bool invalid;
	uint w, h;

	void destroy()
	{
		invalid = true;
		SDL_DestroyTexture(t);
	}
}
