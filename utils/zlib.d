/**
 * Compress/decompress data using the zlib library. Originally from Phobos module std.zlib.
 * Modified to use Data class.
 *
 * References:
 *      	$(LINK2 http://en.wikipedia.org/wiki/Zlib, Wikipedia)
 * License:
 *      	Public Domain
 *
 * Macros:
 *      	WIKI = Phobos/StdZlib
 */


module ae.utils.zlib;

//debug=zlib;   			// uncomment to turn on debugging printf's

private import etc.c.zlib;
import ae.sys.data;
import std.conv; // to!int
debug import std.stdio;

// Values for 'mode'

enum
{
	Z_NO_FLUSH      = 0,
	Z_SYNC_FLUSH    = 2,
	Z_FULL_FLUSH    = 3,
	Z_FINISH        = 4,
}

/*************************************
 * Errors throw a ZlibException.
 */

class ZlibException : Exception
{
	this(int errnum)
	{   string msg;

		switch (errnum)
		{
			case Z_STREAM_END:  	msg = "stream end"; break;
			case Z_NEED_DICT:   	msg = "need dict"; break;
			case Z_ERRNO:       	msg = "errno"; break;
			case Z_STREAM_ERROR:        msg = "stream error"; break;
			case Z_DATA_ERROR:  	msg = "data error"; break;
			case Z_MEM_ERROR:   	msg = "mem error"; break;
			case Z_BUF_ERROR:   	msg = "buf error"; break;
			case Z_VERSION_ERROR:       msg = "version error"; break;
			default:    		msg = "unknown error";	break;
		}
		super(msg);
	}
}

/**************************************************
 * Compute the Adler32 checksum of the data in buf[]. adler is the starting
 * value when computing a cumulative checksum.
 */

uint adler32(uint adler, void[] buf)
{
	return etc.c.zlib.adler32(adler, cast(ubyte *)buf, to!int(buf.length));
}

unittest
{
	static ubyte[] data = [1,2,3,4,5,6,7,8,9,10];

	uint adler;

	debug(zlib) printf("D.zlib.adler32.unittest\n");
	adler = adler32(0u, cast(void[])data);
	debug(zlib) printf("adler = %x\n", adler);
	assert(adler == 0xdc0037);
}

/*********************************
 * Compute the CRC32 checksum of the data in buf[]. crc is the starting value
 * when computing a cumulative checksum.
 */

uint crc32(uint crc, void[] buf)
{
	return etc.c.zlib.crc32(crc, cast(ubyte *)buf, to!int(buf.length));
}

unittest
{
	static ubyte[] data = [1,2,3,4,5,6,7,8,9,10];

	uint crc;

	debug(zlib) printf("D.zlib.crc32.unittest\n");
	crc = crc32(0u, cast(void[])data);
	debug(zlib) printf("crc = %x\n", crc);
	assert(crc == 0x2520577b);
}

/*********************************************
 * Compresses the data in srcbuf[] using compression _level level.
 * The default value
 * for level is 6, legal values are 1..9, with 1 being the least compression
 * and 9 being the most.
 * Returns the compressed data.
 */

Data compress(Data srcbuf, int level)
in
{
	assert(-1 <= level && level <= 9);
}
body
{
	int err;
	Data destbuf;
	size_t destlen;

	destlen = srcbuf.length + ((srcbuf.length + 1023) / 1024) + 12;
	destbuf = Data(destlen);
	err = etc.c.zlib.compress2(cast(ubyte*)destbuf.ptr, &destlen, cast(ubyte*)srcbuf.ptr, srcbuf.length, level);
	if (err)
	{   destbuf.deleteContents();
		throw new ZlibException(err);
	}

	destbuf.length = destlen;
	return destbuf;
}

/*********************************************
 * ditto
 */

Data compress(Data buf)
{
	return compress(buf, Z_DEFAULT_COMPRESSION);
}

/*********************************************
 * Decompresses the data in srcbuf[].
 * Params: destlen = size of the uncompressed data.
 * It need not be accurate, but the decompression will be faster if the exact
 * size is supplied.
 * Returns: the decompressed data.
 */

Data uncompress(Data srcbuf, size_t destlen = 0u, int winbits = 15)
{
	int err;
	Data destbuf;

	if (!destlen)
		destlen = srcbuf.length * 2 + 1;

	while (1)
	{
		etc.c.zlib.z_stream zs;

		destbuf = Data(destlen);

		zs.next_in = cast(ubyte*) srcbuf.ptr;
		zs.avail_in = to!int(srcbuf.length);

		zs.next_out = cast(ubyte*) destbuf.ptr;
		zs.avail_out = to!int(destlen);

		err = etc.c.zlib.inflateInit2(&zs, winbits);
		if (err)
		{   destbuf.deleteContents;
			throw new ZlibException(err);
		}
		err = etc.c.zlib.inflate(&zs, Z_NO_FLUSH);
		switch (err)
		{
			case Z_OK:
				etc.c.zlib.inflateEnd(&zs);
				destlen = destbuf.length * 2;
				continue;

			case Z_STREAM_END:
				destbuf.length = zs.total_out;
				err = etc.c.zlib.inflateEnd(&zs);
				if (err != Z_OK)
					goto Lerr;
				return destbuf;

			default:
				etc.c.zlib.inflateEnd(&zs);
			Lerr:
				destbuf.deleteContents;
				throw new ZlibException(err);
		}
	}
	assert(0);
}

unittest
{
	ubyte[] src = cast(ubyte[])
"the quick brown fox jumps over the lazy dog\r
the quick brown fox jumps over the lazy dog\r
";
	ubyte[] result;

	//arrayPrint(src);
	result = cast(ubyte[])uncompress(compress(new Data(src))).contents;
	//arrayPrint(result);
	assert(result == src);
}

/+
void arrayPrint(ubyte[] array)
{
	//printf("array %p,%d\n", (void*)array, array.length);
	for (int i = 0; i < array.length; i++)
	{
		printf("%02x ", array[i]);
		if (((i + 1) & 15) == 0)
			printf("\n");
	}
	printf("\n\n");
}
+/

/*********************************************
 * Used when the data to be compressed is not all in one buffer.
 */

class Compress
{
  private:
	z_stream zs;
	int level = Z_DEFAULT_COMPRESSION;
	int inited;
	Data zs_in;

	void error(int err)
	{
		if (inited)
		{   deflateEnd(&zs);
			inited = 0;
		}
		throw new ZlibException(err);
	}

  public:

	/**
	 * Construct. level is the same as for D.zlib.compress().
	 */
	this(int level)
	in
	{
		assert(1 <= level && level <= 9);
	}
	body
	{
		this.level = level;
	}

	/// ditto
	this()
	{
	}

	~this()
	{   int err;

		if (inited)
		{
			inited = 0;
			err = deflateEnd(&zs);
			if (err)
				error(err);
		}
	}

	/**
	 * Compress the data in buf and return the compressed data.
	 * The buffers
	 * returned from successive calls to this should be concatenated together.
	 */
	Data compress(Data buf)
	{   int err;
		Data destbuf;

		if (buf.length == 0)
			return destbuf;

		if (!inited)
		{
			err = deflateInit(&zs, level);
			if (err)
				error(err);
			inited = 1;
		}

		destbuf = Data(zs.avail_in + buf.length);
		zs.next_out = cast(ubyte*)destbuf.ptr;
		zs.avail_out = to!int(destbuf.length);

		if (zs.avail_in)
			buf = zs.next_in[0 .. zs.avail_in] ~ buf;

		zs.next_in = cast(ubyte*) buf.ptr;
		zs.avail_in = to!int(buf.length);
		zs_in = buf; // hold reference

		err = deflate(&zs, Z_NO_FLUSH);
		if (err != Z_STREAM_END && err != Z_OK)
		{   destbuf.deleteContents;
			error(err);
		}
		destbuf.length = destbuf.length - zs.avail_out;
		return destbuf;
	}

	/***
	 * Compress and return any remaining data.
	 * The returned data should be appended to that returned by compress().
	 * Params:
	 *  mode = one of the following:
	 *  	$(DL
					$(DT Z_SYNC_FLUSH )
					$(DD Syncs up flushing to the next byte boundary.
						Used when more data is to be compressed later on.)
					$(DT Z_FULL_FLUSH )
					$(DD Syncs up flushing to the next byte boundary.
						Used when more data is to be compressed later on,
						and the decompressor needs to be restartable at this
						point.)
					$(DT Z_FINISH)
					$(DD (default) Used when finished compressing the data. )
				)
	 */
	Data flush(int mode = Z_FINISH)
	in
	{
		assert(mode == Z_FINISH || mode == Z_SYNC_FLUSH || mode == Z_FULL_FLUSH);
	}
	body
	{
		Data destbuf;
		ubyte[512] tmpbuf = void;
		int err;

		if (!inited)
			return destbuf;

		/* may be  zs.avail_out+<some constant>
		 * zs.avail_out is set nonzero by deflate in previous compress()
		 */
		//tmpbuf = new void[zs.avail_out];
		zs.next_out = tmpbuf.ptr;
		zs.avail_out = tmpbuf.length;

		while( (err = deflate(&zs, mode)) != Z_STREAM_END)
		{
			if (err == Z_OK)
			{
				if (zs.avail_out != 0 && mode != Z_FINISH)
					break;
				else if(zs.avail_out == 0)
				{
					destbuf ~= tmpbuf[];
					zs.next_out = tmpbuf.ptr;
					zs.avail_out = tmpbuf.length;
					continue;
				}
				err = Z_BUF_ERROR;
			}
			destbuf.deleteContents;
			error(err);
		}
		destbuf ~= tmpbuf[0 .. (tmpbuf.length - zs.avail_out)];

		if (mode == Z_FINISH)
		{
			err = deflateEnd(&zs);
			inited = 0;
			if (err)
				error(err);
		}
		return destbuf;
	}
}

/******
 * Used when the data to be decompressed is not all in one buffer.
 */

class UnCompress
{
  private:
	z_stream zs;
	int inited;
	int done;
	size_t destbufsize;
	Data zs_in;

	void error(int err)
	{
		if (inited)
		{   inflateEnd(&zs);
			inited = 0;
		}
		throw new ZlibException(err);
	}

  public:

	/**
	 * Construct. destbufsize is the same as for D.zlib.uncompress().
	 */
	this(size_t destbufsize)
	{
		this.destbufsize = destbufsize;
	}

	/** ditto */
	this()
	{
	}

	~this()
	{   int err;

		if (inited)
		{
			inited = 0;
			err = inflateEnd(&zs);
			if (err)
				error(err);
		}
		done = 1;
	}

	/**
	 * Decompress the data in buf and return the decompressed data.
	 * The buffers returned from successive calls to this should be concatenated
	 * together.
	 */
	Data uncompress(Data buf)
	in
	{
		assert(!done);
	}
	body
	{   int err;
		Data destbuf;

		if (buf.length == 0)
			return destbuf;

		if (!inited)
		{
			err = inflateInit(&zs);
			if (err)
				error(err);
			inited = 1;
		}

		if (!destbufsize)
			destbufsize = buf.length * 2;
		destbuf = Data(zs.avail_in * 2 + destbufsize);
		zs.next_out = cast(ubyte*) destbuf.ptr;
		zs.avail_out = to!int(destbuf.length);

		if (zs.avail_in)
			buf = zs.next_in[0 .. zs.avail_in] ~ buf;

		zs.next_in = cast(ubyte*) buf.ptr;
		zs.avail_in = to!int(buf.length);
		zs_in = buf; // hold reference

		err = inflate(&zs, Z_NO_FLUSH);
		if (err != Z_STREAM_END && err != Z_OK)
		{   destbuf.deleteContents;
			error(err);
		}
		destbuf.length = destbuf.length - zs.avail_out;
		return destbuf;
	}

	/**
	 * Decompress and return any remaining data.
	 * The returned data should be appended to that returned by uncompress().
	 * The UnCompress object cannot be used further.
	 */
	Data flush()
	in
	{
		assert(!done);
	}
	out
	{
		assert(done);
	}
	body
	{
		Data extra, destbuf;
		int err;

		done = 1;
		if (!inited)
			return destbuf;

	  L1:
		destbuf = Data(zs.avail_in * 2 + 100);
		zs.next_out = cast(ubyte*) destbuf.ptr;
		zs.avail_out = to!int(destbuf.length);

		err = etc.c.zlib.inflate(&zs, Z_NO_FLUSH);
		if (err == Z_OK && zs.avail_out == 0)
		{
			extra ~= destbuf;
			goto L1;
		}
		if (err != Z_STREAM_END)
		{
			destbuf.deleteContents;
			if (err == Z_OK)
				err = Z_BUF_ERROR;
			error(err);
		}
		destbuf = destbuf[0 .. zs.next_out - cast(ubyte*) destbuf.ptr];
		err = etc.c.zlib.inflateEnd(&zs);
		inited = 0;
		if (err)
			error(err);
		if (extra.length)
			destbuf = extra ~ destbuf;
		return destbuf;
	}
}

/* (unittests omitted) */

// VP 2009.10.09: adding streamed uncompressor which supports user-defined output buffer size
class StreamUnCompress
{
  private:
	z_stream zs;
	bool inited;
	Data input;

	void error(int err)
	{
		if (!inited) {
			inflateEnd(&zs);
			inited = false;
		}
		throw new ZlibException(err);
	}

  public:

	this(Data input)
	{
		this.input = input;

		int err = inflateInit(&zs);
		if (err)
			error(err);
		inited = true;

		zs.next_in = cast(ubyte*) input.ptr;
		zs.avail_in = to!int(input.length);
	}

	~this()
	{   if (inited)
		{
			int err = inflateEnd(&zs);
			if (err)
				throw new ZlibException(err);
		}
	}

	/// Decompresses the next part of input into the allocated buffer. output is adjusted to a slice of itself representing the actual amount of decompressed data.
	/// Returns true when all data has been processed.
	bool uncompress(Data output)
	in
	{
		assert(inited);
	}
	body
	{
		zs.next_out = cast(ubyte*) output.ptr;
		zs.avail_out = to!int(output.length);

		int err = inflate(&zs, Z_NO_FLUSH);
		if (err != Z_STREAM_END && err != Z_OK)
			error(err);

		output.length = output.length - zs.avail_out;

		if (err == Z_STREAM_END)
		{
			err = etc.c.zlib.inflateEnd(&zs);
			inited = 0;
			if (err)
				error(err);
			return true;
		}
		return false;
	}
}
