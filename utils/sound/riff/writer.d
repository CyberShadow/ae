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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.utils.sound.riff.writer;

import std.algorithm;
import std.conv;
import std.range;

import ae.utils.sound.riff.common;
import ae.utils.array : staticArray;

struct ValueReprRange(T)
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

auto valueReprRange(T)(auto ref T t) { return ValueReprRange!T(t); }

auto fourCC(char[4] name)
{
	return valueReprRange(name);
}

auto riffChunk(R)(char[4] name, R data)
{
	return chain(
		fourCC(name),
		valueReprRange(data.length.to!uint),
		data
	);
}

auto makeRiff(R)(R r, uint sampleRate = 44100)
{
	alias Sample = typeof(r.front);
	static if (!is(Sample C : C[channels_], size_t channels_))
		return makeRiff(r.map!(s => [s].staticArray), sampleRate);
	else
	{
		enum numChannels = r.front.length;
		auto bytesPerSample = r.front[0].sizeof;
		auto bitsPerSample = bytesPerSample * 8;

		return riffChunk("RIFF",
			chain(
				fourCC("WAVE"),
				riffChunk("fmt ",
					valueReprRange(WaveFmt(
						1, // PCM
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
