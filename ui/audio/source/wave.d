/**
 * ae.ui.audio.wave.base
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

module ae.ui.audio.source.wave;

import std.algorithm.mutation;
import std.range;
import std.range.primitives;

import ae.ui.audio.source.base;

/// Implementation of `AbstractSoundSource` backed by a D range of samples.
template WaveSoundSource(Wave)
{
	alias Sample = typeof(Wave.init.front);

	class WaveSoundSource : AbstractSoundSource!Sample
	{
		Wave wave; ///
		uint sampleRate; ///

		this(Wave wave, uint sampleRate)
		{
			this.wave = wave;
			this.sampleRate = sampleRate;
		} ///

		override uint getSampleRate() const nothrow
		{
			return sampleRate;
		} ///

		override size_t getNumChannels() const nothrow
		{
			// TODO
			return 1;
		} ///

		override bool procedural() const nothrow
		{
			return true;
		} ///

		override size_t copySamples(size_t channel, size_t start, Sample[] buffer) const nothrow
		{
			auto w = cast(Wave)wave; // Break constness because Map.save is not const
			auto remaining = copy(w.drop(start).take(buffer.length), buffer);
			return buffer.length - remaining.length;
		} ///

		override const(Sample)[] getSamples(size_t channel, size_t start, size_t maxLength) const nothrow
		{
			assert(false, "Procedural");
		} ///
	}
}

/// Construct a `WaveSoundSource` from a range of samples.
WaveSoundSource!Wave waveSoundSource(Wave)(Wave wave, uint sampleRate)
{
	return new WaveSoundSource!Wave(wave, sampleRate);
}

debug(ae_unittest) unittest
{
	auto w = waveSoundSource([short.max, short.min], 44100);
}
