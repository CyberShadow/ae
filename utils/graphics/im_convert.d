/**
 * ImageMagick "convert" program wrapper
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

module ae.utils.graphics.im_convert;

import std.exception;
import std.stdio;
import std.traits : ReturnType;
import std.typecons;

import ae.sys.cmd;
import ae.sys.file;
import ae.sys.imagemagick;
import ae.utils.graphics.bitmap;
import ae.utils.graphics.color;
import ae.utils.graphics.image;

/// Invoke ImageMagick's `convert` program to parse the given data.
auto parseViaIMConvert(COLOR)(const(void)[] data)
{
	string[] convertFlags;
	static if (is(COLOR : BGR))
	{
	//	convertFlags ~= ["-colorspace", "rgb"];
	//	convertFlags ~= ["-depth", "24"];
		convertFlags ~= ["-type", "TrueColor"];
		convertFlags ~= ["-alpha", "off"];
	}
	else
	static if (is(COLOR : BGRA))
	{
		convertFlags ~= ["-type", "TrueColorAlpha"];
		convertFlags ~= ["-alpha", "on"];
	}
	return data
		.pipe(["convert".imageMagickBinary()] ~ convertFlags ~ ["-[0]", "bmp:-"])
		.viewBMP!COLOR();
}

/// ditto
auto parseViaIMConvert(C = TargetColor, TARGET)(const(void)[] data, auto ref TARGET target)
	if (isWritableView!TARGET && isTargetColor!(C, TARGET))
{
	return data.parseViaIMConvert!(ViewColor!TARGET)().copy(target);
}

unittest
{
	if (false)
	{
		void[] data;
		parseViaIMConvert!BGR(data);

		Image!BGR i;
		parseViaIMConvert!BGR(data, i);
	}
}

// ----------------------------------------------------------------------------

private struct DecodeStreamImpl(COLOR)
{
	alias BMP = ReturnType!(viewBMP!(COLOR, ubyte[]));
	@property BMP front() return
	{
		return frameBuf.viewBMP!COLOR();
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

	private void initialize(File f, string fn)
	{
		auto pipes = pipe();
		output = pipes.readEnd();

		string[] convertFlags;
		static if (is(COLOR : BGR))
		{
		//	convertFlags ~= ["-colorspace", "rgb"];
		//	convertFlags ~= ["-depth", "24"];
			convertFlags ~= ["-type", "TrueColor"];
			convertFlags ~= ["-alpha", "off"];
		}
		else
		static if (is(COLOR : BGRA))
		{
			convertFlags ~= ["-type", "TrueColorAlpha"];
			convertFlags ~= ["-alpha", "on"];
		}
		else
			static assert(false, "Unsupported color: " ~ COLOR.stringof);

		auto args = [
			"convert".imageMagickBinary(),
			] ~ convertFlags ~ [
			fn,
			"bmp:-",
		];
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
}

/// Represents a stream as a D range of frames.
struct DecodeStream(COLOR)
{
	private RefCounted!(DecodeStreamImpl!COLOR) impl;
	this(File f) { impl.initialize(f, "-"); } ///
	this(string fn) { impl.initialize(stdin, fn); } ///
	@property typeof(impl).BMP front() return { return impl.front; } ///
	@property bool empty() { return impl.empty; } ///
	void popFront() { impl.popFront(); } ///
}
//alias RefCounted!VideoStreamImpl VideoStream;
deprecated alias VideoStream = DecodeStream;

/// Creates a `DecodeStream` from the given file,
/// providing a forward range of frames in the file.
DecodeStream!COLOR streamViaIMConvert(COLOR)(File f) { return DecodeStream!COLOR(f); }
DecodeStream!COLOR streamViaIMConvert(COLOR)(string fn) { return DecodeStream!COLOR(fn); } /// ditto

unittest
{
	if (false)
	{
		streamViaIMConvert!BGR("");
		streamViaIMConvert!BGR(stdin);
	}
}
