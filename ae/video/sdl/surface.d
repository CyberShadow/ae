module ae.video.sdl.surface;

import derelict.sdl.sdl;

import ae.video.surface;
import ae.shell.sdl.shell;

final class SDLSurface : Surface
{
	SDL_Surface* s;

	this(SDL_Surface* s)
	{
		this.s = s;
	}

	override Bitmap lock()
	{
		sdlEnforce(SDL_LockSurface(s)==0, "Can't lock surface");
		return Bitmap(cast(uint*)s.pixels, s.w, s.h, s.pitch);
	}

	override void unlock()
	{
		SDL_UnlockSurface(s);
	}

	void flip()
	{
		sdlEnforce(SDL_Flip(s)==0);
	}
}
