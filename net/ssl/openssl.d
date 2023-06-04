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
 *   Vladimir Panteleev <ae@cy.md>
 */

/**
   This module selects which OpenSSL version to target depending on
   what version of D bindings are available. The "openssl" Deimos
   package version 1.x targets OpenSSL 1.0, and version 2.x targets
   OpenSSL 1.1.

   If you use ae with Dub, you can specify the version of the OpenSSL
   D bindings in your project's dub.sdl. The ae:openssl subpackage
   also has configurations which indicate the library file names to
   link against.

   Thus, to target OpenSSL 1.0, you can use:

   ---
   dependency "ae:openssl" version="..."
   dependency "openssl" version="~>1.0"
   subConfiguration "ae:openssl" "lib-explicit-1.0"
   ---

   And, to target OpenSSL 1.1:

   ---
   dependency "ae:openssl" version="..."
   dependency "openssl" version="~>2.0"
   subConfiguration "ae:openssl" "lib-implicit-1.1"
   ---
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

debug(OPENSSL) import std.stdio : stderr;
debug(OPENSSL_DATA) import std.stdio : stderr;

// ***************************************************************************

/// Are the current Deimos OpenSSL bindings 1.1 or newer?
static if (is(typeof(OPENSSL_MAKE_VERSION)))
	enum isOpenSSL11 = OPENSSL_VERSION_NUMBER >= OPENSSL_MAKE_VERSION(1, 1, 0, 0);
else
	enum isOpenSSL11 = false;

/// `mixin` this in your program to link to OpenSSL.
mixin template SSLUseLib()
{
	static if (ae.net.ssl.openssl.isOpenSSL11)
	{
		pragma(lib, "ssl");
		pragma(lib, "crypto");
	}
	else
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
}

// Patch up incomplete Deimos bindings.

private
{
	enum TLS1_3_VERSION = 0x0304;
	enum SSL_CTRL_SET_MIN_PROTO_VERSION          = 123;
	enum SSL_CTRL_SET_MAX_PROTO_VERSION          = 124;
	long SSL_CTX_set_min_proto_version(SSL_CTX* ctx, int version_) { return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MIN_PROTO_VERSION, version_, null); }
	long SSL_CTX_set_max_proto_version(SSL_CTX* ctx, int version_) { return SSL_CTX_ctrl(ctx, SSL_CTRL_SET_MAX_PROTO_VERSION, version_, null); }

	static if (isOpenSSL11)
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
		extern(C) int SSL_CTX_set_ciphersuites(SSL_CTX* ctx, const(char)* str);
	}
	else
	{
		extern(C) void X509_VERIFY_PARAM_set_hostflags(X509_VERIFY_PARAM *param, uint flags) nothrow;
		extern(C) X509_VERIFY_PARAM *SSL_get0_param(SSL *ssl) nothrow;
		enum X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS = 0x4;
		extern(C) int X509_VERIFY_PARAM_set1_host(X509_VERIFY_PARAM *param, const char *name, size_t namelen) nothrow;
	}
}

// ***************************************************************************

shared static this()
{
	SSL_load_error_strings();
	SSL_library_init();
	OpenSSL_add_all_algorithms();
}

// ***************************************************************************

/// `SSLProvider` implementation.
class OpenSSLProvider : SSLProvider
{
	override SSLContext createContext(SSLContext.Kind kind)
	{
		return new OpenSSLContext(kind);
	} ///

	override SSLAdapter createAdapter(SSLContext context, IConnection next)
	{
		auto ctx = cast(OpenSSLContext)context;
		assert(ctx, "Not an OpenSSLContext");
		return new OpenSSLAdapter(ctx, next);
	} ///
}

/// `SSLContext` implementation.
class OpenSSLContext : SSLContext
{
	SSL_CTX* sslCtx; /// The C OpenSSL context object.
	Kind kind; /// Client or server.
	Verify verify; ///

	const(ubyte)[] psk; /// PSK (Pre-Shared Key) configuration.
	string pskID; /// ditto

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
		setCipherList(["ALL", "!MEDIUM", "!LOW", "!aNULL", "!eNULL", "!SSLv2", "!DH", "!TLSv1"]);

		SSL_CTX_set_default_verify_paths(sslCtx);
	} ///

	/// OpenSSL uses different APIs to specify the cipher list for
	/// TLSv1.2 and below and to specify the ciphersuites for TLSv1.3.
	/// When calling `setCipherList`, use this value to delimit them:
	/// values before `cipherListTLS13Delimiter` will be specified via
	/// SSL_CTX_set_cipher_list (for TLSv1.2 and older), and those
	/// after `cipherListTLS13Delimiter` will be specified via
	/// `SSL_CTX_set_ciphersuites` (for TLSv1.3).
	static immutable cipherListTLS13Delimiter = "\0ae-net-ssl-openssl-cipher-list-tls-1.3-delimiter";

	override void setCipherList(string[] ciphers)
	{
		assert(ciphers.length, "Empty cipher list");
		import std.algorithm.searching : findSplit;
		auto parts = ciphers.findSplit((&cipherListTLS13Delimiter)[0..1]);
		auto oldCiphers = parts[0];
		auto newCiphers = parts[2];
		if (oldCiphers.length)
			SSL_CTX_set_cipher_list(sslCtx, oldCiphers.join(":").toStringz()).sslEnforce();
		if (newCiphers.length)
		{
			static if (isOpenSSL11)
				SSL_CTX_set_ciphersuites(sslCtx, newCiphers.join(":").toStringz()).sslEnforce();
			else
				assert(false, "Not built against OpenSSL version with TLSv1.3 support.");
		}
	} /// `SSLContext` method implementation.

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
	} /// ditto

	override void enableECDH()
	{
		auto ecdh = EC_KEY_new_by_curve_name(NID_X9_62_prime256v1).sslEnforce();
		scope(exit) EC_KEY_free(ecdh);
		SSL_CTX_set_tmp_ecdh(sslCtx, ecdh).sslEnforce();
	} /// ditto

	override void setCertificate(string path)
	{
		SSL_CTX_use_certificate_chain_file(sslCtx, toStringz(path))
			.sslEnforce("Failed to load certificate file " ~ path);
	} /// ditto

	override void setPrivateKey(string path)
	{
		SSL_CTX_use_PrivateKey_file(sslCtx, toStringz(path), SSL_FILETYPE_PEM)
			.sslEnforce("Failed to load private key file " ~ path);
	} /// ditto

	override void setPreSharedKey(string id, const(ubyte)[] key)
	{
		pskID = id;
		psk = key;

		final switch (kind)
		{
			case Kind.client: SSL_CTX_set_psk_client_callback(sslCtx, psk ? &pskClientCallback : null); break;
			case Kind.server: SSL_CTX_set_psk_server_callback(sslCtx, psk ? &pskServerCallback : null); break;
		}
	} /// ditto

	extern (C) private static uint pskClientCallback(
		SSL* ssl, const(char)* hint,
		char* identity, uint max_identity_len, ubyte* psk,
		uint max_psk_len)
	{
		debug(OPENSSL) stderr.writeln("pskClientCallback! hint=", hint);

		auto self = cast(OpenSSLAdapter)SSL_get_ex_data(ssl, 0);
		if (self.context.pskID.length + 1 > max_identity_len ||
			self.context.psk.length       > max_psk_len)
		{
			debug(OPENSSL) stderr.writeln("PSK or PSK ID too long");
			return 0;
		}

		identity[0 .. self.context.pskID.length] = self.context.pskID[];
		identity[     self.context.pskID.length] = 0;
		psk[0 .. self.context.psk.length] = self.context.psk[];
		return cast(uint)self.context.psk.length;
	}

	extern (C) private static uint pskServerCallback(
		SSL* ssl, const(char)* identity,
		ubyte* psk, uint max_psk_len)
	{
		auto self = cast(OpenSSLAdapter)SSL_get_ex_data(ssl, 0);
		auto identityStr = fromStringz(identity);
		if (identityStr != self.context.pskID)
		{
			debug(OPENSSL) stderr.writefln("PSK ID mismatch: expected %s, got %s",
				self.context.pskID, identityStr);
			return 0;
		}
		if (self.context.psk.length > max_psk_len)
		{
			debug(OPENSSL) stderr.writeln("PSK too long");
			return 0;
		}
		psk[0 .. self.context.psk.length] = self.context.psk[];
		return cast(uint)self.context.psk.length;
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
	} /// ditto

	override void setPeerRootCertificate(string path)
	{
		auto szPath = toStringz(path);
		SSL_CTX_load_verify_locations(sslCtx, szPath, null).sslEnforce();

		if (kind == Kind.server)
		{
			auto list = SSL_load_client_CA_file(szPath).sslEnforce();
			SSL_CTX_set_client_CA_list(sslCtx, list);
		}
	} /// ditto

	override void setFlags(int flags)
	{
		SSL_CTX_set_options(sslCtx, flags).sslEnforce();
	} /// ditto

	private static immutable int[enumLength!SSLVersion] sslVersions = [
		0,
		SSL3_VERSION,
		TLS1_VERSION,
		TLS1_1_VERSION,
		TLS1_2_VERSION,
		TLS1_3_VERSION,
	];

	override void setMinimumVersion(SSLVersion v)
	{
		SSL_CTX_set_min_proto_version(sslCtx, sslVersions[v]).sslEnforce();
	} /// ditto

	override void setMaximumVersion(SSLVersion v)
	{
		SSL_CTX_set_max_proto_version(sslCtx, sslVersions[v]).sslEnforce();
	} /// ditto
}

static this()
{
	ssl = new OpenSSLProvider();
}

// ***************************************************************************

/// `SSLAdapter` implementation.
class OpenSSLAdapter : SSLAdapter
{
	SSL* sslHandle; /// The C OpenSSL connection object.
	OpenSSLContext context; ///
	ConnectionState connectionState; ///
	const(char)* hostname; ///

	this(OpenSSLContext context, IConnection next)
	{
		this.context = context;
		super(next);

		sslHandle = sslEnforce(SSL_new(context.sslCtx));
		SSL_set_ex_data(sslHandle, 0, cast(void*)this).sslEnforce();
		SSL_set_bio(sslHandle, r.bio, w.bio);

		if (next.state == ConnectionState.connected)
			initialize();
	} ///

	override void onConnect()
	{
		debug(OPENSSL) stderr.writefln("OpenSSL: * Transport is connected");
		initialize();
	} /// `SSLAdapter` method implementation.

	override void onReadData(Data data)
	{
		debug(OPENSSL_DATA) stderr.writefln("OpenSSL: { Got %d incoming bytes from network", data.length);

		if (next.state == ConnectionState.disconnecting)
		{
			return;
		}

		assert(r.data.length == 0, "Would clobber data");
		data.enter((contents) { r.set(contents); });

		try
		{
			// We must buffer all cleartext data and send it off in a
			// single `super.onReadData` call. It cannot be split up
			// into multiple calls, because the `readDataHandler` may
			// be set to null in the middle of our loop.
			Data clearText;

			while (true)
			{
				static ubyte[4096] buf;
				debug(OPENSSL_DATA) auto oldLength = r.data.length;
				auto result = SSL_read(sslHandle, buf.ptr, buf.length);
				debug(OPENSSL_DATA) stderr.writefln("OpenSSL: < SSL_read ate %d bytes and spat out %d bytes", oldLength - r.data.length, result);
				if (result > 0)
				{
					updateState();
					clearText ~= buf[0..result];
				}
				else
				{
					sslError(result, "SSL_read");
					updateState();
					break;
				}
			}
			enforce(r.data.length == 0, "SSL did not consume all read data");
			if (clearText.length)
				super.onReadData(clearText);
		}
		catch (CaughtException e)
		{
			debug(OPENSSL) stderr.writeln("Error while %s and processing incoming data: %s".format(next.state, e.msg));
			if (next.state != ConnectionState.disconnecting && next.state != ConnectionState.disconnected)
				disconnect(e.msg, DisconnectType.error);
			else
				throw e;
		}
	} /// `SSLAdapter` method implementation.

	override void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		assert(state == ConnectionState.connected, "Attempting to send to a non-connected socket");
		while (data.length)
		{
			auto datum = data[0];
			data = data[1 .. $];
			if (!datum.length)
				continue;

			debug(OPENSSL_DATA) stderr.writefln("OpenSSL: > Got %d outgoing bytes from program", datum.length);

			debug(OPENSSL_DATA) auto oldLength = w.data.length;
			int result;
			datum.enter((contents) {
				result = SSL_write(sslHandle, contents.ptr, contents.length.to!int);
			});
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
	} /// ditto

	override @property ConnectionState state()
	{
		if (next.state == ConnectionState.connecting)
			return next.state;
		return connectionState;
	} /// ditto

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
	} /// ditto

	override void onDisconnect(string reason, DisconnectType type)
	{
		debug(OPENSSL) stderr.writefln("OpenSSL: onDisconnect ('%s'), calling SSL_free", reason);
		r.clear();
		w.clear();
		SSL_free(sslHandle);
		sslHandle = null;
		r = MemoryBIO.init; // Was owned by sslHandle, destroyed by SSL_free
		w = MemoryBIO.init; // ditto
		connectionState = ConnectionState.disconnected;
		debug(OPENSSL) stderr.writeln("OpenSSL: onDisconnect: SSL_free called, calling super.onDisconnect");
		super.onDisconnect(reason, type);
		debug(OPENSSL) stderr.writeln("OpenSSL: onDisconnect finished");
	} /// ditto

	override void setHostName(string hostname, ushort port = 0, string service = null)
	{
		this.hostname = cast(char*)hostname.toStringz();
		SSL_set_tlsext_host_name(sslHandle, cast(char*)this.hostname);
	} /// ditto

	override OpenSSLCertificate getHostCertificate()
	{
		return new OpenSSLCertificate(SSL_get_certificate(sslHandle).sslEnforce());
	} /// ditto

	override OpenSSLCertificate getPeerCertificate()
	{
		return new OpenSSLCertificate(SSL_get_peer_certificate(sslHandle).sslEnforce());
	} /// ditto

protected:
	MemoryBIO r; // BIO for incoming ciphertext
	MemoryBIO w; // BIO for outgoing ciphertext

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
			static if (!isOpenSSL11)
			{
				import core.stdc.string : strlen;
				X509_VERIFY_PARAM* param = SSL_get0_param(sslHandle);
				X509_VERIFY_PARAM_set_hostflags(param, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
				X509_VERIFY_PARAM_set1_host(param, hostname, strlen(hostname)).sslEnforce("X509_VERIFY_PARAM_set1_host");
			}
			else
			{
				SSL_set_hostflags(sslHandle, X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS);
				SSL_set1_host(sslHandle, hostname).sslEnforce("SSL_set1_host");
			}
		}
	}

	protected final void updateState()
	{
		// Flush any accumulated outgoing ciphertext to the network
		if (w.data.length)
		{
			debug(OPENSSL_DATA) stderr.writefln("OpenSSL: } Flushing %d outgoing bytes from OpenSSL to network", w.data.length);
			next.send(Data(w.data));
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
}

/// `SSLCertificate` implementation.
class OpenSSLCertificate : SSLCertificate
{
	X509* x509; /// The C OpenSSL certificate object.

	this(X509* x509)
	{
		this.x509 = x509;
	} ///

	override string getSubjectName()
	{
		char[256] buf;
		X509_NAME_oneline(X509_get_subject_name(x509), buf.ptr, buf.length);
		buf[$-1] = 0;
		return buf.ptr.to!string();
	} /// `SSLCertificate` method implementation.
}

// ***************************************************************************

/// TODO: replace with custom BIO which hooks into IConnection
struct MemoryBIO
{
	@disable this(this);

	this(const(void)[] data)
	{
		bio_ = BIO_new_mem_buf(cast(void*)data.ptr, data.length.to!int);
	} ///

	void set(scope const(void)[] data)
	{
		BUF_MEM *bptr = BUF_MEM_new();
		if (data.length)
		{
			BUF_MEM_grow(bptr, data.length);
			bptr.data[0..bptr.length] = cast(char[])data;
		}
		BIO_set_mem_buf(bio, bptr, BIO_CLOSE);
	} ///

	void clear() { set(null); } ///

	@property BIO* bio()
	{
		if (!bio_)
		{
			bio_ = sslEnforce(BIO_new(BIO_s_mem()));
			BIO_set_close(bio_, BIO_CLOSE);
		}
		return bio_;
	} ///

	const(void)[] data()
	{
		BUF_MEM *bptr;
		BIO_get_mem_ptr(bio, &bptr);
		return bptr.data[0..bptr.length];
	} ///

private:
	BIO* bio_;
}

/// Convert an OpenSSL error into a thrown D exception.
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
