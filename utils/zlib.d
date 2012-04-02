/**
 * Compress/decompress data using the zlib library.
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

module ae.utils.zlib;

import etc.c.zlib;
import std.conv;
import std.exception;

import ae.sys.data;

class ZlibException : Exception
{
	this(int err, z_stream* zs)
	{
		if (zs.msg)
			super(to!string(zs.msg));
		else
		{
			string msg;
			switch (err)
			{
				case Z_STREAM_END:      msg = "stream end"; break;
				case Z_NEED_DICT:       msg = "need dict"; break;
				case Z_ERRNO:           msg = "errno"; break;
				case Z_STREAM_ERROR:    msg = "stream error"; break;
				case Z_DATA_ERROR:      msg = "data error"; break;
				case Z_MEM_ERROR:       msg = "mem error"; break;
				case Z_BUF_ERROR:       msg = "buf error"; break;
				case Z_VERSION_ERROR:   msg = "version error"; break;
				default:                msg = "unknown error"; break;
			}
			super(msg);
		}
	}

	this(string msg) { super(msg); }
}

enum ZlibMode { normal, raw, gzipOnly, gzipAuto }

struct ZlibOptions
{
	int deflateLevel = Z_DEFAULT_COMPRESSION;
	int windowBits = 15; /// 8..15 - actual windowBits, without additional meaning
	ZlibMode mode;

	invariant()
	{
		assert(deflateLevel == Z_DEFAULT_COMPRESSION || (deflateLevel >= 0 && deflateLevel <= 9));
		assert(windowBits >= 8 && windowBits <= 15);
	}

private:
	@property
	int zwindowBits()
	{
		final switch (mode)
		{
		case ZlibMode.normal:
			return windowBits;
		case ZlibMode.raw:
			return -windowBits;
		case ZlibMode.gzipOnly:
			return 16+windowBits;
		case ZlibMode.gzipAuto:
			return 32+windowBits;
		}
	}
}

struct ZlibProcess(bool COMPRESSING)
{
	void init(ZlibOptions options = ZlibOptions.init)
	{
		static if (COMPRESSING)
			//zenforce(deflateInit(&zs, options.deflateLevel));
			zenforce(deflateInit2(&zs, options.deflateLevel, Z_DEFLATED, options.zwindowBits, 8, Z_DEFAULT_STRATEGY));
		else
			//zenforce(inflateInit(&zs));
			zenforce(inflateInit2(&zs, options.zwindowBits));
	}

	void processChunk(Data chunk)
	{
		if (!chunk.length)
			return;

		assert(zs.avail_in == 0);
		zs.next_in  = cast(ubyte*) chunk.ptr;
		zs.avail_in = to!uint(chunk.length);

		do
		{
			if (zs.avail_out == 0)
				allocChunk(adjustSize(zs.avail_in));

			assert(zs.avail_in  && zs.next_in );
			assert(zs.avail_out && zs.next_out);
			if (zend(processFunc(&zs, Z_NO_FLUSH)))
				enforce(zs.avail_in==0, new ZlibException("Trailing data"));
		} while (zs.avail_in);
	}

	Data[] flush()
	{
		if (zs.avail_out == 0)
			allocChunk(adjustSize(zs.avail_in));

		while (!zend(processFunc(&zs, Z_FINISH)))
			allocChunk(zs.avail_out*2+1);

		saveChunk();
		return outputChunks;
	}

	static Data[] process(Data[] input, ZlibOptions options = ZlibOptions.init)
	{
		typeof(this) zp;
		zp.init(options);
		foreach (ref chunk; input)
			zp.processChunk(chunk);
		return zp.flush();
	}

	static Data process(Data input, ZlibOptions options = ZlibOptions.init)
	{
		return process([input], options).joinData();
	}

private:
	z_stream zs;
	Data currentChunk;
	Data[] outputChunks;

	static if (COMPRESSING)
	{
		alias deflate processFunc;
		alias deflateEnd endFunc;

		size_t adjustSize(size_t sz) { return sz / 4 + 1; }
	}
	else
	{
		alias inflate processFunc;
		alias inflateEnd endFunc;

		size_t adjustSize(size_t sz) { return sz * 4 + 1; }
	}

	void zenforce(int ret)
	{
		if (ret != Z_OK)
			throw new ZlibException(ret, &zs);
	}

	bool zend(int ret)
	{
		if (ret == Z_STREAM_END)
			return true;
		zenforce(ret);
		return false;
	}

	void saveChunk()
	{
		if (zs.next_out && zs.next_out != currentChunk.ptr)
		{
			outputChunks ~= currentChunk[0..zs.next_out-currentChunk.ptr];
			currentChunk = Data();
		}
		zs.next_out = null;
	}

	void allocChunk(size_t sz)
	{
		saveChunk();
		currentChunk = Data(sz);
		currentChunk.length = currentChunk.capacity;
		zs.next_out  = cast(ubyte*)currentChunk.mptr;
		zs.avail_out = to!uint(currentChunk.length);
	}

	~this()
	{
		zenforce(endFunc(&zs));
	}
}

alias ZlibProcess!true  ZlibDeflater;
alias ZlibProcess!false ZlibInflater;

alias ZlibDeflater.process compress;
alias ZlibInflater.process uncompress;

Data compress(Data input, int level)
{
	return compress(input, ZlibOptions(level));
}

unittest
{
	void testRoundtrip(ubyte[] src)
	{
		ubyte[] def = cast(ubyte[])  compress(Data(src)).toHeap;
		ubyte[] res = cast(ubyte[])uncompress(Data(def)).toHeap;
		assert(res == src);
	}

	testRoundtrip(cast(ubyte[])
"the quick brown fox jumps over the lazy dog\r
the quick brown fox jumps over the lazy dog\r
");
	testRoundtrip([0]);
	testRoundtrip(null);
}
