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

module ae.ui.video.sdl.renderer;

import std.exception;

import derelict.sdl.sdl;

import ae.ui.video.renderer;
import ae.ui.shell.sdl.shell;

final class SDLRenderer : Renderer
{
	SDL_Surface* s;

	this(SDL_Surface* s)
	{
		this.s = s;
		//this.canFastLock = (s.flags & SDL_HWSURFACE) == 0;
		this.canFastLock = !SDL_MUSTLOCK(s);
	}

	override Bitmap fastLock()
	{
		assert(canFastLock, "Can't fastLock this");
		// TODO: cache bitmap for recursive locks?
		return lock();
	}

	override Bitmap lock()
	{
		sdlEnforce(SDL_LockSurface(s)==0, "Can't lock surface");
		enforce(s.format.BytesPerPixel == 4 && s.format.Bmask == 0xFF, "Invalid pixel format");
		return Bitmap(cast(COLOR*)s.pixels, s.w, s.h, s.pitch / uint.sizeof);
	}

	override void unlock()
	{
		SDL_UnlockSurface(s);
	}

	override void present()
	{
		sdlEnforce(SDL_Flip(s)==0);
	}

	// **********************************************************************

	override @property uint width()
	{
		return s.w;
	}

	override @property uint height()
	{
		return s.h;
	}

	override void putPixel(int x, int y, COLOR color)
	{
		auto bitmap = fastLock();
		bitmap.safePut(x, y, color);
		unlock();
	}
}
