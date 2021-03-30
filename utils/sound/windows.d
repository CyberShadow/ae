/**
 * Play waves using the Windows multimedia API
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

module ae.utils.sound.windows;
version (Windows):

import ae.utils.sound.riff.writer;

import core.time;

import std.algorithm;
import std.range;

import ae.sys.windows.imports;
mixin(importWin32!q{mmsystem});
mixin(importWin32!q{winnt});

mixin(importWin32!(q{mmsystem}, q{public}, q{SND_ASYNC, SND_LOOP, SND_NOSTOP}));

void playWave(Wave)(Wave wave, Duration duration, uint flags = 0)
{
	enum sampleRate = 44100;
	auto samples = cast(size_t)(duration.total!"hnsecs" * sampleRate / convert!("seconds", "hnsecs")(1));
	playRiff(makeRiff(wave.takeExactly(samples), sampleRate), flags);
}

void playRiff(Riff)(Riff riff, uint flags = 0)
{
	import core.stdc.stdlib : malloc, free;

	auto data = (cast(ubyte*)malloc(riff.length))[0..riff.length];
	scope(exit) free(data.ptr);
	copy(riff, data);
	PlaySoundA(cast(LPCSTR)data.ptr, null, SND_MEMORY | flags);
}
