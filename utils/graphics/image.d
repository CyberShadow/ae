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
	inout(COLOR)[] scanline(int y) inout
	{
		assert(y>=0 && y<h, "Scanline out-of-bounds");
		assert(pitch, "Pitch not set");
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
	inout(COLOR)[] scanline(int y) inout
	{
		assert(y>=0 && y<h, "Scanline out-of-bounds");
		auto start = w*y;
		return pixels[start..start+w];
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

// Functions which need a target image to operate on are currenty declared
// as two overloads. The code might be simplified if some of these get fixed:
// https://d.puremagic.com/issues/show_bug.cgi?id=8074
// https://d.puremagic.com/issues/show_bug.cgi?id=12386
// https://d.puremagic.com/issues/show_bug.cgi?id=12425
// https://d.puremagic.com/issues/show_bug.cgi?id=12426
// https://d.puremagic.com/issues/show_bug.cgi?id=12433

alias ViewImage(V) = Image!(ViewColor!V);

/// Copy the given view into the specified target.
auto copy(SRC, TARGET)(auto ref SRC src, auto ref TARGET target)
	if (isView!SRC && isWritableView!TARGET)
{
	target.size(src.w, src.h);
	src.blitTo(target);
	return target;
}

/// Copy the given view into a newly-allocated image.
auto copy(SRC)(auto ref SRC src)
	if (isView!SRC)
{
	ViewImage!SRC target;
	return src.copy(target);
}

unittest
{
	auto v = onePixel(0);
	auto i = v.copy();
	v.copy(i);

	auto c = i.crop(0, 0, 1, 1);
	v.copy(c);
}

alias ElementViewImage(R) = ViewImage!(ElementType!R);

/// Splice multiple images horizontally.
auto hjoin(R, TARGET)(R images, auto ref TARGET target)
	if (isInputRange!R && isView!(ElementType!R) && isWritableView!TARGET)
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
/// ditto
auto hjoin(R)(R images)
	if (isInputRange!R && isView!(ElementType!R))
{
	ElementViewImage!R target;
	return images.hjoin(target);
}

/// Splice multiple images vertically.
auto vjoin(R, TARGET)(R images, auto ref TARGET target)
	if (isInputRange!R && isView!(ElementType!R) && isWritableView!TARGET)
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
/// ditto
auto vjoin(R)(R images)
	if (isInputRange!R && isView!(ElementType!R))
{
	ElementViewImage!R target;
	return images.vjoin(target);
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
template downscale(int HRX, int HRY=HRX)
{
	auto downscale(SRC, TARGET)(auto ref SRC src, auto ref TARGET target)
		if (isDirectView!SRC && isWritableView!TARGET)
	{
		alias lr = target;
		alias hr = src;
		alias COLOR = ViewColor!SRC;

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
					version (none) // TODO: broken
					{
						ExpandChannelType!(COLOR, EXPAND_BYTES+COLOR.init.a.sizeof) sum;
						ExpandChannelType!(typeof(COLOR.init.a), EXPAND_BYTES) alphaSum;
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
						static assert(false, "Downscaling with alpha is not implemented");
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

	auto downscale(SRC)(auto ref SRC src)
		if (isView!SRC)
	{
		ViewImage!SRC target;
		return src.downscale(target);
	}
}

unittest
{
	onePixel(RGB.init).nearestNeighbor(4, 4).copy.downscale!(2, 2)();
//	onePixel(RGBA.init).nearestNeighbor(4, 4).copy.downscale!(2, 2)();

	Image!ubyte i;
	i.size(4, 1);
	i.pixels[] = [1, 3, 5, 7];
	auto d = i.downscale!(2, 1);
	assert(d.pixels == [2, 6]);
}

// ***************************************************************************

/// Downscaling copy (averages colors in source per one pixel in target).
auto downscaleTo(SRC, TARGET)(auto ref SRC src, auto ref TARGET target)
if (isDirectView!SRC && isWritableView!TARGET)
{
	alias lr = target;
	alias hr = src;
	alias COLOR = ViewColor!SRC;

	void impl(uint EXPAND_BYTES)()
	{
		foreach (y; 0..lr.h)
			foreach (x; 0..lr.w)
			{
				static if (is(typeof(COLOR.init.a))) // downscale with alpha
					static assert(false, "Downscaling with alpha is not implemented");
				else
				{
					ExpandChannelType!(ViewColor!SRC, EXPAND_BYTES) sum;
					auto x0 =  x    * hr.w / lr.w;
					auto x1 = (x+1) * hr.w / lr.w;
					auto y0 =  y    * hr.h / lr.h;
					auto y1 = (y+1) * hr.h / lr.h;

					// When upscaling (across one or two axes),
					// fall back to nearest neighbor
					if (x0 == x1) x1++;
					if (y0 == y1) y1++;

					foreach (j; y0 .. y1)
						foreach (p; hr.scanline(j)[x0 .. x1])
							sum += p;
					auto area = (x1 - x0) * (y1 - y0);
					auto avg = sum / area;
					lr[x, y] = cast(ViewColor!SRC)(avg);
				}
			}
	}

	auto perPixelArea = (hr.w / lr.w + 1) * (hr.h / lr.h + 1);

	if (perPixelArea <= 0x100)
		impl!1();
	else
	if (perPixelArea <= 0x10000)
		impl!2();
	else
	if (perPixelArea <= 0x1000000)
		impl!3();
	else
		assert(false, "Downscaling too much");

	return target;
}

/// Downscales an image to a certain size.
auto downscaleTo(SRC)(auto ref SRC src, int w, int h)
if (isView!SRC)
{
	ViewImage!SRC target;
	target.size(w, h);
	return src.downscaleTo(target);
}

unittest
{
	onePixel(RGB.init).nearestNeighbor(4, 4).copy.downscaleTo(2, 2);
//	onePixel(RGBA.init).nearestNeighbor(4, 4).copy.downscaleTo(2, 2);

	Image!ubyte i;
	i.size(6, 1);
	i.pixels[] = [1, 2, 3, 4, 5, 6];
	assert(i.downscaleTo(6, 1).pixels == [1, 2, 3, 4, 5, 6]);
	assert(i.downscaleTo(3, 1).pixels == [1, 3, 5]);
	assert(i.downscaleTo(2, 1).pixels == [2, 5]);
	assert(i.downscaleTo(1, 1).pixels == [3]);

	i.size(3, 3);
	i.pixels[] = [
		1, 2, 3,
		4, 5, 6,
		7, 8, 9];
	assert(i.downscaleTo(2, 2).pixels == [1, 2, 5, 7]);

	i.size(1, 1);
	i.pixels = [1];
	assert(i.downscaleTo(2, 2).pixels == [1, 1, 1, 1]);
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
		src.copyScanline(y, dst[y*src.w..(y+1)*src.w]);
}

// ***************************************************************************

import std.traits;

// Workaround for https://d.puremagic.com/issues/show_bug.cgi?id=12433

struct InputColor {}
alias GetInputColor(COLOR, INPUT) = Select!(is(COLOR == InputColor), INPUT, COLOR);

struct TargetColor {}
enum isTargetColor(C, TARGET) = is(C == TargetColor) || is(C == ViewColor!TARGET);

// ***************************************************************************

import ae.utils.graphics.color;
import ae.utils.meta : structFields;

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
auto parsePBM(C = TargetColor, TARGET)(const(void)[] vdata, auto ref TARGET target)
	if (isWritableView!TARGET && isTargetColor!(C, TARGET))
{
	alias COLOR = ViewColor!TARGET;

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
/// ditto
auto parsePBM(COLOR)(const(void)[] vdata)
{
	Image!COLOR target;
	return vdata.parsePBM(target);
}

unittest
{
	import std.conv : hexString;
	auto data = "P6\n2\n2\n255\n" ~
		hexString!"000000 FFF000" ~
		hexString!"000FFF FFFFFF";
	auto i = data.parsePBM!RGB();
	assert(i[0, 0] == RGB.fromHex("000000"));
	assert(i[0, 1] == RGB.fromHex("000FFF"));
}

unittest
{
	import std.conv : hexString;
	auto data = "P5\n2\n2\n255\n" ~
		hexString!"00 55" ~
		hexString!"AA FF";
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
	import std.conv : hexString;
	assert(onePixel(RGB(1,2,3)).toPBM == "P6\n1 1 255\n" ~ hexString!"01 02 03");
	assert(onePixel(L8 (1)    ).toPBM == "P5\n1 1 255\n" ~ hexString!"01"      );
}

// ***************************************************************************

/// Loads a raw COLOR[] into an image of the indicated size.
auto fromPixels(C = InputColor, INPUT, TARGET)(INPUT[] input, uint w, uint h,
		auto ref TARGET target)
	if (isWritableView!TARGET
	 && is(GetInputColor!(C, INPUT) == ViewColor!TARGET))
{
	alias COLOR = ViewColor!TARGET;

	auto pixels = cast(COLOR[])input;
	enforce(pixels.length == w*h, "Dimension / filesize mismatch");
	target.size(w, h);
	target.pixels[] = pixels;
	return target;
}

/// ditto
auto fromPixels(C = InputColor, INPUT)(INPUT[] input, uint w, uint h)
{
	alias COLOR = GetInputColor!(C, INPUT);
	Image!COLOR target;
	return fromPixels!COLOR(input, w, h, target);
}

unittest
{
	import std.conv : hexString;
	Image!L8 i;
	i = hexString!"42".fromPixels!L8(1, 1);
	i = hexString!"42".fromPixels!L8(1, 1, i);
	assert(i[0, 0].l == 0x42);
	i = (cast(L8[])hexString!"42").fromPixels(1, 1);
	i = (cast(L8[])hexString!"42").fromPixels(1, 1, i);
}

// ***************************************************************************

static import ae.utils.graphics.bitmap;

enum bitmapNeedV4Header(COLOR) = !is(COLOR == BGR) && !is(COLOR == BGRX);

uint[4] bitmapChannelMasks(COLOR)()
{
	uint[4] result;
	foreach (i, f; COLOR.init.tupleof)
	{
		enum channelName = __traits(identifier, COLOR.tupleof[i]);
		static if (channelName != "x")
			static assert((COLOR.tupleof[i].offsetof + COLOR.tupleof[i].sizeof) * 8 <= 32,
				"Color " ~ COLOR.stringof ~ " (channel " ~ channelName ~ ") is too large for BMP");

		enum MASK = (cast(uint)typeof(COLOR.tupleof[i]).max) << (COLOR.tupleof[i].offsetof*8);
		static if (channelName == "r")
			result[0] |= MASK;
		else
		static if (channelName == "g")
			result[1] |= MASK;
		else
		static if (channelName == "b")
			result[2] |= MASK;
		else
		static if (channelName == "a")
			result[3] |= MASK;
		else
		static if (channelName == "l")
		{
			result[0] |= MASK;
			result[1] |= MASK;
			result[2] |= MASK;
		}
		else
		static if (channelName == "x")
		{
		}
		else
			static assert(false, "Don't know how to encode channelNamenel " ~ channelName);
	}
	return result;
}

@property int bitmapPixelStride(COLOR)(int w)
{
	int pixelStride = w * cast(uint)COLOR.sizeof;
	pixelStride = (pixelStride+3) & ~3;
	return pixelStride;
}

/// Returns a view representing a BMP file.
/// Does not copy pixel data.
auto viewBMP(COLOR, V)(V data)
if (is(V : const(void)[]))
{
	import ae.utils.graphics.bitmap;
	alias BitmapHeader!3 Header;
	enforce(data.length > Header.sizeof, "Not enough data for header");
	Header* header = cast(Header*) data.ptr;
	enforce(header.bfType == "BM", "Invalid signature");
	enforce(header.bfSize == data.length, "Incorrect file size (%d in header, %d in file)"
		.format(header.bfSize, data.length));
	enforce(header.bcSize >= Header.sizeof - header.bcSize.offsetof);

	static struct BMP
	{
		int w, h;
		typeof(data.ptr) pixelData;
		int pixelStride;

		inout(COLOR)[] scanline(int y) inout // TODO constness
		{
			assert(y >= 0 && y < h, "BMP scanline out of bounds");
			return (cast(COLOR*)(pixelData + y * pixelStride))[0..w];
		}

		mixin DirectView;
	}
	BMP bmp;

	bmp.w = header.bcWidth;
	bmp.h = header.bcHeight;
	enforce(header.bcPlanes==1, "Multiplane BMPs not supported");

	enforce(header.bcBitCount == COLOR.sizeof * 8,
		"Mismatching BMP bcBitCount - trying to load a %d-bit .BMP file to a %d-bit Image"
		.format(header.bcBitCount, COLOR.sizeof * 8));

	static if (bitmapNeedV4Header!COLOR)
		enforce(header.VERSION >= 4, "Need a V4+ header to load a %s image".format(COLOR.stringof));
	if (header.VERSION >= 4)
	{
		enforce(data.length > BitmapHeader!4.sizeof, "Not enough data for header");
		auto header4 = cast(BitmapHeader!4*) data.ptr;
		uint[4] fileMasks = [
			header4.bV4RedMask,
			header4.bV4GreenMask,
			header4.bV4BlueMask,
			header4.bV4AlphaMask];
		static immutable expectedMasks = bitmapChannelMasks!COLOR();
		enforce(fileMasks == expectedMasks,
			"Channel format mask mismatch.\nExpected: [%(%32b, %)]\nIn file : [%(%32b, %)]"
			.format(expectedMasks, fileMasks));
	}

	bmp.pixelData = data[header.bfOffBits..$].ptr;
	bmp.pixelStride = bitmapPixelStride!COLOR(bmp.w);

	if (bmp.h < 0)
		bmp.h = -bmp.h;
	else
	{
		bmp.pixelData += bmp.pixelStride * (bmp.h - 1);
		bmp.pixelStride = -bmp.pixelStride;
	}

	return bmp;
}

/// Parses a Windows bitmap (.bmp) file.
auto parseBMP(C = TargetColor, TARGET)(const(void)[] data, auto ref TARGET target)
	if (isWritableView!TARGET && isTargetColor!(C, TARGET))
{
	alias COLOR = ViewColor!TARGET;
	viewBMP!COLOR(data).copy(target);
	return target;
}
/// ditto
auto parseBMP(COLOR)(const(void)[] data)
{
	Image!COLOR target;
	return data.parseBMP(target);
}

unittest
{
	alias parseBMP!BGR parseBMP24;
}

/// Creates a Windows bitmap (.bmp) file.
ubyte[] toBMP(SRC)(auto ref SRC src)
	if (isView!SRC)
{
	alias COLOR = ViewColor!SRC;

	import ae.utils.graphics.bitmap;
	static if (bitmapNeedV4Header!COLOR)
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
	header.bcBitCount = COLOR.sizeof * 8;

	static if (header.VERSION >= 4)
	{
		header.biCompression = BI_BITFIELDS;
		static immutable masks = bitmapChannelMasks!COLOR();
		header.bV4RedMask   = masks[0];
		header.bV4GreenMask = masks[1];
		header.bV4BlueMask  = masks[2];
		header.bV4AlphaMask = masks[3];
	}

	auto pixelData = data[header.bfOffBits..$];
	auto ptr = pixelData.ptr;
	size_t pos = 0;

	foreach (y; 0..src.h)
	{
		src.copyScanline(y, (cast(COLOR*)ptr)[0..src.w]);
		ptr += pixelStride;
	}

	return data;
}

unittest
{
	Image!BGR output;
	onePixel(BGR(1,2,3)).toBMP().parseBMP!BGR(output);
}

// ***************************************************************************

enum ulong PNGSignature = 0x0a1a0a0d474e5089;

struct PNGChunk
{
	char[4] type;
	const(void)[] data;

	uint crc32()
	{
		import std.digest.crc;
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
	ubyte[4] width, height;
	ubyte colourDepth;
	PNGColourType colourType;
	PNGCompressionMethod compressionMethod;
	PNGFilterMethod filterMethod;
	PNGInterlaceMethod interlaceMethod;
	static assert(PNGHeader.sizeof == 13);
}

/// Creates a PNG file.
/// Only basic PNG features are supported
/// (no filters, interlacing, palettes etc.)
ubyte[] toPNG(SRC)(auto ref SRC src, int compressionLevel = 5)
	if (isView!SRC)
{
	import std.zlib : compress;
	import std.bitmanip : nativeToBigEndian, swapEndian;

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
		width : nativeToBigEndian(src.w),
		height : nativeToBigEndian(src.h),
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

		version (LittleEndian)
			static if (ChannelType!COLOR.sizeof > 1)
				foreach (ref p; cast(ChannelType!COLOR[])rowPixels)
					p = swapEndian(p);
	}
	chunks ~= PNGChunk("IDAT", compress(idatData, compressionLevel));
	chunks ~= PNGChunk("IEND", null);

	return makePNG(chunks);
}

ubyte[] makePNG(PNGChunk[] chunks)
{
	import std.bitmanip : nativeToBigEndian;

	uint totalSize = 8;
	foreach (chunk; chunks)
		totalSize += 8 + chunk.data.length + 4;
	ubyte[] data = new ubyte[totalSize];

	*cast(ulong*)data.ptr = PNGSignature;
	uint pos = 8;
	foreach(chunk;chunks)
	{
		uint i = pos;
		uint chunkLength = to!uint(chunk.data.length);
		pos += 12 + chunkLength;
		*cast(ubyte[4]*)&data[i] = nativeToBigEndian(chunkLength);
		(cast(char[])data[i+4 .. i+8])[] = chunk.type[];
		data[i+8 .. i+8+chunk.data.length] = (cast(ubyte[])chunk.data)[];
		*cast(ubyte[4]*)&data[i+8+chunk.data.length] = nativeToBigEndian(chunk.crc32());
		assert(pos == i+12+chunk.data.length);
	}

	return data;
}

unittest
{
	onePixel(RGB(1,2,3)).toPNG();
	onePixel(5).toPNG();
}
