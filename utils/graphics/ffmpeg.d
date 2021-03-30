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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.graphics.ffmpeg;

import std.exception;
import std.stdio;
import std.typecons;

import ae.utils.graphics.bitmap;
import ae.utils.graphics.color;
import ae.utils.graphics.image;
import ae.sys.file : readExactly;

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
			auto frameAlpha = frameBuf.viewBMP!BGRX();
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
		auto args = [
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
		];
		debug(FFMPEG) stderr.writeln(args.escapeShellCommand);
		pid = spawnProcess(args, f, pipes.writeEnd);

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
		auto args = [
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
		];
		debug(FFMPEG) stderr.writeln(args.escapeShellCommand);
		pid = spawnProcess(args, pipes.readEnd, f);
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
