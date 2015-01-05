/**
 * OpenSSL support.
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

module ae.net.ssl.openssl;

import ae.net.asockets;
import ae.net.ssl.ssl;
import ae.utils.text;

import std.conv : to;
import std.exception : enforce;
import std.functional;
import std.socket;
import std.string;

//import deimos.openssl.rand;
import deimos.openssl.ssl;
import deimos.openssl.err;

pragma(lib, "ssl");
version(Windows)
	{ pragma(lib, "eay"); }
else
	{ pragma(lib, "crypto"); }

debug(OPENSSL) import std.stdio : stderr;

// ***************************************************************************

shared static this()
{
	SSL_load_error_strings();
	SSL_library_init();
}

// ***************************************************************************

class SSLContext
{
	SSL_CTX* sslCtx;

	this()
	{
		sslCtx = sslEnforce(SSL_CTX_new(SSLv23_client_method()));
	}
}

SSLContext sslContext;
static this()
{
	sslContext = new SSLContext();
	sslAdapterFactory = toDelegate(&factory);
}

// ***************************************************************************

class OpenSSLAdapter : SSLAdapter
{
	SSL* sslHandle;

	this(IConnection next, SSLContext context = sslContext)
	{
		super(next);

		sslHandle = sslEnforce(SSL_new(context.sslCtx));
		SSL_set_connect_state(sslHandle);
		SSL_set_bio(sslHandle, r.bio, w.bio);
	}

	MemoryBIO r, w;

	override void onReadData(Data data)
	{
		assert(r.data.length == 0, "Would clobber data");
		r.set(data.contents);

		if (queue.length)
			flushQueue();

		while (r.data.length)
		{
			static ubyte[4096] buf;
			auto result = SSL_read(sslHandle, buf.ptr, buf.length);
			if (result > 0)
				super.onReadData(Data(buf[0..result]));
			else
			{
				sslError(result);
				break;
			}
		}
		enforce(r.data.length == 0, "SSL did not consume all read data");
	}

	void flushWritten()
	{
		if (w.data.length)
		{
			next.send([Data(w.data)]);
			w.clear();
		}
	}

	Data[] queue;

	override void send(Data[] data, int priority = DEFAULT_PRIORITY)
	{
		debug(OPENSSL) stderr.writeln("OpenSSLAdapter.send");
		if (data.length)
			queue ~= data;

		flushQueue();
	}

	alias send = super.send;

	void flushQueue()
	{
		while (queue.length)
		{
			auto result = SSL_write(sslHandle, queue[0].ptr, queue[0].length.to!int);
			if (result > 0)
			{
				queue[0] = queue[0][result..$];
				if (!queue[0].length)
					queue = queue[1..$];
			}
			else
			{
				sslError(result);
				break;
			}
		}
		flushWritten();
	}

	void sslError(int ret)
	{
		auto err = SSL_get_error(sslHandle, ret);
		switch (err)
		{
			case SSL_ERROR_WANT_READ:
			case SSL_ERROR_ZERO_RETURN:
				return;
			default:
				sslEnforce(false);
		}
	}
}

SSLAdapter factory(IConnection next) { return new OpenSSLAdapter(next); }

// ***************************************************************************

struct MemoryBIO
{
	@disable this(this);

	this(const(void)[] data)
	{
		bio_ = BIO_new_mem_buf(cast(void*)data.ptr, data.length.to!int);
	}

	void set(const(void)[] data)
	{
		BUF_MEM *bptr = BUF_MEM_new();
		if (data.length)
		{
			BUF_MEM_grow(bptr, data.length);
			bptr.data[0..bptr.length] = cast(char[])data;
		}
		BIO_set_mem_buf(bio, bptr, BIO_CLOSE);
	}

	void clear() { set(null); }

	@property BIO* bio()
	{
		if (!bio_)
		{
			bio_ = sslEnforce(BIO_new(BIO_s_mem()));
			BIO_set_close(bio_, BIO_CLOSE);
		}
		return bio_;
	}

	const(void)[] data()
	{
		BUF_MEM *bptr;
		BIO_get_mem_ptr(bio, &bptr);
		return bptr.data[0..bptr.length];
	}

private:
	BIO* bio_;
}

T sslEnforce(T)(T v)
{
	if (v)
		return v;

	{
		MemoryBIO m;
		ERR_print_errors(m.bio);
		string msg = (cast(char[])m.data).idup;

		throw new Exception(msg);
	}
}

// ***************************************************************************

unittest
{
	auto c = new TcpConnection;
	auto s = new OpenSSLAdapter(c);

	c.handleConnect =
	{
		debug(OPENSSL) stderr.writeln("Connected!");
		s.send(Data("GET / HTTP/1.0\r\n\r\n"));
	};
	s.handleReadData = (Data data)
	{
		debug(OPENSSL) { stderr.write(cast(string)data.contents); stderr.flush(); }
	};
	c.connect("www.openssl.org", 443);
	socketManager.loop();
}
