/**
 * Canvas wrapper and code for whole images.
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

module ae.utils.graphics.image;

public import ae.utils.graphics.canvas;

// TODO: many of the below functions allocate. This is convenient but very
// inefficient - they should take a destination image as a parameter, and moved
// to the Canvas mixin.

struct Image(COLOR)
{
	int w, h;
	alias w stride;
	COLOR[] pixels;

	mixin Canvas;

	this(int w, int h)
	{
		size(w, h);
	}

	/// Does not scale image
	void size(int w, int h)
	{
		this.w = w;
		this.h = h;
		if (pixels.length < w*h)
			pixels.length = w*h;
	}

	static Image!COLOR hjoin(Image!COLOR[] images)
	{
		int w, h;
		foreach (ref image; images)
			w += image.w,
			h = max(h, image.h);
		auto result = Image!COLOR(w, h);
		int x;
		foreach (ref image; images)
			result.draw(x, 0, image),
			x += image.w;
		return result;
	}

	static Image!COLOR vjoin(Image!COLOR[] images)
	{
		int w, h;
		foreach (ref image; images)
			w = max(w, image.w),
			h += image.h;
		auto result = Image!COLOR(w, h);
		int y;
		foreach (ref image; images)
			result.draw(0, y, image),
			y += image.h;
		return result;
	}

	Image!COLOR hflip()
	{
		auto newImage = Image!COLOR(w, h);
		foreach (y; 0..h)
			foreach (uint x, c; pixels[y*stride..y*stride+w])
				newImage[w-x-1, y] = c;
		return newImage;
	}

	template SameSize(T, U...)
	{
		static if (U.length)
			enum SameSize = T.sizeof==U[0].sizeof && SameSize!U;
		else
			enum SameSize = true;
	}

	template ChannelType(T)
	{
		static if (is(T : ulong))
			alias T ChannelType;
		else
		static if (is(T == struct))
		{
			static assert(SameSize!T, "Inconsistent color channel sizes");
			alias typeof(T.init.tupleof[0]) ChannelType;
		}
		else
			static assert(0, "Can't get channel type of " ~ T.stringof);
	}

	// ***********************************************************************

	import std.ascii;
	import std.exception;
	import std.file : read, write;
	import std.conv : to;
	import std.zlib;
	import ae.utils.math : swapBytes;

	static string[] readPNMHeader(ref ubyte[] data)
	{
		string[] fields;
		uint wordStart = 0;
		uint p;
		for (p=1; p<data.length && fields.length<4; p++)
			if (!isWhite(data[p-1]) && isWhite(data[p]))
				fields ~= cast(string)data[wordStart..p];
			else
			if (isWhite(data[p-1]) && !isWhite(data[p]))
				wordStart = p;
		data = data[p..$];
		enforce(fields.length==4, "Header too short");
		enforce(fields[0].length==2 && fields[0][0]=='P', "Invalid signature");
		return fields;
	}

	void loadPNM()(string filename)
	{
		static assert(StructFields!COLOR == ["r", "g", "b"], "PNM only supports RGB, not " ~ __traits(allMembers, COLOR.Fields).stringof);
		ubyte[] data = cast(ubyte[])read(filename);
		string[] fields = readPNMHeader(data);
		enforce(fields[0]=="P6", "Invalid signature");
		w = to!uint(fields[1]);
		h = to!uint(fields[2]);
		enforce(data.length / COLOR.sizeof == w*h, "Dimension / filesize mismatch");
		enforce(to!uint(fields[3]) == COLOR.tupleof[0].max);
		pixels = cast(COLOR[])data;
		static if (COLOR.tupleof[0].sizeof > 1)
			foreach (ref pixel; pixels)
				pixel = COLOR.op!q{swapBytes(a)}(pixel);
	}

	void savePNM()(string filename) // RGB only
	{
		import std.string;
		static assert(StructFields!COLOR == ["r", "g", "b"], "PNM only supports RGB");
		alias ChannelType!COLOR CHANNEL_TYPE;
		enforce(w*h == pixels.length, "Dimension mismatch");
		ubyte[] header = cast(ubyte[])format("P6\n%d %d %d\n", w, h, CHANNEL_TYPE.max);
		ubyte[] data = new ubyte[header.length + pixels.length * COLOR.sizeof];
		data[0..header.length] = header;
		data[header.length..$] = cast(ubyte[])pixels;
		static if (CHANNEL_TYPE.sizeof > 1)
		{
			auto end = cast(CHANNEL_TYPE*)data.ptr+data.length;
			for (CHANNEL_TYPE* p = cast(CHANNEL_TYPE*)(data.ptr + header.length); p<end; p++)
				*p = swapBytes(*p);
		}
		std.file.write(filename, data);
	}

	void loadPGM()(string filename)
	{
		static assert(StructFields!COLOR == ["g"], "PGM only supports grayscale");
		ubyte[] data = cast(ubyte[])read(filename);
		string[] fields = readPNMHeader(data);
		enforce(fields[0]=="P5", "Invalid signature");
		w = to!uint(fields[1]);
		h = to!uint(fields[2]);
		enforce(data.length / COLOR.sizeof == w*h, "Dimension / filesize mismatch");
		enforce(to!uint(fields[3]) == COLOR.init.g.max);
		pixels = cast(COLOR[])data;
		static if (COLOR.sizeof > 1)
			foreach (ref pixel; pixels)
				pixel = swapBytes(pixel);
	}

	void savePGM()(string filename)
	{
		static assert(StructFields!COLOR == ["g"], "PGM only supports grayscale");
		ubyte[] header = cast(ubyte[])format("P5\n%d %d\n%d\n", w, h, COLOR.max);
		ubyte[] data = new ubyte[header.length + pixels.length * COLOR.sizeof];
		data[0..header.length] = header;
		COLOR* p = cast(COLOR*)(data.ptr + header.length);
		foreach (c; pixels)
			*p++ = swapBytes(c);
		std.file.write(filename, data);
	}

	void loadRGBA()(string filename, uint w, uint h)
	{
		static assert(StructFields!COLOR == ["r", "g", "b", "a"], "COLOR is not RGBA");
		pixels = cast(COLOR[])read(filename);
		enforce(pixels.length == w*h, "Dimension / filesize mismatch");
		this.w = w;
		this.h = h;
	}

	// ***********************************************************************

	void loadBMP()(string filename)
	{
		ubyte[] data = cast(ubyte[])read(filename);
		loadBMP(data);
	}

	void loadBMP()(ubyte[] data)
	{
		alias BitmapHeader!3 Header;
		enforce(data.length > Header.sizeof);
		Header* header = cast(Header*) data.ptr;
		enforce(header.bfType == "BM", "Invalid signature");
		enforce(header.bfSize == data.length, format("Incorrect file size (%d in header, %d in file)", header.bfSize, data.length));
		enforce(header.bcSize >= Header.sizeof - header.bcSize.offsetof);

		w = stride = header.bcWidth;
		h = header.bcHeight;
		enforce(header.bcPlanes==1, "Multiplane BMPs not supported");

		static assert(BitmapBitCount, "Unsupported BMP color type: " ~ COLOR.stringof);
		enforce(header.bcBitCount == BitmapBitCount, format("Mismatching BMP bcBitCount - trying to load a %d-bit .BMP file to a %d-bit Image", header.bcBitCount, BitmapBitCount));

		auto pixelData = data[header.bfOffBits..$];
		auto pixelStride = bitmapPixelStride;
		size_t pos = 0;

		if (h < 0)
			h = -h;
		else
		{
			pos = pixelStride*(h-1);
			pixelStride = -pixelStride;
		}

		size(w, h);
		foreach (y; 0..h)
		{
			pixels[y*stride..y*stride+w] = (cast(COLOR*)(pixelData.ptr+pos))[0..w];
			pos += pixelStride;
		}
	}

	// ***********************************************************************

	Image!COLOR dup()
	{
		auto newImage = Image!COLOR(w, h);
		newImage.pixels = pixels[0..w*h].dup;
		return newImage;
	}

	Image!COLOR crop(int x1, int y1, int x2, int y2)
	{
		auto nw = x2-x1;
		auto nh = y2-y1;
		auto newImage = Image!COLOR(nw, nh);
		auto oldOffset = y1*stride + x1;
		auto newOffset = 0;
		foreach (y; y1..y2)
		{
			auto newOffset2 = newOffset + nw;
			newImage.pixels[newOffset..newOffset2] = pixels[oldOffset..oldOffset+nw];
			oldOffset += w;
			newOffset = newOffset2;
		}
		return newImage;
	}

	Image!COLOR2 convert(string pred=`c`, COLOR2=typeof(((){ COLOR c; size_t i; return mixin(pred); })()))()
	{
		auto newImage = Image!COLOR2(w, h);
		foreach (i, c; pixels)
			newImage.pixels[i] = mixin(pred);
		return newImage;
	}
}

void copyCanvas(C, I)(C c, ref I image)
{
	image.size(c.w, c.h);
	image.draw(0, 0, c);
}

private
{
	// test instantiation
	alias Image!RGB RGBImage;
}
