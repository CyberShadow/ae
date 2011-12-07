/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Vladimir Panteleev <vladimir@thecybershadow.net>
 * Portions created by the Initial Developer are Copyright (C) 2007-2011
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Canvas wrapper and code for whole images.
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

	/// Does not resize
	void size(int w, int h)
	{
		this.w = w;
		this.h = h;
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
			result.draw(image, x, 0),
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
			result.draw(image, 0, y),
			y += image.h;
		return result;
	}

	Image!COLOR hflip()
	{
		auto newImage = Image!COLOR(w, h);
		foreach (y; 0..h)
			foreach (x, c; pixels[y*stride..y*stride+w])
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
	import crc32;
	import std.zlib;

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
		static assert(__traits(allMembers, COLOR.Fields).stringof == `tuple("r","g","b")`, "PNM only supports RGB, not " ~ __traits(allMembers, COLOR.Fields).stringof);
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
				pixel = COLOR.op!q{bswap(a)}(pixel);
	}

	void savePNM()(string filename) // RGB only
	{
		static assert(__traits(allMembers, COLOR).stringof == `tuple("r","g","b")`, "PNM only supports RGB");
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
				*p = bswap(*p);
		}
		std.file.write(filename, data);
	}

	void loadPGM()(string filename)
	{
		static assert(__traits(allMembers, COLOR.Fields).stringof == `tuple("g")`, "PGM only supports grayscale");
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
				pixel = bswap(pixel);
	}

	void savePGM()(string filename)
	{
		static assert(__traits(allMembers, COLOR.Fields).stringof == `tuple("g")`, "PGM only supports grayscale");
		ubyte[] header = cast(ubyte[])format("P5\n%d %d\n%d\n", w, h, COLOR.max);
		ubyte[] data = new ubyte[header.length + pixels.length * COLOR.sizeof];
		data[0..header.length] = header;
		COLOR* p = cast(COLOR*)(data.ptr + header.length);
		foreach (c; pixels)
			*p++ = bswap(c);
		std.file.write(filename, data);
	}

	void loadRGBA()(string filename, uint w, uint h)
	{
		static assert(__traits(allMembers, COLOR).stringof == `tuple("r","g","b","a")`, "COLOR is not RGBA");
		pixels = cast(COLOR[])read(filename);
		enforce(pixels.length == w*h, "Dimension / filesize mismatch");
		this.w = w;
		this.h = h;
	}

	// ***********************************************************************

	void savePNG()(string filename)
	{
		enum : ulong { SIGNATURE = 0x0a1a0a0d474e5089 }

		struct PNGChunk
		{
			char[4] type;
			const(void)[] data;

			uint crc32()
			{
				uint crc = strcrc32(type);
				foreach (v; cast(ubyte[])data)
					crc = update_crc32(v, crc);
				return ~crc;
			}

			this(string type, const(void)[] data)
			{
				this.type[] = type;
				this.data = data;
			}
		}

		enum PNGColourType : ubyte { G, RGB=2, PLTE, GA, RGBA=6 }
		enum PNGCompressionMethod : ubyte { DEFLATE }
		enum PNGFilterMethod : ubyte { ADAPTIVE }
		enum PNGInterlaceMethod : ubyte { NONE, ADAM7 }

		enum PNGFilterAdaptive : ubyte { NONE, SUB, UP, AVERAGE, PAETH }

		struct PNGHeader
		{
		align(1):
			uint width, height;
			ubyte colourDepth;
			PNGColourType colourType;
			PNGCompressionMethod compressionMethod;
			PNGFilterMethod filterMethod;
			PNGInterlaceMethod interlaceMethod;
			static assert(PNGHeader.sizeof == 13);
		}

		alias ChannelType!COLOR CHANNEL_TYPE;

		static if (!is(COLOR == struct))
			enum COLOUR_TYPE = PNGColourType.G;
		else
		static if (structFields!COLOR()==["r","g","b"])
			enum COLOUR_TYPE = PNGColourType.RGB;
		else
		static if (structFields!COLOR()==["g","a"])
			enum COLOUR_TYPE = PNGColourType.GA;
		else
		static if (structFields!COLOR()==["r","g","b","a"])
			enum COLOUR_TYPE = PNGColourType.RGBA;
		else
			static assert(0, "Unsupported PNG color type: " ~ COLOR.stringof);

		PNGChunk[] chunks;
		PNGHeader header = {
			width : bswap(w),
			height : bswap(h),
			colourDepth : CHANNEL_TYPE.sizeof * 8,
			colourType : COLOUR_TYPE,
			compressionMethod : PNGCompressionMethod.DEFLATE,
			filterMethod : PNGFilterMethod.ADAPTIVE,
			interlaceMethod : PNGInterlaceMethod.NONE,
		};
		chunks ~= PNGChunk("IHDR", cast(void[])[header]);
		uint idatStride = w*COLOR.sizeof+1;
		ubyte[] idatData = new ubyte[h*idatStride];
		for (uint y=0; y<h; y++)
		{
			idatData[y*idatStride] = PNGFilterAdaptive.NONE;
			auto rowPixels = cast(COLOR[])idatData[y*idatStride+1..(y+1)*idatStride];
			rowPixels[] = pixels[y*stride..(y+1)*stride];

			static if (CHANNEL_TYPE.sizeof > 1)
				foreach (ref p; cast(CHANNEL_TYPE[])rowPixels)
					p = bswap(p);
		}
		chunks ~= PNGChunk("IDAT", compress(idatData, 5));
		chunks ~= PNGChunk("IEND", null);

		uint totalSize = 8;
		foreach (chunk; chunks)
			totalSize += 8 + chunk.data.length + 4;
		ubyte[] data = new ubyte[totalSize];

		*cast(ulong*)data.ptr = SIGNATURE;
		uint pos = 8;
		foreach(chunk;chunks)
		{
			uint i = pos;
			uint chunkLength = chunk.data.length;
			pos += 12 + chunkLength;
			*cast(uint*)&data[i] = bswap(chunkLength);
			(cast(char[])data[i+4 .. i+8])[] = chunk.type;
			data[i+8 .. i+8+chunk.data.length] = cast(ubyte[])chunk.data;
			*cast(uint*)&data[i+8+chunk.data.length] = bswap(chunk.crc32());
			assert(pos == i+12+chunk.data.length);
		}
		std.file.write(filename, data);
	}

	// ***********************************************************************

	align(1)
	struct BitmapHeader
	{
		// BITMAPFILEHEADER
		char[2] bfType = "BM";
		uint    bfSize;
		ushort  bfReserved1;
		ushort  bfReserved2;
		uint    bfOffBits;

		// BITMAPCOREINFO
		uint   bcSize = this.sizeof - bcSize.offsetof;
		int    bcWidth;
		int    bcHeight;
		ushort bcPlanes;
		ushort bcBitCount;
	}

	void loadBMP()(string filename)
	{
		ubyte[] data = cast(ubyte[])read(filename);
		enforce(data.length > BitmapHeader.sizeof);
		BitmapHeader* header = cast(BitmapHeader*) data.ptr;
		enforce(header.bfType == "BM", "Invalid signature");
		enforce(header.bfSize == data.length, "Incorrect file size");
		enforce(header.bcSize >= BitmapHeader.sizeof - header.bcSize.offsetof);

		w = stride = header.bcWidth;
		h = header.bcHeight;
		enforce(header.bcPlanes==1, "Multiplane BMPs not supported");

		static if (is(COLOR == BGR))
			enforce(header.bcBitCount == 24, "Not a 24-bit BMP image");
		else
		static if (is(COLOR == BGRX) || is(COLOR == BGRA))
			enforce(header.bcBitCount == 32, "Not a 32-bit BMP image");
		else
		static if (is(COLOR == G8))
			enforce(header.bcBitCount == 8, "Not an 8-bit BMP image");
		else
			static assert(0, "Unsupported BMP color type: " ~ COLOR.stringof);

		auto pixelData = data[header.bfOffBits..$];
		int pixelStride = w * COLOR.sizeof;
		pixelStride = (pixelStride+3) & ~3;
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
	image.draw(c, 0, 0);
}

private
{
	// test intantiation
	alias Image!RGB RGBImage;
}
