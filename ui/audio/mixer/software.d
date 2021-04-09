/**
 * ae.ui.audio.mixer.software
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

module ae.ui.audio.mixer.software;

import std.algorithm.mutation;

import ae.ui.audio.mixer.base;
import ae.ui.audio.source.base;

/// Software mixer implementation.
class SoftwareMixer : Mixer
{
	struct Stream
	{
		SoundSource source; ///
		size_t pos; ///
	} /// Currently playing streams.
	Stream[] streams; /// ditto

	override void playSound(SoundSource sound)
	{
		// Note: sounds will begin to play on the next sound frame
		// (fillBuffer invocation), so any two sounds' start time will
		// always be a multiple of the buffer length apart.
		streams ~= Stream(sound, 0);

		// TODO: check sample rate
	} ///

	// Temporary storage of procedural streams
	private SoundSample[] streamBuffer;

	// TODO: multiple channels
	override void fillBuffer(SoundSample[] buffer) nothrow
	{
		buffer[] = 0;

		foreach_reverse (i, ref stream; streams)
		{
			foreach (channel; 0..1)
			{
				const(SoundSample)[] samples;
				if (stream.source.procedural)
				{
					if (streamBuffer.length < buffer.length)
						streamBuffer.length = buffer.length;
					auto copiedSamples = stream.source.copySamples(channel, stream.pos, streamBuffer);
					samples = streamBuffer[0..copiedSamples];
				}
				else
					samples = stream.source.getSamples(channel, stream.pos, buffer.length);

				buffer[0..samples.length] += samples[]; // Fast vector math!

				if (samples.length < buffer.length) // EOF?
					streams = streams.remove(i);
			}
			stream.pos += buffer.length;
		}
	} ///
}
