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

import ae.utils.graphics.bitmap;
import ae.utils.graphics.color;
import ae.utils.graphics.image;

private struct VideoInputStreamImpl
{
	@property ref Image!BGR front() return
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

		frameBuf.parseBMP!BGR(frame);
	}

	@disable this(this);

	~this()
	{
		if (done)
			wait(pipes.pid);
		else
		{
			if (!tryWait(pipes.pid).terminated)
			{
				try
					kill(pipes.pid);
				catch (ProcessException e)
				{}
			}

			version(Posix)
			{
				import core.sys.posix.signal : SIGKILL;
				if (!tryWait(pipes.pid).terminated)
				{
					try
						kill(pipes.pid, SIGKILL);
					catch (ProcessException e)
					{}
				}
			}

			wait(pipes.pid);
		}
	}

	private void initialize(string fn, string[] ffmpegArgs)
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
			// Additional arguments
			] ~ ffmpegArgs ~ [
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

	alias BitmapHeader!3 Header;
	ubyte[] frameBuf;
	Image!BGR frame;
}

struct VideoInputStream
{
	RefCounted!VideoInputStreamImpl impl;
	this(string fn, string[] ffmpegArgs) { impl.initialize(fn, ffmpegArgs); }
	@property ref Image!BGR front() return { return impl.front; }
	@property bool empty() { return impl.empty; }
	void popFront() { impl.popFront(); }
}
//alias RefCounted!VideoStreamImpl VideoStream;
deprecated alias VideoStream = VideoInputStream;

VideoInputStream streamVideo(string fn, string[] ffmpegArgs = null) { return VideoInputStream(fn, ffmpegArgs); }

private:

import std.stdio;

bool readExactly(ref File f, ubyte[] buf)
{
	auto read = f.rawRead(buf);
	if (read.length==0) return false;
	enforce(read.length == buf.length, "Unexpected end of stream");
	return true;
}
