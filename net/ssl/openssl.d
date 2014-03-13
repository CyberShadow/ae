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
	sslSocketFactory = toDelegate(&factory);
}

// ***************************************************************************

class CustomSSLSocket(Parent) : Parent
{
	SSL* sslHandle;

	this(SSLContext context = sslContext)
	{
		sslHandle = sslEnforce(SSL_new(context.sslCtx));
		SSL_set_connect_state(sslHandle);
		SSL_set_bio(sslHandle, r.bio, w.bio);
	}

	MemoryBIO r, w;

	ReadDataHandler userDataHandler;

	override void onReadable()
	{
		userDataHandler = handleReadData;
		handleReadData = &onReadData;
		scope(exit) handleReadData = userDataHandler;
		super.onReadable();
	}

	void callUserDataHandler(Data data)
	{
		assert(handleReadData is &onReadData);
		scope(exit)
			if (handleReadData !is &onReadData)
			{
				userDataHandler = handleReadData;
				handleReadData = &onReadData;
			}
		userDataHandler(this, data);
	}

	void onReadData(ClientSocket sender, Data data)
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
				callUserDataHandler(Data(buf[0..result]));
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
			super.send([Data(w.data)]);
			w.clear();
		}
	}

	Data[] queue;

	override void send(Data[] data, int priority = DEFAULT_PRIORITY)
	{
		if (data.length)
			queue ~= data;

		flushQueue();
	}

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

alias CustomSSLSocket!ClientSocket SSLSocket;

SSLSocket factory() { return new SSLSocket(); }

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

unittest
{
//	import std.stdio;
	ClientSocket s = new SSLSocket();

	s.handleConnect = (ClientSocket c)
	{
	//	writeln("Connected!");
		s.send(Data("GET / HTTP/1.0\r\n\r\n"));
	};
	s.handleReadData = (ClientSocket c, Data data)
	{
	//	write(cast(string)data.contents); stdout.flush();
	};
	s.connect("www.openssl.org", 443);
	socketManager.loop();
}
