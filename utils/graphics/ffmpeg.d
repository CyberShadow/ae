/**
 * Get frames from a video file by invoking ffmpeg.
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

module ae.utils.graphics.ffmpeg;

import std.exception;
import std.typecons;

public import ae.utils.graphics.image;

private struct VideoStreamImpl
{
	@property ref Image!BGR front()
	{
		return frame;
	}

	@property bool empty() { return done; }

	void popFront()
	{
		auto stream = pipes.stdout;
		auto headerBuf = frameBuf[0..Header.sizeof];
		if (!stream.readExactly(headerBuf))
		{
			done = true;
			return;
		}

		auto pHeader = cast(Header*)headerBuf.ptr;
		frameBuf.length = pHeader.bfSize;
		auto dataBuf = frameBuf[Header.sizeof..$];
		enforce(stream.readExactly(dataBuf), "Unexpected end of stream");

		frame.loadBMP(frameBuf);
	}

	@disable this(this);

	~this()
	{
		if (done)
			wait(pipes.pid);
		else
			kill(pipes.pid);
	}

	private void initialize(string fn)
	{
		pipes = pipeProcess([
			"ffmpeg",
			// Be quiet
			"-loglevel", "panic",
			// Specify input
			"-i", fn,
			// No audio
			"-an",
			// Specify output codec
			"-vcodec", "bmp",
			// Specify output format
			"-f", "image2pipe",
			// Specify output
			"-"
		], Redirect.stdout);

		frameBuf.length = Header.sizeof;

		popFront();
	}

private:
	import std.process;

	ProcessPipes pipes;
	bool done;

	alias Image!BGR.BitmapHeader!3 Header;
	ubyte[] frameBuf;
	Image!BGR frame;
}

struct VideoStream
{
	RefCounted!VideoStreamImpl impl;
	this(string fn) { impl.initialize(fn); }
	@property ref Image!BGR front() { return impl.front; }
	@property bool empty() { return impl.empty; }
	void popFront() { impl.popFront(); }
}
//alias RefCounted!VideoStreamImpl VideoStream;

VideoStream streamVideo(string fn) { return VideoStream(fn); }

private:

import std.stdio;

bool readExactly(ref File f, ubyte[] buf)
{
	auto read = f.rawRead(buf);
	if (read.length==0) return false;
	enforce(read.length == buf.length, "Unexpected end of stream");
	return true;
}
