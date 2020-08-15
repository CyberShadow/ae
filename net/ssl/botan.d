/**
 * Botan-powered SSL.
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

module ae.net.ssl.botan;

import botan.math.bigint.bigint;
import botan.rng.auto_rng;
import botan.tls.client;
import botan.tls.server;

import ae.net.asockets;
import ae.net.ssl;

debug = BotanSSL;
debug(BotanSSL) import std.stdio : stderr;

class BotanSSLProvider : SSLProvider
{
	override SSLContext createContext(SSLContext.Kind kind)
	{
		return new BotanSSLContext(kind);
	}

	override SSLAdapter createAdapter(SSLContext context, IConnection next)
	{
		auto ctx = cast(BotanSSLContext)context;
		assert(ctx, "Not a BotanSSLContext");
		return new BotanSSLAdapter(ctx, next);
	}
}

class DefaultTLSCredentialsManager : TLSCredentialsManager
{
	override Vector!CertificateStore trustedCertificateAuthorities(in string type, in string context)
	{
		return super.trustedCertificateAuthorities(type, context);
	}

	override void verifyCertificateChain(in string type, in string purported_hostname, const ref Vector!X509Certificate cert_chain)
	{
		return super.verifyCertificateChain(type, purported_hostname, cert_chain);
	}

	override Vector!X509Certificate certChain(const ref Vector!string cert_key_types, in string type, in string context)
	{
		return super.certChain(cert_key_types, type, context);
	}

	override Vector!X509Certificate certChainSingleType(in string cert_key_type, in string type, in string context)
	{
		return super.certChainSingleType(cert_key_type, type, context);
	}

	override PrivateKey privateKeyFor(in X509Certificate cert, in string type, in string context)
	{
		return super.privateKeyFor(cert, type, context);
	}

	override bool attemptSrp(in string type, in string context)
	{
		return super.attemptSrp(type, context);
	}

	override string srpIdentifier(in string type, in string context)
	{
		return super.srpIdentifier(type, context);
	}

	override string srpPassword(in string type,
								 in string context,
								 in string identifier)
	{
		return super.srpPassword(type, context, identifier);
	}

	override bool srpVerifier(in string type,
							  in string context,
							  in string identifier,
							  ref string group_name,
							  ref BigInt verifier,
							  ref Vector!ubyte salt,
							  bool generate_fake_on_unknown)
	{
		return super.srpVerifier(type, context, identifier, group_name, verifier, salt, generate_fake_on_unknown);
	}

	override string pskIdentityHint(in string type, in string context)
	{
		return super.pskIdentityHint(type, context);
	}

	override string pskIdentity(in string type, in string context, in string identity_hint)
	{
		return super.pskIdentity(type, context, identity_hint);
	}

	override bool hasPsk()
	{
		return super.hasPsk();
	}

	override SymmetricKey psk(in string type, in string context, in string identity)
	{
		return super.psk(type, context, identity);
	}
}

class AETLSCredentialsManager : DefaultTLSCredentialsManager
{
	override void verifyCertificateChain(in string type, in string purported_hostname, const ref Vector!X509Certificate cert_chain)
	{
		// TODO!
	}
}

class BotanSSLContext : SSLContext
{
	Kind kind;
	TLSSessionManager sessions;
	TLSCredentialsManager creds;
	RandomNumberGenerator rng;
	TLSPolicy policy;

	this(Kind kind)
	{
		this.kind = kind;
		this.rng = new AutoSeededRNG;
		this.sessions = new TLSSessionManagerInMemory(rng);
		this.creds = new AETLSCredentialsManager();
		this.policy = new TLSPolicy;
	}

	override void setCipherList(string[] ciphers)
	{
		assert(false, "TODO");
	}

	override void enableDH(int bits)
	{
		assert(false, "TODO");
	}

	override void enableECDH()
	{
		assert(false, "TODO");
	}

	override void setCertificate(string path)
	{
		assert(false, "TODO");
	}

	override void setPrivateKey(string path)
	{
		assert(false, "TODO");
	}

	override void setPeerVerify(Verify verify)
	{
		assert(false, "TODO");
	}

	override void setPeerRootCertificate(string path)
	{
		assert(false, "TODO");
	}

	override void setFlags(int flags)
	{
		assert(false, "TODO");
	}
}

static this()
{
	ssl = new BotanSSLProvider();
}

// ***************************************************************************

class BotanSSLAdapter : SSLAdapter
{
	BotanSSLContext context;
	TLSChannel channel;

	this(BotanSSLContext context, IConnection next)
	{
		this.context = context;
		super(next);

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
			case SSLContext.Kind.client:
				channel = new TLSClient(
					&botanSocketOutput,
					&botanClientData,
					&botanAlert,
					&botanHandshake,
					context.sessions,
					context.creds,
					context.policy,
					context.rng
				);
				break;
			case SSLContext.Kind.server:
				assert(false, "TODO");
				// break;
		}
	}

	override void onReadData(Data data)
	{
		channel.receivedData(cast(ubyte*)data.ptr, data.length);
	}

	override void setHostName(string hostname)
	{
		assert(false, "TODO");
	}

	override SSLCertificate getHostCertificate()
	{
		assert(false, "TODO");
	}

	override SSLCertificate getPeerCertificate()
	{
		assert(false, "TODO");
	}

	void botanSocketOutput(in ubyte[] data) { next.send(Data(data, true)); }
	void botanClientData(in ubyte[] data) { throw new Exception("Unexpected client data"); }

	void botanAlert(in TLSAlert alert, in ubyte[] data)
	{
		if (alert.isFatal)
			super.disconnect("Fatal TLS alert: " ~ alert.typeString, DisconnectType.error);
	}

	bool botanHandshake(in TLSSession session)
	{
		super.onConnect();
		return true;
	}
}

class BotanSSLCertificate : SSLCertificate
{
}

// ***************************************************************************

unittest
{
	void testServer(string host, ushort port)
	{
		auto c = new TcpConnection;
		auto ctx = ssl.createContext(SSLContext.Kind.client);
		auto s = ssl.createAdapter(ctx, c);

		s.handleConnect =
		{
			debug(BotanSSL) stderr.writeln("Connected!");
			s.send(Data("GET / HTTP/1.0\r\nHost: www.google.com\r\n\r\n"));
		};
		s.handleReadData = (Data data)
		{
			debug(BotanSSL) { stderr.write(cast(string)data.contents); stderr.flush(); }
		};
		s.handleDisconnect = (string reason, DisconnectType type)
		{
			debug(BotanSSL) { stderr.writeln(reason); }
		};
		c.connect(host, port);
		socketManager.loop();
	}

	testServer("www.google.com", 443);
}
