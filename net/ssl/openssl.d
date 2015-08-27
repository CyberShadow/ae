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
import ae.utils.meta : enumLength;
import ae.utils.text;

import std.conv : to;
import std.exception : enforce;
import std.functional;
import std.socket;
import std.string;

//import deimos.openssl.rand;
import deimos.openssl.ssl;
import deimos.openssl.err;

version(Win64)
{
	pragma(lib, "ssleay32");
	pragma(lib, "libeay32");
}
else
{
	pragma(lib, "ssl");
	version(Windows)
		{ pragma(lib, "eay"); }
	else
		{ pragma(lib, "crypto"); }
}

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

	override void enableDH(int bits)
	{
		typeof(&get_rfc3526_prime_2048) func;

		switch (bits)
		{
			case 1536: func = &get_rfc3526_prime_1536; break;
			case 2048: func = &get_rfc3526_prime_2048; break;
			case 3072: func = &get_rfc3526_prime_3072; break;
			case 4096: func = &get_rfc3526_prime_4096; break;
			case 6144: func = &get_rfc3526_prime_6144; break;
			case 8192: func = &get_rfc3526_prime_8192; break;
			default: assert(false, "No RFC3526 prime available for %d bits".format(bits));
		}

		DH* dh;
		scope(exit) DH_free(dh);

		dh = DH_new().sslEnforce();
		dh.p = func(null).sslEnforce();
		ubyte gen = 2;
		dh.g = BN_bin2bn(&gen, gen.sizeof, null);
		SSL_CTX_set_tmp_dh(sslCtx, dh).sslEnforce();
	}

	override void enableECDH()
	{
		auto ecdh = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1).sslEnforce();
		scope(exit) EC_KEY_free(ecdh);
		SSL_CTX_set_tmp_ecdh(sslCtx, ecdh).sslEnforce();
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

	override void setPeerVerify(Verify verify)
	{
		static const int[enumLength!Verify] modes =
		[
			SSL_VERIFY_NONE,
			SSL_VERIFY_PEER,
			SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
		];
		SSL_CTX_set_verify(sslCtx, modes[verify], null);
	}

	override void setPeerRootCertificate(string path)
	{
		auto szPath = toStringz(path);
		SSL_CTX_load_verify_locations(sslCtx, szPath, null).sslEnforce();

		if (kind == Kind.server)
		{
			auto list = SSL_load_client_CA_file(szPath).sslEnforce();
			SSL_CTX_set_client_CA_list(sslCtx, list);
		}
	}

	override void setFlags(int flags)
	{
		SSL_CTX_set_options(sslCtx, flags).sslEnforce();
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
	OpenSSLContext context;

	this(OpenSSLContext context, IConnection next)
	{
		this.context = context;
		super(next);

		sslHandle = sslEnforce(SSL_new(context.sslCtx));
		SSL_set_bio(sslHandle, r.bio, w.bio);
	}

	override void onConnect()
	{
		final switch (context.kind)
		{
			case OpenSSLContext.Kind.client: SSL_connect(sslHandle).sslEnforce(); break;
			case OpenSSLContext.Kind.server: SSL_accept (sslHandle).sslEnforce(); break;
		}

		super.onConnect();
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

	override void disconnect(string reason, DisconnectType type)
	{
		SSL_shutdown(sslHandle);
		flushWritten();
		super.disconnect(reason, type);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		SSL_shutdown(sslHandle);
		r.clear();
		w.clear();
		super.onDisconnect(reason, type);
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

	override OpenSSLCertificate getHostCertificate()
	{
		return new OpenSSLCertificate(SSL_get_certificate(sslHandle).sslEnforce());
	}

	override OpenSSLCertificate getPeerCertificate()
	{
		return new OpenSSLCertificate(SSL_get_peer_certificate(sslHandle).sslEnforce());
	}
}

class OpenSSLCertificate : SSLCertificate
{
	X509* x509;

	this(X509* x509)
	{
		this.x509 = x509;
	}

	override string getSubjectName()
	{
		char[256] buf;
		X509_NAME_oneline(X509_get_subject_name(x509), buf.ptr, buf.length);
		buf[$-1] = 0;
		return buf.ptr.to!string();
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
