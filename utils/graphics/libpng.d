/**
 * libpng support.
 *
 * License:
 *	 This Source Code Form is subject to the terms of
 *	 the Mozilla Public License, v. 2.0. If a copy of
 *	 the MPL was not distributed with this file, You
 *	 can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *	 Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.graphics.libpng;

import std.exception;
import std.string : fromStringz;

debug(LIBPNG) import std.stdio : stderr;

import ae.utils.graphics.color;
import ae.utils.graphics.image;

import libpng.png;
import libpng.pnglibconf;

pragma(lib, "png");

struct PNGReader
{
	// Settings

	bool strict = true; // Throw on corrupt / invalid data vs. ignore errors as much as possible
	enum Depth { d8, d16 } Depth depth;
	enum Channels { gray, rgb, bgr } Channels channels;
	enum Alpha { none, alpha, filler } Alpha alpha;
	enum AlphaLocation { before, after } AlphaLocation alphaLocation;
	ubyte[] defaultColor;

	// Callbacks

	void delegate(int width, int height) infoHandler;
	ubyte[] delegate(uint rowNum) rowGetter;
	void delegate(uint rowNum, int pass) rowHandler;
	void delegate() endHandler;

	// Data

	size_t rowbytes;
	uint passes;

	// Public interface

	void init()
	{
		png_ptr = png_create_read_struct(
			png_get_libpng_ver(null),
			&this,
			&libpngErrorHandler,
			&libpngWarningHandler
		).enforce("png_create_read_struct");
		scope(failure) png_destroy_read_struct(&png_ptr, null, null);

		info_ptr = png_create_info_struct(png_ptr)
			.enforce("png_create_info_struct");

		if (!strict)
			png_set_crc_action(png_ptr, PNG_CRC_QUIET_USE, PNG_CRC_QUIET_USE);

		png_set_progressive_read_fn(png_ptr,
			&this,
			&libpngInfoCallback,
			&libpngRowCallback,
			&libpngEndCallback,
		);
	}

	void put(ubyte[] data)
	{
		png_process_data(png_ptr, info_ptr, data.ptr, data.length);
	}

private:
	png_structp	png_ptr;
	png_infop info_ptr;

	static extern(C) void libpngInfoCallback(png_structp png_ptr, png_infop info_ptr)
	{
		int	color_type, bit_depth;
		png_uint_32 width, height;

		auto self = cast(PNGReader*)png_get_progressive_ptr(png_ptr);
		assert(self);

		png_get_IHDR(png_ptr, info_ptr, &width, &height, &bit_depth, &color_type,
			null, null, null);

		png_set_expand(png_ptr);

		version (LittleEndian)
			png_set_swap(png_ptr);

		final switch (self.depth)
		{
			case Depth.d8:
				png_set_scale_16(png_ptr);
				break;
			case Depth.d16:
				png_set_expand_16(png_ptr);
				break;
		}

		final switch (self.channels)
		{
			case Channels.gray:
				png_set_rgb_to_gray(png_ptr,
					PNG_ERROR_ACTION_NONE,
					PNG_RGB_TO_GRAY_DEFAULT,
					PNG_RGB_TO_GRAY_DEFAULT
				);
				break;
			case Channels.rgb:
				png_set_gray_to_rgb(png_ptr);
				break;
			case Channels.bgr:
				png_set_gray_to_rgb(png_ptr);
				png_set_bgr(png_ptr);
				break;
		}

		if (self.alpha != Alpha.alpha)
		{
			png_set_strip_alpha(png_ptr);

			png_color_16p image_background;
			if (png_get_bKGD(png_ptr, info_ptr, &image_background))
			{
				if (image_background.gray == 0 &&
					(
						image_background.red != 0 ||
						image_background.green != 0 ||
						image_background.blue != 0
					))
				{
					// Work around libpng bug.
					// Note: this conversion uses a different algorithm than libpng...
					debug(LIBPNG) stderr.writeln("Manually adding gray image background.");
					image_background.gray = (image_background.red + image_background.green + image_background.blue) / 3;
				}

				png_set_background(png_ptr, image_background,
					PNG_BACKGROUND_GAMMA_FILE, 1/*needs to be expanded*/, 1);
			}
			else
			if (self.defaultColor)
				png_set_background(png_ptr,
					cast(png_const_color_16p)self.defaultColor.ptr,
					PNG_BACKGROUND_GAMMA_SCREEN, 0/*do not expand*/, 1);
		}

		if (self.alpha != Alpha.none)
		{
			int location;
			final switch (self.alphaLocation)
			{
				case AlphaLocation.before:
					location = PNG_FILLER_BEFORE;
					png_set_swap_alpha(png_ptr);
					break;
				case AlphaLocation.after:
					location = PNG_FILLER_AFTER;
					break;
			}
			final switch (self.alpha)
			{
				case Alpha.none:
					assert(false);
				case Alpha.alpha:
					png_set_add_alpha(png_ptr, 0xFFFFFFFF, location);
					break;
				case Alpha.filler:
					png_set_filler(png_ptr, 0, location);
					break;
			}
		}

		self.passes = png_set_interlace_handling(png_ptr);

		png_read_update_info(png_ptr, info_ptr);

		self.rowbytes = cast(int)png_get_rowbytes(png_ptr, info_ptr);

		if (self.infoHandler)
			self.infoHandler(width, height);
	}

	extern(C) static void libpngRowCallback(png_structp png_ptr, png_bytep new_row, png_uint_32 row_num, int pass)
	{
		auto self = cast(PNGReader*)png_get_progressive_ptr(png_ptr);
		assert(self);

		auto row = self.rowGetter(row_num);
		if (row.length != self.rowbytes)
			assert(false, "Row size mismatch");

		png_progressive_combine_row(png_ptr, row.ptr, new_row);

		if (self.rowHandler)
			self.rowHandler(row_num, pass);
	}

	extern(C) static void libpngEndCallback(png_structp png_ptr, png_infop info_ptr)
	{
		auto self = cast(PNGReader*)png_get_progressive_ptr(png_ptr);
		assert(self);

		if (self.endHandler)
			self.endHandler();
	}

	extern(C) static void libpngWarningHandler(png_structp png_ptr, png_const_charp msg)
	{
		debug(LIBPNG) stderr.writeln("PNG warning: ", fromStringz(msg));

		auto self = cast(PNGReader*)png_get_progressive_ptr(png_ptr);
		assert(self);

		if (self.strict)
			throw new Exception("PNG warning: " ~ fromStringz(msg).assumeUnique);
	}

	extern(C) static void libpngErrorHandler(png_structp png_ptr, png_const_charp msg)
	{
		debug(LIBPNG) stderr.writeln("PNG error: ", fromStringz(msg));

		auto self = cast(PNGReader*)png_get_progressive_ptr(png_ptr);
		assert(self);

		// We must stop execution here, otherwise libpng abort()s
		throw new Exception("PNG error: " ~ fromStringz(msg).assumeUnique);
	}

	@disable this(this);

	~this()
	{
		if (png_ptr && info_ptr)
			png_destroy_read_struct(&png_ptr, &info_ptr, null);
		png_ptr = null;
		info_ptr = null;
	}
}

Image!COLOR decodePNG(COLOR)(ubyte[] data, bool strict = true)
{
	Image!COLOR img;

	PNGReader reader;
	reader.strict = strict;
	reader.init();

	// Depth

	static if (is(ChannelType!COLOR == ubyte))
		reader.depth = PNGReader.Depth.d8;
	else
	static if (is(ChannelType!COLOR == ushort))
		reader.depth = PNGReader.Depth.d16;
	else
		static assert(false, "Can't read PNG into " ~ ChannelType!COLOR.stringof ~ " channels");

	// Channels

	static if (!is(COLOR == struct))
		enum channels = ["l"];
	else
	{
		import ae.utils.meta : structFields;
		enum channels = structFields!COLOR;
	}

	// Alpha location

	static if (channels[0] == "a" || channels[0] == "x")
	{
		reader.alphaLocation = PNGReader.AlphaLocation.before;
		enum alphaChannel = channels[0];
		enum colorChannels = channels[1 .. $];
	}
	else
	static if (channels[$-1] == "a" || channels[$-1] == "x")
	{
		reader.alphaLocation = PNGReader.AlphaLocation.after;
		enum alphaChannel = channels[$-1];
		enum colorChannels = channels[0 .. $-1];
	}
	else
	{
		enum alphaChannel = null;
		enum colorChannels = channels;
	}

	// Alpha kind

	static if (alphaChannel is null)
		reader.alpha = PNGReader.Alpha.none;
	else
	static if (alphaChannel == "a")
		reader.alpha = PNGReader.Alpha.alpha;
	else
	static if (alphaChannel == "x")
		reader.alpha = PNGReader.Alpha.filler;
	else
		static assert(false);

	// Channel order

	static if (colorChannels == ["l"])
		reader.channels = PNGReader.Channels.gray;
	else
	static if (colorChannels == ["r", "g", "b"])
		reader.channels = PNGReader.Channels.rgb;
	else
	static if (colorChannels == ["b", "g", "r"])
		reader.channels = PNGReader.Channels.bgr;
	else
		static assert(false, "Can't read PNG into channel order " ~ channels.stringof);

	// Delegates

	reader.infoHandler = (int width, int height)
	{
		img.size(width, height);
	};

	reader.rowGetter = (uint rowNum)
	{
		return cast(ubyte[])img.scanline(rowNum);
	};

	reader.put(data);

	return img;
}

unittest
{
	static struct BitWriter
	{
		ubyte[] buf;
		size_t off; ubyte bit;

		void write(T)(T value, ubyte size)
		{
			foreach_reverse (vBit; 0..size)
			{
				ubyte b = cast(ubyte)(ulong(value) >> vBit) & 1;
				auto bBit = 7 - this.bit;
				buf[this.off] |= b << bBit;
				if (++this.bit == 8)
				{
					this.bit = 0;
					this.off++;
				}
			}
		}
	}

	static void testColor(PNGReader.Depth depth, PNGReader.Channels channels, PNGReader.Alpha alpha, PNGReader.AlphaLocation alphaLocation)()
	{
		debug(LIBPNG) stderr.writefln(">>> COLOR depth=%-3s channels=%-4s alpha=%-6s alphaloc=%-6s",
			depth, channels, alpha, alphaLocation);

		static if (depth == PNGReader.Depth.d8)
			alias ChannelType = ubyte;
		else
		static if (depth == PNGReader.Depth.d16)
			alias ChannelType = ushort;
		else
			static assert(false);

		static if (alpha == PNGReader.Alpha.none)
			enum string[] alphaField = [];
		else
		static if (alpha == PNGReader.Alpha.alpha)
			enum alphaField = ["a"];
		else
		static if (alpha == PNGReader.Alpha.filler)
			enum alphaField = ["x"];
		else
			static assert(false);

		static if (channels == PNGReader.Channels.gray)
			enum channelFields = ["l"];
		else
		static if (channels == PNGReader.Channels.rgb)
			enum channelFields = ["r", "g", "b"];
		else
		static if (channels == PNGReader.Channels.bgr)
			enum channelFields = ["b", "g", "r"];
		else
			static assert(false);

		static if (alphaLocation == PNGReader.AlphaLocation.before)
			enum fields = alphaField ~ channelFields;
		else
		static if (alphaLocation == PNGReader.AlphaLocation.after)
			enum fields = channelFields ~ alphaField;
		else
			static assert(false);

		import ae.utils.meta : ArrayToTuple;
		alias COLOR = Color!(ChannelType, ArrayToTuple!fields);

		enum Bkgd { none, black, white }

		static void testPNG(ubyte pngDepth, bool pngPaletted, bool pngColor, bool pngAlpha, bool pngTrns, Bkgd pngBkgd)
		{
			debug(LIBPNG) stderr.writefln("   > PNG depth=%2d palette=%d color=%d alpha=%d trns=%d bkgd=%-5s",
				pngDepth, pngPaletted, pngColor, pngAlpha, pngTrns, pngBkgd);

			void skip(string msg) { debug(LIBPNG) stderr.writefln("     >> Skipped: %s", msg); }

			enum numPixels = 7;

			if (pngPaletted && !pngColor)
				return skip("Palette without color rejected by libpng ('Invalid color type in IHDR')");
			if (pngPaletted && pngAlpha)
				return skip("Palette with alpha rejected by libpng ('Invalid color type in IHDR')");
			if (pngPaletted && pngDepth > 8)
				return skip("Large palette rejected by libpng ('Invalid color type/bit depth combination in IHDR')");
			if (pngAlpha && pngDepth < 8)
				return skip("Alpha with low bit depth rejected by libpng ('Invalid color type/bit depth combination in IHDR')");
			if (pngColor && !pngPaletted && pngDepth < 8)
				return skip("Non-palette RGB with low bit depth rejected by libpng ('Invalid color type/bit depth combination in IHDR')");
			if (pngTrns && pngAlpha)
				return skip("tRNS with alpha is redundant, libpng complains ('invalid with alpha channel')");
			if (pngTrns && !pngPaletted && pngDepth < 2)
				return skip("Not enough bits to represent tRNS color");
			if (pngPaletted && (1 << pngDepth) < numPixels)
				return skip("Not enough bits to represent all palette color indices");

			import std.bitmanip : nativeToBigEndian;
			import std.conv : to;
			import std.algorithm.iteration : sum;

			ubyte pngChannelSize;
			if (pngPaletted)
				pngChannelSize = 8; // PLTE is always 8-bit
			else
				pngChannelSize = pngDepth;

			ulong pngChannelMax = (1 << pngChannelSize) - 1;
			ulong pngChannelMed = pngChannelMax / 2;
			ulong bkgdColor = [pngChannelMed, 0, pngChannelMax][pngBkgd];
			ulong[4][numPixels] pixels = [
				[            0,             0,             0, pngChannelMax], // black
				[pngChannelMax, pngChannelMax, pngChannelMax, pngChannelMax], // white
				[pngChannelMax, pngChannelMed,             0, pngChannelMax], // red
				[            0, pngChannelMed, pngChannelMax, pngChannelMax], // blue
				[     ulong(0),             0,             0,             0], // transparent (zero alpha)
				[            1,             2,             3, pngChannelMax], // transparent (tRNS color)
				[bkgdColor    , bkgdColor    , bkgdColor    , pngChannelMax], // bKGD color (for palette index)
			];
			enum pixelIndexTRNS = 5;
			enum pixelIndexBKGD = 6;

			ubyte colourType;
			if (pngPaletted)
				colourType |= PNG_COLOR_MASK_PALETTE;
			if (pngColor)
				colourType |= PNG_COLOR_MASK_COLOR;
			if (pngAlpha)
				colourType |= PNG_COLOR_MASK_ALPHA;

			PNGChunk[] chunks;
			PNGHeader header = {
				width : nativeToBigEndian(int(pixels.length)),
				height : nativeToBigEndian(1),
				colourDepth : pngDepth,
				colourType : cast(PNGColourType)colourType,
				compressionMethod : PNGCompressionMethod.DEFLATE,
				filterMethod : PNGFilterMethod.ADAPTIVE,
				interlaceMethod : PNGInterlaceMethod.NONE,
			};
			chunks ~= PNGChunk("IHDR", cast(void[])[header]);

			if (pngPaletted)
			{
				auto palette = BitWriter(new ubyte[3 * pixels.length]);
				foreach (pixel; pixels)
					foreach (channel; pixel[0..3])
						palette.write(channel, 8);
				chunks ~= PNGChunk("PLTE", palette.buf);
			}

			if (pngTrns)
			{
				BitWriter trns;
				if (pngPaletted)
				{
					trns = BitWriter(new ubyte[pixels.length]);
					foreach (pixel; pixels)
						trns.write(pixel[3] * 255 / pngChannelMax, 8);
				}
				else
				if (pngColor)
				{
					trns = BitWriter(new ubyte[3 * ushort.sizeof]);
					foreach (channel; pixels[pixelIndexTRNS][0..3])
						trns.write(channel, 16);
				}
				else
				{
					trns = BitWriter(new ubyte[ushort.sizeof]);
					trns.write(pixels[pixelIndexTRNS][0..3].sum / 3, 16);
				}
				debug(LIBPNG) stderr.writefln("     tRNS=%s", trns.buf);
				chunks ~= PNGChunk("tRNS", trns.buf);
			}

			if (pngBkgd != Bkgd.none)
			{
				BitWriter bkgd;
				if (pngPaletted)
				{
					bkgd = BitWriter(new ubyte[1]);
					bkgd.write(pixelIndexBKGD, 8);
				}
				else
				if (pngColor)
				{
					bkgd = BitWriter(new ubyte[3 * ushort.sizeof]);
					foreach (channel; 0..3)
						bkgd.write(bkgdColor, 16);
				}
				else
				{
					bkgd = BitWriter(new ubyte[ushort.sizeof]);
					bkgd.write(bkgdColor, 16);
				}
				chunks ~= PNGChunk("bKGD", bkgd.buf);
			}

			auto channelBits = pixels.length * pngDepth;

			uint pngChannels;
			if (pngPaletted)
				pngChannels = 1;
			else
			if (pngColor)
				pngChannels = 3;
			else
				pngChannels = 1;
			if (pngAlpha)
				pngChannels++;
			auto pixelBits = channelBits * pngChannels;

			auto pixelBytes = (pixelBits + 7) / 8;
			uint idatStride = to!uint(1 + pixelBytes);
			auto idat = BitWriter(new ubyte[idatStride]);
			idat.write(PNGFilterAdaptive.NONE, 8);

			foreach (x; 0 .. pixels.length)
			{
				if (pngPaletted)
					idat.write(x, pngDepth);
				else
				if (pngColor)
					foreach (channel; pixels[x][0..3])
						idat.write(channel, pngDepth);
				else
					idat.write(pixels[x][0..3].sum / 3, pngDepth);

				if (pngAlpha)
					idat.write(pixels[x][3], pngDepth);
			}

			import std.zlib : compress;
			chunks ~= PNGChunk("IDAT", compress(idat.buf, 0));

			chunks ~= PNGChunk("IEND", null);

			auto bytes = makePNG(chunks);
			auto img = decodePNG!COLOR(bytes);

			assert(img.w == pixels.length);
			assert(img.h == 1);

			import std.conv : text;

			// Solids

			void checkSolid(bool nontrans=false)(int x, ulong[3] spec)
			{
				ChannelType r = cast(ChannelType)(spec[0] * ChannelType.max / pngChannelMax);
				ChannelType g = cast(ChannelType)(spec[1] * ChannelType.max / pngChannelMax);
				ChannelType b = cast(ChannelType)(spec[2] * ChannelType.max / pngChannelMax);

				immutable c = img[x, 0];

				scope(failure) debug(LIBPNG) stderr.writeln("x:", x, " def:", spec, " / expected:", [r,g,b], " / got:", c);

				static if (nontrans)
				{ /* Already checked alpha / filler in checkTransparent */ }
				else
				static if (alpha == PNGReader.Alpha.filler)
				{
					assert(c.x == 0);
				}
				else
				static if (alpha == PNGReader.Alpha.alpha)
					assert(c.a == ChannelType.max);

				ChannelType norm(ChannelType v)
				{
					uint pngMax;
					if (pngPaletted)
						pngMax = 255;
					else
						pngMax = (1 << pngDepth) - 1;
					return cast(ChannelType)(v * pngMax / ChannelType.max * ChannelType.max / pngMax);
				}

				if (!pngColor)
					r = g = b = (r + g + b) / 3;

				static if (channels == PNGReader.Channels.gray)
				{
					if (spec == [1,2,3])
						assert(c.l <= norm(b));
					else
					if (pngColor && spec[0..3].sum / 3 == pngChannelMax / 2)
					{
						// libpng's RGB to grayscale conversion is not straight-forward,
						// do a range check
						assert(c.l > 0 && c.l < ChannelType.max);
					}
					else
						assert(c.l == norm((r + g + b) / 3), text(c.l, " != ", norm((r + g + b) / 3)));
				}
				else
				{
					assert(c.r == norm(r));
					assert(c.g == norm(g));
					assert(c.b == norm(b));
				}
			}

			foreach (x; 0..4)
				checkSolid(x, pixels[x][0..3]);

			// Transparency

			void checkTransparent(int x, ulong[3] bgColor)
			{
				auto c = img[x, 0];

				scope(failure) debug(LIBPNG) stderr.writeln("x:", x, " def:", pixels[x], " / got:", c);

				static if (alpha == PNGReader.Alpha.alpha)
					assert(c.a == 0);
				else
				{
					static if (alpha == PNGReader.Alpha.filler)
						assert(c.x == 0);

					ulong[3] bg = pngBkgd != Bkgd.none ? [bkgdColor, bkgdColor, bkgdColor] : bgColor;
					ChannelType[3] cbg;
					foreach (i; 0..3)
						cbg[i] = cast(ChannelType)(bg[i] * ChannelType.max / pngChannelMax);

					checkSolid!true(x, bg);
				}
			}

			if (pngAlpha || (pngTrns && pngPaletted))
				checkTransparent(4, [0,0,0]);
			else
				checkSolid(4, [0,0,0]);

			if (pngTrns && !pngPaletted)
			{
				if (pngBkgd != Bkgd.none)
				{} // libpng bug!
				else
					checkTransparent(5, [1,2,3]);
			}
			else
				checkSolid(5, [1,2,3]);
		}

		foreach (ubyte pngDepth; [1, 2, 4, 8, 16])
			foreach (pngPaletted; [false, true])
				foreach (pngColor; [false, true])
					foreach (pngAlpha; [false, true])
						foreach (pngTrns; [false, true])
							foreach (pngBkgd; [EnumMembers!Bkgd]) // absent, black, white
								testPNG(pngDepth, pngPaletted, pngColor, pngAlpha, pngTrns, pngBkgd);
	}

	import std.traits : EnumMembers;
	foreach (depth; EnumMembers!(PNGReader.Depth))
		foreach (channels; EnumMembers!(PNGReader.Channels))
			foreach (alpha; EnumMembers!(PNGReader.Alpha))
				foreach (alphaLocation; EnumMembers!(PNGReader.AlphaLocation))
					testColor!(depth, channels, alpha, alphaLocation);
}
