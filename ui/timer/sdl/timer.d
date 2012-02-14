/**
 * ae.ui.timer.sdl.timer
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

module ae.ui.timer.sdl.timer;

import derelict.sdl.sdl;

public import ae.ui.timer.timer;
import ae.ui.app.application;
import ae.ui.shell.sdl.shell : sdlEnforce;

final class SDLTimer : Timer
{
	override TimerEvent setTimeout (AppCallback fn, uint ms) { return add(fn, ms, false); }
	override TimerEvent setInterval(AppCallback fn, uint ms) { return add(fn, ms, true ); }

private:
	TimerEvent add(AppCallback fn, uint ms, bool recurring)
	{
		auto event = new SDLTimerEvent;
		event.fn = fn;
		event.recurring = recurring;
		event.id = sdlEnforce(SDL_AddTimer(ms, &sdlCallback, cast(void*)event));
		return event;
	}

	extern(C) static uint sdlCallback(uint ms, void* param)
	{
		auto event = cast(SDLTimerEvent)param;
		if (event.call())
			return ms;
		else
			return 0;
	}
}

private final class SDLTimerEvent : TimerEvent
{
	SDL_TimerID id;
	AppCallback fn;
	bool recurring, calling, cancelled;

	// Returns true if it should be rescheduled.
	bool call()
	{
		calling = true;
		fn.call();
		calling = false;
		return recurring && !cancelled;
	}

	override void cancel()
	{
		if (calling)
			cancelled = true;
		else
			SDL_RemoveTimer(id);
	}
}
