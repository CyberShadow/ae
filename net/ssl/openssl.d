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
import ae.net.ssl;
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
	OpenSSL_add_all_algorithms();
}

// ***************************************************************************

class OpenSSLProvider : SSLProvider
{
	override SSLContext createContext(SSLContext.Kind kind)
	{
		return new OpenSSLContext(kind);
	}

	override SSLAdapter createAdapter(SSLContext context, IConnection next)
	{
		auto ctx = cast(OpenSSLContext)context;
		assert(ctx, "Not an OpenSSLContext");
		return new OpenSSLAdapter(ctx, next);
	}
}

class OpenSSLContext : SSLContext
{
	SSL_CTX* sslCtx;
	Kind kind;

	this(Kind kind)
	{
		this.kind = kind;

		const(SSL_METHOD)* method;

		final switch (kind)
		{
			case Kind.client:
				method = SSLv23_client_method().sslEnforce();
				break;
			case Kind.server:
				method = SSLv23_server_method().sslEnforce();
				break;
		}
		sslCtx = SSL_CTX_new(method).sslEnforce();
	}

	override void setCipherList(string[] ciphers)
	{
		SSL_CTX_set_cipher_list(sslCtx, ciphers.join(":").toStringz()).sslEnforce();
	}

	override void setCertificate(string path)
	{
		SSL_CTX_use_certificate_chain_file(sslCtx, toStringz(path))
			.sslEnforce("Failed to load certificate file " ~ path);
	}

	override void setPrivateKey(string path)
	{
		SSL_CTX_use_PrivateKey_file(sslCtx, toStringz(path), SSL_FILETYPE_PEM)
			.sslEnforce("Failed to load private key file " ~ path);
	}
}

static this()
{
	ssl = new OpenSSLProvider();
}

// ***************************************************************************

class OpenSSLAdapter : SSLAdapter
{
	SSL* sslHandle;

	this(OpenSSLContext context, IConnection next)
	{
		super(next);

		sslHandle = sslEnforce(SSL_new(context.sslCtx));
		SSL_set_bio(sslHandle, r.bio, w.bio);

		final switch (context.kind)
		{
			case OpenSSLContext.Kind.client: SSL_connect(sslHandle).sslEnforce(); break;
			case OpenSSLContext.Kind.server: SSL_accept (sslHandle).sslEnforce(); break;
		}
	}

	MemoryBIO r, w;

	override void onReadData(Data data)
	{
		assert(r.data.length == 0, "Would clobber data");
		r.set(data.contents);

		try
		{
			if (queue.length)
				flushQueue();

			while (r.data.length)
			{
				static ubyte[4096] buf;
				auto result = SSL_read(sslHandle, buf.ptr, buf.length);
				flushWritten();
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
		catch (Exception e)
		{
			debug(OPENSSL) stderr.writeln("Error while processing incoming data: " ~ e.msg);
			disconnect(e.msg, DisconnectType.error);
		}
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

// ***************************************************************************

/// TODO: replace with custom BIO which hooks into IConnection
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

T sslEnforce(T)(T v, string message = null)
{
	if (v)
		return v;

	{
		MemoryBIO m;
		ERR_print_errors(m.bio);
		string msg = (cast(char[])m.data).idup;

		if (message)
			msg = message ~ ": " ~ msg;

		throw new Exception(msg);
	}
}

// ***************************************************************************

unittest
{
	void testServer(string host, ushort port)
	{
		auto c = new TcpConnection;
		auto ctx = ssl.createContext(SSLContext.Kind.client);
		auto s = ssl.createAdapter(ctx, c);

		c.handleConnect =
		{
			debug(OPENSSL) stderr.writeln("Connected!");
			s.send(Data("GET / HTTP/1.0\r\n\r\n"));
		};
		s.handleReadData = (Data data)
		{
			debug(OPENSSL) { stderr.write(cast(string)data.contents); stderr.flush(); }
		};
		c.connect(host, port);
		socketManager.loop();
	}

	testServer("www.openssl.org", 443);
}
