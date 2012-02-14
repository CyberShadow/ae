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

module ae.ui.video.sdl.renderer;

import std.exception;

import derelict.sdl.sdl;

import ae.ui.shell.sdl.shell;
import ae.ui.video.renderer;
import ae.ui.video.software.common;

/// Wrapper for a software SDL_Surface.
final class SDLRenderer : Renderer
{
	SDL_Surface* s;
	Bitmap bitmap;

	this(SDL_Surface* s)
	{
		this.s = s;
		enforce(!SDL_MUSTLOCK(s), "Renderer surface is not fastlocking");
		//this.canFastLock = (s.flags & SDL_HWSURFACE) == 0;
		this.canFastLock = true;

		enforce(s.format.BytesPerPixel == 4 && s.format.Bmask == 0xFF, "Invalid pixel format");
		bitmap = Bitmap(cast(COLOR*)s.pixels, s.w, s.h, s.pitch / uint.sizeof);
	}

	override Bitmap fastLock()
	{
		return bitmap;
	}

	override Bitmap lock()
	{
		//sdlEnforce(SDL_LockSurface(s)==0, "Can't lock surface");
		return bitmap;
	}

	override void unlock()
	{
		//SDL_UnlockSurface(s);
	}

	override void present()
	{
		sdlEnforce(SDL_Flip(s)==0);
	}

	override void shutdown() {}

	// **********************************************************************

	override @property uint width()
	{
		return s.w;
	}

	override @property uint height()
	{
		return s.h;
	}

	mixin SoftwareRenderer;
}
