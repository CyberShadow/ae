/**
 * ae.ui.audio.sdl.audio
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

module ae.ui.audio.sdl2.audio;

import derelict.sdl2.sdl;

import ae.ui.app.application;
import ae.ui.audio.audio;
import ae.ui.audio.source.base;
import ae.ui.shell.sdl2.shell;

class SDL2Audio : Audio
{
	override void start(Application application)
	{
		assert(mixer, "No mixer set");

		SDL_AudioSpec spec;
		// TODO: make this customizable
		spec.freq = 44100;
		spec.format = AUDIO_S16;
		spec.channels = 1;
		spec.samples = 1024;
		spec.callback = &callback;
		spec.userdata = cast(void*)this;

		sdlEnforce(SDL_OpenAudio(&spec, null) >= 0, "SDL_OpenAudio");

		SDL_PauseAudio(0);
	}

	override void stop()
	{
		SDL_CloseAudio();
	}

	private static extern(C) void callback(void *userData, ubyte *bufferPtr, int length) nothrow
	{
		auto buffer = cast(SoundSample[])bufferPtr[0..length];
		SDL2Audio instance = cast(SDL2Audio)userData;
		instance.mixer.fillBuffer(buffer);
	}
}
