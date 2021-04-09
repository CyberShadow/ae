/**
 * ae.ui.audio.memory.base
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

module ae.ui.audio.source.memory;

import std.algorithm.comparison;
import std.algorithm.mutation;
import std.range;
import std.range.primitives;

import ae.ui.audio.source.base;

/// Implementation of `AbstractSoundSource` backed by a simple array of samples.
template MemorySoundSource(Sample)
{
	final class MemorySoundSource : AbstractSoundSource!Sample
	{
		Sample[] samples; ///
		uint sampleRate; ///

		this(Sample[] samples, uint sampleRate)
		{
			this.samples = samples;
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
			return false;
		} ///

		override size_t copySamples(size_t channel, size_t start, Sample[] buffer) const nothrow
		{
			auto slice = getSamples(channel, start, buffer.length);
			buffer[0 .. slice.length] = slice;
			return slice.length;
		} ///

		override const(Sample)[] getSamples(size_t channel, size_t start, size_t maxLength) const nothrow
		{
			start = min(start, samples.length);
			auto end = min(start + maxLength, samples.length);
			return samples[start .. end];
		} ///
	}
}

/// Construct a `MemorySoundSource` from an array.
MemorySoundSource!Sample memorySoundSource(Sample)(Sample[] samples, uint sampleRate)
{
	return new MemorySoundSource!Sample(samples, sampleRate);
}

unittest
{
	auto w = memorySoundSource([short.max, short.min], 44100);
}
