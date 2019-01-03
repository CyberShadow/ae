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
		auto headerBuf = frameBuf[0..Header.sizeof];
		if (!output.readExactly(headerBuf))
		{
			done = true;
			return;
		}

		auto pHeader = cast(Header*)headerBuf.ptr;
		frameBuf.length = pHeader.bfSize;
		auto dataBuf = frameBuf[Header.sizeof..$];
		enforce(output.readExactly(dataBuf), "Unexpected end of stream");

		if (pHeader.bcBitCount == 32)
		{
			// discard alpha
			frameBuf.parseBMP!BGRA(frameAlpha);
			frameAlpha.colorMap!(c => BGR(c.b, c.g, c.r)).copy(frame);
		}
		else
			frameBuf.parseBMP!BGR(frame);
	}

	@disable this(this);

	~this()
	{
		if (done)
			wait(pid);
		else
		{
			if (!tryWait(pid).terminated)
			{
				try
					kill(pid);
				catch (ProcessException e)
				{}
			}

			version(Posix)
			{
				import core.sys.posix.signal : SIGKILL;
				if (!tryWait(pid).terminated)
				{
					try
						kill(pid, SIGKILL);
					catch (ProcessException e)
					{}
				}
			}

			wait(pid);
		}
	}

	private void initialize(File f, string fn, string[] ffmpegArgs)
	{
		auto pipes = pipe();
		output = pipes.readEnd();
		pid = spawnProcess([
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
		], f, pipes.writeEnd);

		frameBuf.length = Header.sizeof;

		popFront();
	}

private:
	import std.process;

	Pid pid;
	File output;
	bool done;

	alias BitmapHeader!3 Header;
	ubyte[] frameBuf;
	Image!BGR frame;
	Image!BGRA frameAlpha;
}

struct VideoInputStream
{
	RefCounted!VideoInputStreamImpl impl;
	this(File f, string[] ffmpegArgs) { impl.initialize(f, "-", ffmpegArgs); }
	this(string fn, string[] ffmpegArgs) { impl.initialize(stdin, fn, ffmpegArgs); }
	@property ref Image!BGR front() return { return impl.front; }
	@property bool empty() { return impl.empty; }
	void popFront() { impl.popFront(); }
}
//alias RefCounted!VideoStreamImpl VideoStream;
deprecated alias VideoStream = VideoInputStream;

VideoInputStream streamVideo(File f, string[] ffmpegArgs = null) { return VideoInputStream(f, ffmpegArgs); }
VideoInputStream streamVideo(string fn, string[] ffmpegArgs = null) { return VideoInputStream(fn, ffmpegArgs); }

// ----------------------------------------------------------------------------

struct VideoOutputStream
{
	void put(ref Image!BGR frame)
	{
		output.rawWrite(frame.toBMP);
	}

	@disable this(this);

	~this()
	{
		output.close();
		wait(pid);
	}

	private this(File f, string fn, string[] ffmpegArgs, string[] inputArgs)
	{
		auto pipes = pipe();
		output = pipes.writeEnd;
		pid = spawnProcess([
			"ffmpeg",
			// Additional input arguments (such as -framerate)
			] ~ inputArgs ~ [
		//	// Be quiet
		//	"-loglevel", "panic",
			// Specify input format
			"-f", "image2pipe",
			// Specify input
			"-i", "-",
			// Additional arguments
			] ~ ffmpegArgs ~ [
			// Specify output
			fn
		], pipes.readEnd, f);
	}

	this(File f, string[] ffmpegArgs = null, string[] inputArgs = null)
	{
		this(f, "-", ffmpegArgs, inputArgs);
	}

	this(string fn, string[] ffmpegArgs = null, string[] inputArgs = null)
	{
		this(stdin, fn, ffmpegArgs, inputArgs);
	}

private:
	import std.process;

	Pid pid;
	File output;
	bool done;

	alias BitmapHeader!3 Header;
	Image!BGR frame;
}

// ----------------------------------------------------------------------------

private:

import std.stdio;

bool readExactly(ref File f, ubyte[] buf)
{
	auto read = f.rawRead(buf);
	if (read.length==0) return false;
	enforce(read.length == buf.length, "Unexpected end of stream");
	return true;
}
