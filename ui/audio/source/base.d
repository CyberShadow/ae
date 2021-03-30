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

class AbstractSoundSource(Sample)
{
	abstract uint getSampleRate() const nothrow;
	abstract size_t getNumChannels() const nothrow;
	abstract bool procedural() const nothrow; /// requires copySamples
	abstract size_t copySamples(size_t channel, size_t start, Sample[] buffer) const nothrow;
	abstract const(Sample)[] getSamples(size_t channel, size_t start, size_t maxLength) const nothrow;
}

/// The sample type we'll use by default for mixing.
alias SoundSample = short;

/// 16-bit PCM
alias SoundSource = AbstractSoundSource!SoundSample;

