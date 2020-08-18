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

import core.stdc.stdint;

import std.conv : to;
import std.exception : enforce, errnoEnforce;
import std.functional;
import std.socket;
import std.string;

//import deimos.openssl.rand;
import deimos.openssl.ssl;
import deimos.openssl.err;
import deimos.openssl.x509_vfy;
import deimos.openssl.x509v3;

import ae.net.asockets;
import ae.net.ssl;
import ae.utils.exception : CaughtException;
import ae.utils.meta : enumLength;
import ae.utils.text;

mixin template SSLUseLib()
{
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
}

debug(OPENSSL) import std.stdio : stderr;

// ***************************************************************************

static if (is(typeof(OPENSSL_MAKE_VERSION)))
	private enum isOpenSSL11 = OPENSSL_VERSION_NUMBER >= OPENSSL_MAKE_VERSION(1, 1, 0, 0);
else
	private enum isOpenSSL11 = false;

// Patch up incomplete Deimos bindings.

static if (isOpenSSL11)
private
{
	alias SSLv23_client_method = TLS_client_method;
	alias SSLv23_server_method = TLS_server_method;
	void SSL_load_error_strings() {}
	struct OPENSSL_INIT_SETTINGS;
	extern(C) void OPENSSL_init_ssl(uint64_t opts, const OPENSSL_INIT_SETTINGS *settings) nothrow;
	void SSL_library_init() { OPENSSL_init_ssl(0, null); }
	void OpenSSL_add_all_algorithms() { SSL_library_init(); }
	extern(C) BIGNUM *BN_get_rfc3526_prime_1536(BIGNUM *bn) nothrow;
	alias get_rfc3526_prime_1536 = BN_get_rfc3526_prime_1536;
	extern(C) BIGNUM *BN_get_rfc3526_prime_2048(BIGNUM *bn) nothrow;
	alias get_rfc3526_prime_2048 = BN_get_rfc3526_prime_2048;
	extern(C) BIGNUM *BN_get_rfc3526_prime_3072(BIGNUM *bn) nothrow;
	alias get_rfc3526_prime_3072 = BN_get_rfc3526_prime_3072;
	extern(C) BIGNUM *BN_get_rfc3526_prime_4096(BIGNUM *bn) nothrow;
	alias get_rfc3526_prime_4096 = BN_get_rfc3526_prime_4096;
	extern(C) BIGNUM *BN_get_rfc3526_prime_6144(BIGNUM *bn) nothrow;
	alias get_rfc3526_prime_6144 = BN_get_rfc3526_prime_6144;
	extern(C) BIGNUM *BN_get_rfc3526_prime_8192(BIGNUM *bn) nothrow;
	alias get_rfc3526_prime_8192 = BN_get_rfc3526_prime_8192;
	extern(C) int SSL_in_init(const SSL *s) nothrow;
}

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
	Verify verify;

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

		SSL_CTX_set_default_verify_paths(sslCtx);
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
		this.verify = verify;
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
	ConnectionState connectionState;
	const(char)* hostname;

	this(OpenSSLContext context, IConnection next)
	{
		this.context = context;
		super(next);

		sslHandle = sslEnforce(SSL_new(context.sslCtx));
		SSL_set_bio(sslHandle, r.bio, w.bio);

		if (next.state == ConnectionState.connected)
			initialize();
	}

	override void onConnect()
	{
		initialize();
	}

	private final void initialize()
	{
		final switch (context.kind)
		{
			case OpenSSLContext.Kind.client: SSL_connect(sslHandle).sslEnforce(); break;
			case OpenSSLContext.Kind.server: SSL_accept (sslHandle).sslEnforce(); break;
		}
		connectionState = ConnectionState.connecting;
		updateState();

		if (context.verify && hostname && context.kind == OpenSSLContext.Kind.client)
		{
			SSL_set_hostflags(sslHandle, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
			SSL_set1_host(sslHandle, hostname).sslEnforce("SSL_set1_host");
		}
	}

	MemoryBIO r; // BIO for incoming ciphertext
	MemoryBIO w; // BIO for outgoing ciphertext

	override void onReadData(Data data)
	{
		debug(OPENSSL_DATA) stderr.writefln("OpenSSL: { Got %d incoming bytes from network", data.length);

		if (next.state == ConnectionState.disconnecting)
		{
			return;
		}

		assert(r.data.length == 0, "Would clobber data");
		r.set(data.contents);

		try
		{
			while (true)
			{
				static ubyte[4096] buf;
				debug(OPENSSL_DATA) auto oldLength = r.data.length;
				auto result = SSL_read(sslHandle, buf.ptr, buf.length);
				debug(OPENSSL_DATA) stderr.writefln("OpenSSL: < SSL_read ate %d bytes and spat out %d bytes", oldLength - r.data.length, result);
				if (result > 0)
				{
					updateState();
					super.onReadData(Data(buf[0..result]));
					// Stop if upstream decided to disconnect.
					if (next.state != ConnectionState.connected)
						return;
				}
				else
				{
					sslError(result, "SSL_read");
					updateState();
					break;
				}
			}
			enforce(r.data.length == 0, "SSL did not consume all read data");
		}
		catch (CaughtException e)
		{
			debug(OPENSSL) stderr.writeln("Error while %s and processing incoming data: %s".format(next.state, e.msg));
			if (next.state != ConnectionState.disconnecting && next.state != ConnectionState.disconnected)
				disconnect(e.msg, DisconnectType.error);
			else
				throw e;
		}
	}

	override void send(Data[] data, int priority = DEFAULT_PRIORITY)
	{
		while (data.length)
		{
			auto datum = data[0];
			data = data[1 .. $];
			if (!datum.length)
				continue;

			debug(OPENSSL_DATA) stderr.writefln("OpenSSL: > Got %d outgoing bytes from program", datum.length);

			debug(OPENSSL_DATA) auto oldLength = w.data.length;
			auto result = SSL_write(sslHandle, datum.ptr, datum.length.to!int);
			debug(OPENSSL_DATA) stderr.writefln("OpenSSL:   SSL_write ate %d bytes and spat out %d bytes", datum.length, w.data.length - oldLength);
			if (result > 0)
			{
				// "SSL_write() will only return with success, when the
				// complete contents of buf of length num has been written."
			}
			else
			{
				sslError(result, "SSL_write");
				break;
			}
		}
		updateState();
	}

	override @property ConnectionState state()
	{
		return connectionState;
	}

	final void updateState()
	{
		// Flush any accumulated outgoing ciphertext to the network
		if (w.data.length)
		{
			debug(OPENSSL_DATA) stderr.writefln("OpenSSL: } Flushing %d outgoing bytes from OpenSSL to network", w.data.length);
			next.send([Data(w.data)]);
			w.clear();
		}

		// Has the handshake been completed?
		if (connectionState == ConnectionState.connecting && SSL_is_init_finished(sslHandle))
		{
			connectionState = ConnectionState.connected;
			if (context.verify)
				try
					if (!SSL_get_peer_certificate(sslHandle))
						enforce(context.verify != SSLContext.Verify.require, "No SSL peer certificate was presented");
					else
					{
						auto result = SSL_get_verify_result(sslHandle);
						enforce(result == X509_V_OK,
							"SSL peer verification failed with error " ~ result.to!string);
					}
				catch (Exception e)
				{
					disconnect(e.msg, DisconnectType.error);
					return;
				}
			super.onConnect();
		}
	}

	override void disconnect(string reason, DisconnectType type)
	{
		debug(OPENSSL) stderr.writefln("OpenSSL: disconnect called ('%s')", reason);
		if (!SSL_in_init(sslHandle))
		{
			debug(OPENSSL) stderr.writefln("OpenSSL: Calling SSL_shutdown");
			SSL_shutdown(sslHandle);
			connectionState = ConnectionState.disconnecting;
			updateState();
		}
		else
			debug(OPENSSL) stderr.writefln("OpenSSL: In init, not calling SSL_shutdown");
		debug(OPENSSL) stderr.writefln("OpenSSL: SSL_shutdown done, flushing");
		debug(OPENSSL) stderr.writefln("OpenSSL: SSL_shutdown output flushed");
		super.disconnect(reason, type);
	}

	override void onDisconnect(string reason, DisconnectType type)
	{
		debug(OPENSSL) stderr.writefln("OpenSSL: onDisconnect ('%s'), calling SSL_free", reason);
		r.clear();
		w.clear();
		SSL_free(sslHandle);
		sslHandle = null;
		connectionState = ConnectionState.disconnected;
		debug(OPENSSL) stderr.writeln("OpenSSL: onDisconnect: SSL_free called, calling super.onDisconnect");
		super.onDisconnect(reason, type);
		debug(OPENSSL) stderr.writeln("OpenSSL: onDisconnect finished");
	}

	alias send = SSLAdapter.send;

	void sslError(int ret, string msg)
	{
		auto err = SSL_get_error(sslHandle, ret);
		debug(OPENSSL) stderr.writefln("OpenSSL: SSL error ('%s', ret %d): %s", msg, ret, err);
		switch (err)
		{
			case SSL_ERROR_WANT_READ:
			case SSL_ERROR_ZERO_RETURN:
				return;
			case SSL_ERROR_SYSCALL:
				errnoEnforce(false, msg ~ " failed");
				assert(false);
			default:
				sslEnforce(false, "%s failed - error code %s".format(msg, err));
		}
	}

	override void setHostName(string hostname, ushort port = 0, string service = null)
	{
		this.hostname = cast(char*)hostname.toStringz();
		SSL_set_tlsext_host_name(sslHandle, cast(char*)this.hostname);
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

version (unittest) import ae.net.ssl.test;
unittest { testSSL(new OpenSSLProvider); }
