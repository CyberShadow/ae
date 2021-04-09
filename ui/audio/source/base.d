/**
 * ae.ui.audio.source.base
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

module ae.ui.audio.source.base;

/// Base class of a sound source.
class AbstractSoundSource(Sample)
{
	/// Returns number of samples per second.
	abstract uint getSampleRate() const nothrow;

	/// Returns number of channels per sample.
	abstract size_t getNumChannels() const nothrow;

	/// If true, `getSamples` is not available - samples can only be read with `copySamples`.
	abstract bool procedural() const nothrow;

	/// Fill `buffer` with samples from `channel` starting with the position `start`.
	abstract size_t copySamples(size_t channel, size_t start, Sample[] buffer) const nothrow;

	/// Retrieve a slice of an internal buffer containing the samples.
	/// Only available if `procedural` is `false`.
	abstract const(Sample)[] getSamples(size_t channel, size_t start, size_t maxLength) const nothrow;
}

/// The sample type we'll use by default for mixing.
alias SoundSample = short;

/// 16-bit PCM
alias SoundSource = AbstractSoundSource!SoundSample;

