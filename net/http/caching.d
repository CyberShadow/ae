/**
 * Cached HTTP responses
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

module ae.net.http.caching;

import std.datetime;

import ae.net.http.common;
import ae.net.http.responseex;
import ae.sys.data;
import ae.utils.mime;
import ae.utils.time;
import ae.utils.zlib;
import ae.utils.gzip;

/// Controls which caching headers are sent to clients.
enum CachePolicy
{
	/// No caching headers are sent.
	/// Usually results in occasional If-Modified-Since / 304 Not Modified checks.
	unspecified,

	/// Data at this URL will never change.
	forever,

	/// Disable caching (use for frequently changing content).
	disable
}

/// Abstract class for caching resources in memory.
/// Stores compressed version as well.
class AbstractCachedResource
{
	/// Zlib compression level
	int compressionLevel = 1;

protected: // interface with descendant classes

	/// Get uncompressed data. The call may be expensive,
	/// result is cached (in uncompressedData).
	abstract Data[] getData();

	/// Return last modified time.
	/// Used for Last-Modified and If-Modified-Since headers.
	/// Called when cached data is invalidated; return value is cached.
	/// Returns current (invalidation) time by default.
	SysTime getLastModified()
	{
		return Clock.currTime(UTC());
	}

	// TODO: ETag?

	/// Caching policy. To be set during subclass construction.
	CachePolicy cachePolicy = CachePolicy.unspecified;

	/// MIME content type. To be set during subclass construction.
	string contentType;

	/// Called every time a request is done.
	/// Can be used to check if cached data expired, and invalidate() it.
	/// By default is a no-op.
	void newRequest() {}

	/// Clear cached uncompressed and compressed data.
	/// An alternative to calling invalidate() from a subclass is to
	/// simply create a new class instance when data becomes stale
	/// (overhead is negligible).
	final void invalidate()
	{
		uncompressedDataCache = deflateDataCache = gzipDataCache = null;
		lastModified = getLastModified();
	}

	this()
	{
		invalidate();
	}

private:
	Data[] uncompressedDataCache, deflateDataCache, gzipDataCache;
	SysTime lastModified;

	@property final Data[] uncompressedData()
	{
		if (!uncompressedDataCache)
			uncompressedDataCache = getData();
		return uncompressedDataCache;
	}

	@property final Data[] deflateData()
	{
		if (!deflateDataCache)
			deflateDataCache = ae.utils.zlib.compress(uncompressedData, zlib.ZlibOptions(compressionLevel));
		return deflateDataCache;
	}

	@property final Data[] gzipData()
	{
		// deflate2gzip doesn't actually make a copy of the compressed data (thanks to Data[]).
		if (!gzipDataCache)
			gzipDataCache = deflate2gzip(deflateData, crc32(uncompressedData), uncompressedData.bytes.length);
		return gzipDataCache;
	}

	// Use one response object per HTTP request (as opposed to one response
	// object per cached resource) to avoid problems with simultaneous HTTP
	// requests to the same resource (server calls .optimizeData() which
	// mutates the response object).
	final class Response : HttpResponse
	{
	protected:
		override void compressWithDeflate()
		{
			assert(data is uncompressedData);
			data = deflateData;
		}

		override void compressWithGzip()
		{
			assert(data is uncompressedData);
			data = gzipData;
		}
	}

public:
	/// Used by application code.
	final HttpResponse getResponse(HttpRequest request)
	{
		newRequest();
		auto response = new Response();

		if ("If-Modified-Since" in request.headers)
		{
			auto clientTime = request.headers["If-Modified-Since"].parseTime!(TimeFormats.RFC2822)();
			auto serverTime = httpTime(lastModified)              .parseTime!(TimeFormats.RFC2822)(); // make sure to avoid any issues of fractional seconds, etc.
			if (serverTime <= clientTime)
			{
				response.setStatus(HttpStatusCode.NotModified);
				return response;
			}
		}

		response.setStatus(HttpStatusCode.OK);
		response.data = uncompressedData;
		final switch (cachePolicy)
		{
			case CachePolicy.unspecified:
				break;
			case CachePolicy.forever:
				cacheForever(response.headers);
				break;
			case CachePolicy.disable:
				disableCache(response.headers);
				break;
		}

		if (contentType)
			response.headers["Content-Type"] = contentType;

		response.headers["Last-Modified"] = httpTime(lastModified);

		return response;
	}
}

/// A cached static file on disk (e.g. style, script, image).
// TODO: cachePolicy = forever when integrated with URL generation
class StaticResource : AbstractCachedResource
{
private:
	import std.file;

	string filename;
	SysTime fileTime, lastChecked;

	/// Don't check if the file on disk was modified more often than this interval.
	enum STAT_TIMEOUT = dur!"seconds"(1);

protected:
	override Data[] getData()
	{
		if (!exists(filename) || !isFile(filename)) // TODO: 404
			throw new Exception("Static resource does not exist on disk");

		// maybe use mmap?
		// mmap implies either file locking, or risk of bad data (file content changes, mapped length not)

		import ae.sys.dataio;
		return [readData(filename)];
	}

	override SysTime getLastModified()
	{
		return fileTime;
	}

	override void newRequest()
	{
		auto now = Clock.currTime();
		if ((now - lastChecked) > STAT_TIMEOUT)
		{
			lastChecked = now;

			auto newFileTime = timeLastModified(filename);
			if (newFileTime != fileTime)
			{
				fileTime = newFileTime;
				invalidate();
			}
		}
	}

public:
	this(string filename)
	{
		this.filename = filename;
		contentType = guessMime(filename);
	}
}

/// A generic cached resource, for resources that change
/// less often than they are requested (e.g. RSS feeds).
class CachedResource : AbstractCachedResource
{
private:
	Data[] data;

protected:
	override Data[] getData()
	{
		return data;
	}

public:
	this(Data[] data, string contentType)
	{
		this.data = data;
		this.contentType = contentType;
	}

	void setData(Data[] data)
	{
		this.data = data;
		invalidate();
	}
}
