/**
 * Read support for the RIFF file format (used in .wav files).
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

module ae.utils.sound.riff.reader;

import std.algorithm.searching;
import std.exception;

import ae.utils.sound.riff.common;

struct Chunk
{
	struct Header
	{
		char[4] name;
		uint length;
		ubyte[0] data;
	}

	Header* header;

	this(ref ubyte[] data)
	{
		enforce(data.length >= Header.sizeof);
		header = cast(Header*)data;
		data = data[Header.sizeof..$];

		enforce(data.length >= header.length);
		data = data[header.length..$];
	}

	char[4] name() { return header.name; }
	ubyte[] data() { return header.data.ptr[0..header.length]; }
}

struct Chunks
{
	ubyte[] data;
	bool empty() { return data.length == 0; }
	Chunk front() { auto cData = data; return Chunk(cData); }
	void popFront() { auto c = Chunk(data); }
}

auto readRiff(ubyte[] data)
{
	return Chunk(data);
}

auto getWave(T)(Chunk chunk)
{
	enforce(chunk.name == "RIFF", "Unknown file format");
	auto riffData = chunk.data;
	enforce(riffData.skipOver("WAVE"), "Unknown RIFF contents");
	WaveFmt fmt = (cast(WaveFmt[])Chunks(riffData).find!(c => c.name == "fmt ").front.data)[0];
	enforce(fmt.format == 1, "Unknown WAVE format");
	enforce(fmt.sampleRate * T.sizeof == fmt.byteRate, "Format mismatch");
	auto data = Chunks(riffData).find!(c => c.name == "data").front.data;
	return cast(T[])data;
}
