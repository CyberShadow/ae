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

		enum PF = SDL_DEFINE_PIXELFORMAT(SDL_PIXELTYPE_PACKED32, SDL_PACKEDORDER_XRGB, SDL_PACKEDLAYOUT_8888, 32, 4);
		t = sdlEnforce(SDL_CreateTexture(renderer, PF, SDL_TEXTUREACCESS_STREAMING, w, h), "SDL_CreateTexture failed");
	}

	override Bitmap fastLock()
	{
		assert(false);
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

	override void shutdown() {}

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
