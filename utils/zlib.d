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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.utils.zlib;

import etc.c.zlib;
import std.algorithm.mutation : move;
import std.conv;
import std.exception;

import ae.sys.data;
import ae.sys.dataset : DataVec, joinData;
import ae.utils.array;

/// Thrown on zlib errors.
class ZlibException : Exception
{
	private static string getmsg(int err) nothrow @nogc pure @safe
	{
		switch (err)
		{
			case Z_STREAM_END:      return "stream end";
			case Z_NEED_DICT:       return "need dict";
			case Z_ERRNO:           return "errno";
			case Z_STREAM_ERROR:    return "stream error";
			case Z_DATA_ERROR:      return "data error";
			case Z_MEM_ERROR:       return "mem error";
			case Z_BUF_ERROR:       return "buf error";
			case Z_VERSION_ERROR:   return "version error";
			default:                return "unknown error";
		}
	}

	this(int err, z_stream* zs)
	{
		if (zs.msg)
			super(to!string(zs.msg));
		else
			super(getmsg(err));
	} ///

	this(string msg) { super(msg); } ///
}

/// File format.
enum ZlibMode
{
	normal,   /// Normal deflate stream.
	raw,      /// Raw deflate stream.
	gzipOnly, /// gzip deflate stream. Require gzip input.
	gzipAuto, /// Output and detect gzip, but do not require it.
}

/// Compression/decompression options.
struct ZlibOptions
{
	int deflateLevel = Z_DEFAULT_COMPRESSION; /// Compression level.
	int windowBits = 15; /// Window size (8..15) - actual windowBits, without additional meaning
	ZlibMode mode; /// File format.

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

/// Implements a zlib compression or decompression process.
struct ZlibProcess(bool COMPRESSING)
{
	/// Initialize zlib.
	void init(ZlibOptions options = ZlibOptions.init)
	{
		static if (COMPRESSING)
			//zenforce(deflateInit(&zs, options.deflateLevel));
			zenforce(deflateInit2(&zs, options.deflateLevel, Z_DEFLATED, options.zwindowBits, 8, Z_DEFAULT_STRATEGY));
		else
			//zenforce(inflateInit(&zs));
			zenforce(inflateInit2(&zs, options.zwindowBits));
		initialized_ = true;
	}

	/// Process one chunk of data.
	void processChunk(ref const Data chunk)
	{
		if (!chunk.length)
			return;

		assert(zs.avail_in == 0);
		// zlib will consume all data, so unsafeContents is OK to use here
		scope(success) assert(zs.avail_in == 0);
		// cast+unsafeContents because const(Data) is not copyable, can't use asDataOf, does this even make sense?
		zs.next_in  = cast(ubyte*) chunk.unsafeContents.ptr;
		zs.avail_in = to!uint(chunk.unsafeContents.length);

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

	/// Signal end of input and flush.
	DataVec flush()
	{
		if (zs.avail_out == 0)
			allocChunk(adjustSize(zs.avail_in));

		while (!zend(processFunc(&zs, Z_FINISH)))
		{
			// Allocate reasonable chunk size instead of 1 byte when avail_out==0
			import std.algorithm.comparison : max;
			allocChunk(max(zs.avail_out*2+1, 4096));
		}

		saveChunk();
		return move(outputChunks);
	}

	/// Flush pending output without ending the stream.
	/// Unlike `flush`, which uses `Z_FINISH` and terminates the stream,
	/// this uses `Z_SYNC_FLUSH` and keeps the stream alive for further
	/// `processChunk` / `syncFlush` cycles.
	DataVec syncFlush()
	{
		if (zs.avail_out == 0)
			allocChunk(adjustSize(1));

		while (true)
		{
			auto ret = processFunc(&zs, Z_SYNC_FLUSH);
			if (ret != Z_OK && ret != Z_BUF_ERROR)
				throw new ZlibException(ret, &zs);
			if (zs.avail_out > 0)
				break;
			allocChunk(4096);
		}

		saveChunk();
		zs.avail_out = 0; // force new allocation on next processChunk
		return move(outputChunks);
	}

	/// Reset the stream to its initial state without deallocating.
	/// This is used for "no context takeover" in WebSocket permessage-deflate,
	/// where each message must be compressed/decompressed independently.
	void reset()
	{
		saveChunk();
		outputChunks = DataVec.init;
		zs.avail_out = 0;
		zenforce(resetFunc(&zs));
	}

	/// Process all input.
	static DataVec process(scope const(Data)[] input, ZlibOptions options = ZlibOptions.init)
	{
		typeof(this) zp;
		zp.init(options);
		foreach (ref chunk; input)
			zp.processChunk(chunk);
		return zp.flush();
	}

	/// Process input and return output as a single contiguous `Data`.
	static Data process(Data input, ZlibOptions options = ZlibOptions.init)
	{
		return process(input.asSlice, options).joinData();
	}

	~this()
	{
		if (initialized_)
			endFunc(&zs);
	}

private:
	z_stream zs;
	Data currentChunk;
	DataVec outputChunks;
	bool initialized_;

	static if (COMPRESSING)
	{
		alias deflate processFunc;
		alias deflateEnd endFunc;
		alias deflateReset resetFunc;

		size_t adjustSize(size_t sz) { return sz / 4 + 1; }
	}
	else
	{
		alias inflate processFunc;
		alias inflateEnd endFunc;
		alias inflateReset resetFunc;

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
		if (zs.next_out && zs.next_out != currentChunk.unsafeContents.ptr)
		{
			outputChunks ~= currentChunk[0..zs.next_out-cast(ubyte*)currentChunk.unsafeContents.ptr];
			currentChunk = Data();
		}
		zs.next_out = null;
	}

	void allocChunk(size_t sz)
	{
		saveChunk();
		currentChunk = Data(sz);
		currentChunk.length = currentChunk.capacity;
		zs.next_out  = cast(ubyte*)currentChunk.unsafeContents.ptr;
		zs.avail_out = to!uint(currentChunk.length);
	}
}

alias ZlibProcess!true  ZlibDeflater; /// ditto
alias ZlibProcess!false ZlibInflater; /// ditto

alias ZlibDeflater.process compress;   ///
alias ZlibInflater.process uncompress; ///

/// Shorthand for compressing at a certain level.
Data compress(Data input, int level)
{
	return compress(input, ZlibOptions(level));
}

debug(ae_unittest) unittest
{
	void testRoundtrip(ubyte[] src)
	{
		ubyte[] def =   compress(Data(src)).asDataOf!ubyte.toGC;
		ubyte[] res = uncompress(Data(def)).asDataOf!ubyte.toGC;
		assert(res == src);
	}

	testRoundtrip(cast(ubyte[])
"the quick brown fox jumps over the lazy dog\r
the quick brown fox jumps over the lazy dog\r
");
	testRoundtrip([0]);
	testRoundtrip(null);
}

debug(ae_unittest) unittest
{
	// Test syncFlush for streaming compression/decompression (raw deflate)
	auto original = cast(ubyte[])(
		"the quick brown fox jumps over the lazy dog\r\n" ~
		"the quick brown fox jumps over the lazy dog\r\n");

	ZlibDeflater deflater;
	deflater.init(ZlibOptions(ZlibOptions.init.deflateLevel, 15, ZlibMode.raw));

	auto chunk = Data(original);
	deflater.processChunk(chunk);
	auto compressed1 = deflater.syncFlush().joinData;

	// Compress a second identical message through the same stream
	deflater.processChunk(chunk);
	auto compressed2 = deflater.syncFlush().joinData;

	// Context takeover: second message should compress at least as well
	assert(compressed2.length <= compressed1.length);

	// Decompress both messages through a single inflate stream
	ZlibInflater inflater;
	inflater.init(ZlibOptions(ZlibOptions.init.deflateLevel, 15, ZlibMode.raw));

	inflater.processChunk(compressed1);
	auto decompressed1 = inflater.syncFlush().joinData;
	assert(decompressed1.asDataOf!ubyte.toGC == original);

	inflater.processChunk(compressed2);
	auto decompressed2 = inflater.syncFlush().joinData;
	assert(decompressed2.asDataOf!ubyte.toGC == original);
}
