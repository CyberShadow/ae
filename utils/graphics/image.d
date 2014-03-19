/**
 * In-memory images and various image formats.
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

import std.algorithm;
import std.conv : to;
import std.exception;
import std.range;
import std.string : format;

public import ae.utils.graphics.view;

/// Represents a reference to COLOR data
/// already existing elsewhere in memory.
/// Assumes that pixels are stored row-by-row,
/// with a known distance between each row.
struct ImageRef(COLOR)
{
	int w, h;
	size_t pitch; /// In bytes, not COLORs
	COLOR* pixels;

	/// Returns an array for the pixels at row y.
	COLOR[] scanline(int y)
	{
		assert(y>=0 && y<h);
		assert(pitch);
		auto row = cast(COLOR*)(cast(ubyte*)pixels + y*pitch);
		return row[0..w];
	}

	mixin DirectView;
}

unittest
{
	static assert(isDirectView!(ImageRef!ubyte));
}

/// Convert a direct view to an ImageRef.
/// Assumes that the rows are evenly spaced.
ImageRef!(ViewColor!SRC) toRef(SRC)(auto ref SRC src)
	if (isDirectView!SRC)
{
	return ImageRef!(ViewColor!SRC)(src.w, src.h,
		src.h > 1 ? cast(ubyte*)src.scanline(1) - cast(ubyte*)src.scanline(0) : src.w,
		src.scanline(0).ptr);
}

unittest
{
	auto i = Image!ubyte(1, 1);
	auto r = i.toRef();
	assert(r.scanline(0).ptr is i.scanline(0).ptr);
}

// ***************************************************************************

/// An in-memory image.
/// Pixels are stored in a flat array.
struct Image(COLOR)
{
	int w, h;
	COLOR[] pixels;

	/// Returns an array for the pixels at row y.
	COLOR[] scanline(int y)
	{
		assert(y>=0 && y<h);
		return pixels[w*y..w*(y+1)];
	}

	mixin DirectView;

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
}

unittest
{
	static assert(isDirectView!(Image!ubyte));
}

// ***************************************************************************

alias ViewImage(V) = Image!(ViewColor!V);

// The TARGET template parameter could be removed if this was fixed:
// https://d.puremagic.com/issues/show_bug.cgi?id=12386

/// Copy the given view into an image.
/// If no target is specified, a new image is allocated.
auto copy(SRC, TARGET = ViewImage!SRC)(auto ref SRC src, ref TARGET target = *new ViewImage!SRC)
	if (isView!SRC)
{
	target.size(src.w, src.h);
	src.blitTo(target);
	return target;
}

unittest
{
	auto v = onePixel(0);
	auto i = v.copy();
	v.copy(i);
}

alias ElementViewImage(R) = ViewImage!(ElementType!R);

/// Splice multiple images horizontally.
auto hjoin(R, TARGET = ElementViewImage!R)(R images, ref TARGET target = *new ElementViewImage!R)
	if (isView!(ElementType!R))
{
	int w, h;
	foreach (ref image; images)
		w += image.w,
		h = max(h, image.h);
	target.size(w, h);
	int x;
	foreach (ref image; images)
		image.blitTo(target, x, 0),
		x += image.w;
	return target;
}

/// Splice multiple images vertically.
auto vjoin(R, TARGET = ElementViewImage!R)(R images, ref TARGET target = *new ElementViewImage!R)
	if (isView!(ElementType!R))
{
	int w, h;
	foreach (ref image; images)
		w = max(w, image.w),
		h += image.h;
	target.size(w, h);
	int y;
	foreach (ref image; images)
		image.blitTo(target, 0, y),
		y += image.h;
	return target;
}

unittest
{
	auto h = 10
		.iota
		.retro
		.map!onePixel
		.retro
		.hjoin();

	foreach (i; 0..10)
		assert(h[i, 0] == i);

	auto v = 10.iota.map!onePixel.vjoin();
	foreach (i; 0..10)
		assert(v[0, i] == i);
}

// ***************************************************************************

/// Performs linear downscale by a constant factor
template downscale(int HRX, int HRY)
{
	auto downscale(SRC, TARGET = ViewImage!SRC)(auto ref SRC src,
			ref TARGET target = *new ViewImage!SRC)
		if (isDirectView!SRC)
	{
		alias lr = target;
		alias hr = src;

		assert(hr.w % HRX == 0 && hr.h % HRY == 0, "Size mismatch");

		lr.size(hr.w / HRX, hr.h / HRY);

		foreach (y; 0..lr.h)
			foreach (x; 0..lr.w)
			{
				static if (HRX*HRY <= 0x100)
					enum EXPAND_BYTES = 1;
				else
				static if (HRX*HRY <= 0x10000)
					enum EXPAND_BYTES = 2;
				else
					static assert(0);
				static if (is(typeof(COLOR.init.a))) // downscale with alpha
				{
					ExpandType!(COLOR, EXPAND_BYTES+COLOR.init.a.sizeof) sum;
					ExpandType!(typeof(COLOR.init.a), EXPAND_BYTES) alphaSum;
					auto start = y*HRY*hr.stride + x*HRX;
					foreach (j; 0..HRY)
					{
						foreach (p; hr.pixels[start..start+HRX])
						{
							foreach (i, f; p.tupleof)
								static if (p.tupleof[i].stringof != "p.a")
								{
									enum FIELD = p.tupleof[i].stringof[2..$];
									mixin("sum."~FIELD~" += cast(typeof(sum."~FIELD~"))p."~FIELD~" * p.a;");
								}
							alphaSum += p.a;
						}
						start += hr.stride;
					}
					if (alphaSum)
					{
						auto result = cast(COLOR)(sum / alphaSum);
						result.a = cast(typeof(result.a))(alphaSum / (HRX*HRY));
						lr[x, y] = result;
					}
					else
					{
						static assert(COLOR.init.a == 0);
						lr[x, y] = COLOR.init;
					}
				}
				else
				{
					ExpandChannelType!(ViewColor!SRC, EXPAND_BYTES) sum;
					auto x0 = x*HRX;
					auto x1 = x0+HRX;
					foreach (j; y*HRY..(y+1)*HRY)
						foreach (p; hr.scanline(j)[x0..x1])
							sum += p;
					lr[x, y] = cast(ViewColor!SRC)(sum / (HRX*HRY));
				}
			}

		return target;
	}
}

unittest
{
	onePixel(RGB.init).nearestNeighbor(4, 4).copy.downscale!(2, 2)();
}

// ***************************************************************************

/// Copy the indicated row of src to a COLOR buffer.
void copyScanline(SRC, COLOR)(auto ref SRC src, int y, COLOR[] dst)
	if (isView!SRC && is(COLOR == ViewColor!SRC))
{
	static if (isDirectView!SRC)
		dst[] = src.scanline(y)[];
	else
	{
		assert(src.w == dst.length);
		foreach (x; 0..src.w)
			dst[x] = src[x, y];
	}
}

/// Copy a view's pixels (top-to-bottom) to a COLOR buffer.
void copyPixels(SRC, COLOR)(auto ref SRC src, COLOR[] dst)
	if (isView!SRC && is(COLOR == ViewColor!SRC))
{
	assert(dst.length == src.w * src.h);
	foreach (y; 0..src.h)
		copyScanline(src, y, dst[y*src.w..(y+1)*src.w]);
}

// ***************************************************************************

import ae.utils.graphics.color;
import ae.utils.meta.misc;

private string[] readPBMHeader(ref const(ubyte)[] data)
{
	import std.ascii;

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

private template PBMSignature(COLOR)
{
	static if (structFields!COLOR == ["l"])
		enum PBMSignature = "P5";
	else
	static if (structFields!COLOR == ["r", "g", "b"])
		enum PBMSignature = "P6";
	else
		static assert(false, "Unsupported PBM color: " ~
			__traits(allMembers, COLOR.Fields).stringof);
}

/// Parses a binary Netpbm monochrome (.pgm) or RGB (.ppm) file.
auto parsePBM(COLOR, TARGET = Image!COLOR)(const(void)[] vdata, ref TARGET target = *new Image!COLOR)
{
	auto data = cast(const(ubyte)[])vdata;
	string[] fields = readPBMHeader(data);
	enforce(fields[0]==PBMSignature!COLOR, "Invalid signature");
	enforce(to!uint(fields[3]) == COLOR.tupleof[0].max, "Channel depth mismatch");

	target.size(to!uint(fields[1]), to!uint(fields[2]));
	enforce(data.length / COLOR.sizeof == target.w * target.h,
		"Dimension / filesize mismatch");
	target.pixels[] = cast(COLOR[])data;

	static if (COLOR.tupleof[0].sizeof > 1)
		foreach (ref pixel; pixels)
			pixel = COLOR.op!q{swapBytes(a)}(pixel); // TODO: proper endianness support

	return target;
}

unittest
{
	auto data = "P6\n2\n2\n255\n" ~
		x"000000 FFF000"
		x"000FFF FFFFFF";
	auto i = data.parsePBM!RGB();
	assert(i[0, 0] == RGB.fromHex("000000"));
	assert(i[0, 1] == RGB.fromHex("000FFF"));
}

unittest
{
	auto data = "P5\n2\n2\n255\n" ~
		x"00 55"
		x"AA FF";
	auto i = data.parsePBM!L8();
	assert(i[0, 0] == L8(0x00));
	assert(i[0, 1] == L8(0xAA));
}

/// Creates a binary Netpbm monochrome (.pgm) or RGB (.ppm) file.
ubyte[] toPBM(SRC)(auto ref SRC src)
	if (isView!SRC)
{
	alias COLOR = ViewColor!SRC;

	auto length = src.w * src.h;
	ubyte[] header = cast(ubyte[])"%s\n%d %d %d\n"
		.format(PBMSignature!COLOR, src.w, src.h, ChannelType!COLOR.max);
	ubyte[] data = new ubyte[header.length + length * COLOR.sizeof];

	data[0..header.length] = header;
	src.copyPixels(cast(COLOR[])data[header.length..$]);

	static if (ChannelType!COLOR.sizeof > 1)
		foreach (ref p; cast(ChannelType!COLOR[])data[header.length..$])
			p = swapBytes(p); // TODO: proper endianness support

	return data;
}

unittest
{
	assert(onePixel(RGB(1,2,3)).toPBM == "P6\n1 1 255\n" ~ x"01 02 03");
	assert(onePixel(L8 (1)    ).toPBM == "P5\n1 1 255\n" ~ x"01"      );
}

// ***************************************************************************

/// Loads a raw COLOR[] into an image of the indicated size.
auto fromPixels(COLOR)(COLOR[] pixels, uint w, uint h,
	ref Image!COLOR target = *new Image!COLOR)
{
	enforce(pixels.length == w*h, "Dimension / filesize mismatch");
	target.size(w, h);
	target.pixels[] = pixels;
	return target;
}

/// ditto
auto fromPixels(COLOR)(const(void)[] pixels, uint w, uint h,
	ref Image!COLOR target = *new Image!COLOR)
{
	return fromPixels(cast(COLOR[])pixels, w, h, target);
}

unittest
{
	auto i = x"42".fromPixels!L8(1, 1);
	assert(i[0, 0].l == 0x42);
}

// ***************************************************************************

alias int FXPT2DOT30;
struct CIEXYZ { FXPT2DOT30 ciexyzX, ciexyzY, ciexyzZ; }
struct CIEXYZTRIPLE { CIEXYZ ciexyzRed, ciexyzGreen, ciexyzBlue; }
enum { BI_BITFIELDS = 3 }

align(1)
struct BitmapHeader(uint V)
{
	enum VERSION = V;

align(1):
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
	uint   biCompression;
	uint   biSizeImage;
	uint   biXPelsPerMeter;
	uint   biYPelsPerMeter;
	uint   biClrUsed;
	uint   biClrImportant;

	// BITMAPV4HEADER
	static if (V>=4)
	{
		uint         bV4RedMask;
		uint         bV4GreenMask;
		uint         bV4BlueMask;
		uint         bV4AlphaMask;
		uint         bV4CSType;
		CIEXYZTRIPLE bV4Endpoints;
		uint         bV4GammaRed;
		uint         bV4GammaGreen;
		uint         bV4GammaBlue;
	}

	// BITMAPV5HEADER
	static if (V>=5)
	{
		uint        bV5Intent;
		uint        bV5ProfileData;
		uint        bV5ProfileSize;
		uint        bV5Reserved;
	}
}

template bitmapBitCount(COLOR)
{
	static if (is(COLOR == BGR))
		enum bitmapBitCount = 24;
	else
	static if (is(COLOR == BGRX) || is(COLOR == BGRA))
		enum bitmapBitCount = 32;
	else
	static if (is(COLOR == G8))
		enum bitmapBitCount = 8;
	else
		static assert(false, "Unsupported BMP color type: " ~ COLOR.stringof);
}

@property int bitmapPixelStride(COLOR)(int w)
{
	int pixelStride = w * cast(uint)COLOR.sizeof;
	pixelStride = (pixelStride+3) & ~3;
	return pixelStride;
}

/// Parses a Windows bitmap (.bmp) file.
auto parseBMP(COLOR, TARGET = Image!COLOR)(const(void)[] data, ref TARGET target = *new Image!COLOR)
{
	alias BitmapHeader!3 Header;
	enforce(data.length > Header.sizeof);
	Header* header = cast(Header*) data.ptr;
	enforce(header.bfType == "BM", "Invalid signature");
	enforce(header.bfSize == data.length, "Incorrect file size (%d in header, %d in file)"
		.format(header.bfSize, data.length));
	enforce(header.bcSize >= Header.sizeof - header.bcSize.offsetof);

	auto w = header.bcWidth;
	auto h = header.bcHeight;
	enforce(header.bcPlanes==1, "Multiplane BMPs not supported");

	enforce(header.bcBitCount == bitmapBitCount!COLOR,
		"Mismatching BMP bcBitCount - trying to load a %d-bit .BMP file to a %d-bit Image"
		.format(header.bcBitCount, bitmapBitCount!COLOR));

	auto pixelData = data[header.bfOffBits..$];
	auto pixelStride = bitmapPixelStride!COLOR(w);
	size_t pos = 0;

	if (h < 0)
		h = -h;
	else
	{
		pos = pixelStride*(h-1);
		pixelStride = -pixelStride;
	}

	target.size(w, h);
	foreach (y; 0..h)
	{
		target.scanline(y)[] = (cast(COLOR*)(pixelData.ptr+pos))[0..w];
		pos += pixelStride;
	}

	return target;
}

unittest
{
	alias parseBMP!BGR parseBMP24;
}

/// Creates a Windows bitmap (.bmp) file.
ubyte[] toBMP(SRC)(auto ref SRC src)
	if (isDirectView!SRC)
{
	alias COLOR = ViewColor!SRC;

	static if (COLOR.sizeof > 3)
		alias BitmapHeader!4 Header;
	else
		alias BitmapHeader!3 Header;

	auto pixelStride = bitmapPixelStride!COLOR(src.w);
	auto bitmapDataSize = src.h * pixelStride;
	ubyte[] data = new ubyte[Header.sizeof + bitmapDataSize];
	auto header = cast(Header*)data.ptr;
	*header = Header.init;
	header.bfSize = to!uint(data.length);
	header.bfOffBits = Header.sizeof;
	header.bcWidth = src.w;
	header.bcHeight = -src.h;
	header.bcPlanes = 1;
	header.biSizeImage = bitmapDataSize;
	header.bcBitCount = bitmapBitCount!COLOR;

	static if (header.VERSION >= 4)
	{
		header.biCompression = BI_BITFIELDS;

		COLOR c;
		foreach (i, f; c.tupleof)
		{
			enum CHAN = c.tupleof[i].stringof[2..$];
			enum MASK = (cast(uint)typeof(c.tupleof[i]).max) << (c.tupleof[i].offsetof*8);
			static if (CHAN=="r")
				header.bV4RedMask   |= MASK;
			else
			static if (CHAN=="g")
				header.bV4GreenMask |= MASK;
			else
			static if (CHAN=="b")
				header.bV4BlueMask  |= MASK;
			else
			static if (CHAN=="a")
				header.bV4AlphaMask |= MASK;
		}
	}

	auto pixelData = data[header.bfOffBits..$];
	auto ptr = pixelData.ptr;
	size_t pos = 0;

	foreach (y; 0..src.h)
	{
		(cast(COLOR*)ptr)[0..src.w] = src.scanline(y);
		ptr += pixelStride;
	}

	return data;
}

unittest
{
	onePixel(BGR(1,2,3)).copy.toBMP();
}

// ***************************************************************************

/// Creates a PNG file.
/// Only basic PNG features are supported
/// (no filters, interlacing, palettes etc.)
ubyte[] toPNG(SRC)(auto ref SRC src)
	if (isView!SRC)
{
	import std.digest.crc;
	import std.zlib : compress;
	import ae.utils.math : swapBytes; // TODO: proper endianness support

	enum : ulong { SIGNATURE = 0x0a1a0a0d474e5089 }

	struct PNGChunk
	{
		char[4] type;
		const(void)[] data;

		uint crc32()
		{
			CRC32 crc;
			crc.put(cast(ubyte[])(type[]));
			crc.put(cast(ubyte[])data);
			ubyte[4] hash = crc.finish();
			return *cast(uint*)hash.ptr;
		}

		this(string type, const(void)[] data)
		{
			this.type[] = type[];
			this.data = data;
		}
	}

	enum PNGColourType : ubyte { G, RGB=2, PLTE, GA, RGBA=6 }
	enum PNGCompressionMethod : ubyte { DEFLATE }
	enum PNGFilterMethod : ubyte { ADAPTIVE }
	enum PNGInterlaceMethod : ubyte { NONE, ADAM7 }

	enum PNGFilterAdaptive : ubyte { NONE, SUB, UP, AVERAGE, PAETH }

	align(1)
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

	alias COLOR = ViewColor!SRC;
	static if (!is(COLOR == struct))
		enum COLOUR_TYPE = PNGColourType.G;
	else
	static if (structFields!COLOR == ["l"])
		enum COLOUR_TYPE = PNGColourType.G;
	else
	static if (structFields!COLOR == ["r","g","b"])
		enum COLOUR_TYPE = PNGColourType.RGB;
	else
	static if (structFields!COLOR == ["l","a"])
		enum COLOUR_TYPE = PNGColourType.GA;
	else
	static if (structFields!COLOR == ["r","g","b","a"])
		enum COLOUR_TYPE = PNGColourType.RGBA;
	else
		static assert(0, "Unsupported PNG color type: " ~ COLOR.stringof);

	PNGChunk[] chunks;
	PNGHeader header = {
		width : swapBytes(src.w),
		height : swapBytes(src.h),
		colourDepth : ChannelType!COLOR.sizeof * 8,
		colourType : COLOUR_TYPE,
		compressionMethod : PNGCompressionMethod.DEFLATE,
		filterMethod : PNGFilterMethod.ADAPTIVE,
		interlaceMethod : PNGInterlaceMethod.NONE,
	};
	chunks ~= PNGChunk("IHDR", cast(void[])[header]);
	uint idatStride = to!uint(src.w * COLOR.sizeof+1);
	ubyte[] idatData = new ubyte[src.h * idatStride];
	for (uint y=0; y<src.h; y++)
	{
		idatData[y*idatStride] = PNGFilterAdaptive.NONE;
		auto rowPixels = cast(COLOR[])idatData[y*idatStride+1..(y+1)*idatStride];
		src.copyScanline(y, rowPixels);

		static if (ChannelType!COLOR.sizeof > 1)
			foreach (ref p; cast(ChannelType!COLOR[])rowPixels)
				p = swapBytes(p);
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
		uint chunkLength = to!uint(chunk.data.length);
		pos += 12 + chunkLength;
		*cast(uint*)&data[i] = swapBytes(chunkLength);
		(cast(char[])data[i+4 .. i+8])[] = chunk.type[];
		data[i+8 .. i+8+chunk.data.length] = (cast(ubyte[])chunk.data)[];
		*cast(uint*)&data[i+8+chunk.data.length] = swapBytes(chunk.crc32());
		assert(pos == i+12+chunk.data.length);
	}

	return data;
}

unittest
{
	onePixel(RGB(1,2,3)).toPNG();
	onePixel(5).toPNG();
}
