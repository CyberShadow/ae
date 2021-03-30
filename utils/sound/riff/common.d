/**
 * Common code for the RIFF file format (used in .wav files).
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

module ae.utils.sound.riff.common;

struct WaveFmt
{
	ushort format;
	ushort numChannels;
	uint sampleRate;
	uint byteRate;
	ushort blockAlign;
	ushort bitsPerSample;
}
