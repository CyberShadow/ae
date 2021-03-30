/**
 * Play waves using ALSA command-line tools
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

module ae.utils.sound.asound;

import std.conv;
import std.exception;
import std.process;
import std.range;
import std.traits;

/// Return the ALSA format name corresponding to the given type.
template aSoundFormat(T)
{
	version(LittleEndian)
		enum aSoundEndianness = "_LE";
	else
		enum aSoundEndianness = "_BE";

	static if (is(T==ubyte))
		enum aSoundFormat = "U8";
	else
	static if (is(T==byte))
		enum aSoundFormat = "S8";
	else
	static if (is(T==ushort))
		enum aSoundFormat = "U16" ~ aSoundEndianness;
	else
	static if (is(T==short))
		enum aSoundFormat = "S16" ~ aSoundEndianness;
	else
	static if (is(T==uint))
		enum aSoundFormat = "U32" ~ aSoundEndianness;
	else
	static if (is(T==int))
		enum aSoundFormat = "S32" ~ aSoundEndianness;
	else
	static if (is(T==float))
		enum aSoundFormat = "FLOAT" ~ aSoundEndianness;
	else
	static if (is(T==double))
		enum aSoundFormat = "FLOAT64" ~ aSoundEndianness;
	else
		static assert(false, "Can't represent sample type in asound format: " ~ T.stringof);
}

void playWave(Wave)(Wave wave, int sampleRate = 44100)
{
	alias Sample = typeof(wave.front);
	static if (is(Sample C : C[channels_], size_t channels_))
	{
		alias ChannelSample = C;
		enum channels = channels_;
	}
	else
	{
		alias ChannelSample = Sample;
		enum channels = 1;
	}
	auto p = pipe();
	auto pid = spawnProcess([
			"aplay",
			"--format", aSoundFormat!ChannelSample,
			"--channels", text(channels),
			"--rate", text(sampleRate),
		], p.readEnd());
	while (!wave.empty)
	{
		Sample[1] s;
		s[0] = wave.front;
		wave.popFront();
		p.writeEnd.rawWrite(s[]);
	}
	p.writeEnd.close();
	enforce(pid.wait() == 0, "aplay failed");
}

unittest
{
	if (false)
		playWave(iota(100));
}
