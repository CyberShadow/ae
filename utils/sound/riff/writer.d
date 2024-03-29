/**
 * Write support for the RIFF file format (used in .wav files).
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

module ae.utils.sound.riff.writer;

import std.algorithm;
import std.conv;
import std.range;

import ae.utils.sound.riff.common;
import ae.utils.array : staticArray;

private struct ValueReprRange(T)
{
	ubyte[T.sizeof] bytes;
	size_t p;

	this(ref T t)
	{
		bytes[] = (cast(ubyte[])((&t)[0..1]))[];
	}

	@property ubyte front() { return bytes[p]; }
	void popFront() { p++; }
	@property bool empty() { return p == T.sizeof; }
	@property size_t length() { return T.sizeof - p; }
}

private auto valueReprRange(T)(auto ref T t) { return ValueReprRange!T(t); }

private auto fourCC(char[4] name)
{
	return valueReprRange(name);
}

/// Serialize a chunk and data as a range of bytes.
auto riffChunk(R)(char[4] name, R data)
{
	return chain(
		fourCC(name),
		valueReprRange(data.length.to!uint),
		data
	);
}

/// Serialize a range of samples into a range of bytes representing a RIFF file.
auto makeRiff(R)(R r, uint sampleRate = 44100)
{
	alias Sample = typeof(r.front);
	static if (!is(Sample C : C[channels_], size_t channels_))
		return makeRiff(r.map!(s => [s].staticArray), sampleRate);
	else
	{
		enum numChannels = r.front.length;
		alias ChannelSample = typeof(r.front[0]);
		auto bytesPerSample = ChannelSample.sizeof;
		auto bitsPerSample = bytesPerSample * 8;
		static if (is(ChannelSample : long))
			enum format = 1; // Integer PCM
		else
		static if (is(ChannelSample : real))
			enum format = 3; // Floating-point PCM
		else
			static assert(false, "Unknown sample format: " ~ Sample.stringof);

		return riffChunk("RIFF",
			chain(
				fourCC("WAVE"),
				riffChunk("fmt ",
					valueReprRange(WaveFmt(
						format,
						to!ushort(numChannels),
						sampleRate,
						to!uint  (sampleRate * bytesPerSample * numChannels),
						to!ushort(bytesPerSample * numChannels),
						to!ushort(bitsPerSample),
					)),
				),
				riffChunk("data",
					r.map!(s => valueReprRange(s)).joiner.takeExactly(r.length * r.front.sizeof),
				),
			),
		);
	}
}
