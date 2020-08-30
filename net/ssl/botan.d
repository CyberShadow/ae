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

/// Botan implementation of SSLProvider.
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

/// Implementation of TLSCredentialsManager with the default behavior.
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
	/// E.g.: `() => readText(".../ca-bundle.crt")`
	static string delegate() trustedRootCABundleProvider = null;
	static CertificateStore trustedrootCABundleStore;

	SSLContext.Verify verify;

	override Vector!CertificateStore trustedCertificateAuthorities(in string type, in string context)
	{
		if (!trustedrootCABundleStore)
		{
			auto memStore = new CertificateStoreInMemory();
			import std.string : split;
			auto bundleText = trustedRootCABundleProvider();
			foreach (certText; bundleText.split("\n=")[1..$])
				memStore.addCertificate(X509Certificate(cast(DataSource) DataSourceMemory(certText)));
			trustedrootCABundleStore = memStore;
		}

		return Vector!CertificateStore(trustedrootCABundleStore);
	}

	override void verifyCertificateChain(in string type, in string purported_hostname, const ref Vector!X509Certificate cert_chain)
	{
		if (verify == SSLContext.Verify.none)
			return;
		if (verify == SSLContext.Verify.verify && cert_chain.empty)
			return;
		super.verifyCertificateChain(type, purported_hostname, cert_chain);
	}
}

class AETLSPolicy : TLSPolicy
{
}

class BotanSSLContext : SSLContext
{
	Kind kind;
	Verify verify;

	TLSSessionManager sessions;
	RandomNumberGenerator rng;
	TLSPolicy policy;

	this(Kind kind)
	{
		this.kind = kind;
		this.rng = new AutoSeededRNG;
		this.sessions = new TLSSessionManagerInMemory(rng);
		this.policy = new AETLSPolicy();
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
		this.verify = verify;
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

static this()
{
	// Needed for OCSP validation
	import botan.utils.http_util.http_util : tcp_message_handler;
	tcp_message_handler =
		(in string hostname, string message)
		{
			import std.socket : TcpSocket, InternetAddress;
			auto s = new TcpSocket(new InternetAddress(hostname, 80));
			import std.array;
			// stderr.writeln("OCSP send:", message);
			// import std.file; std.file.write("ocsp-req", message);
			while (message.length)
			{
				auto sent = s.send(message);
				message = message[sent .. $];
			}
			string reply;
			char[4096] buf;
			while (true)
			{
				auto received = s.receive(buf);
				if (received > 0)
					reply ~= buf[0 .. received];
				else
					break;
			}
			// stderr.writeln("OCSP:", [reply]);
			s.close();
			return reply;
		};
}

// ***************************************************************************

class BotanSSLAdapter : SSLAdapter
{
	BotanSSLContext context;
	TLSChannel channel;
	AETLSCredentialsManager creds;
	TLSServerInformation serverInfo;

	this(BotanSSLContext context, IConnection next)
	{
		this.context = context;
		this.creds = new AETLSCredentialsManager();
		this.creds.verify = context.verify;
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
					creds,
					context.policy,
					context.rng,
					serverInfo,
				);
				break;
			case SSLContext.Kind.server:
				assert(false, "TODO");
				// break;
		}
	}

	override void onReadData(Data data)
	{
		bool wasActive = channel.isActive();
		channel.receivedData(cast(ubyte*)data.ptr, data.length);
		if (!wasActive && channel.isActive())
			super.onConnect();
	}

	override void send(Data[] data, int priority)
	{
		foreach (datum; data)
			channel.send(cast(ubyte*)datum.ptr, datum.length);
	}

	override void setHostName(string hostname, ushort port = 0, string service = null)
	{
		serverInfo = TLSServerInformation(hostname, service, port);
	}

	override SSLCertificate getHostCertificate()
	{
		assert(false, "TODO");
	}

	override SSLCertificate getPeerCertificate()
	{
		assert(false, "TODO");
	}

	void botanSocketOutput(in ubyte[] data)
	{
		next.send(Data(data, true));
	}

	void botanClientData(in ubyte[] data)
	{
		super.onReadData(Data(data));
	}

	void botanAlert(in TLSAlert alert, in ubyte[] data)
	{
		if (alert.isFatal)
			super.disconnect("Fatal TLS alert: " ~ alert.typeString, DisconnectType.error);
	}

	bool botanHandshake(in TLSSession session)
	{
		debug(BotanSSL) stderr.writeln("Handshake done!");
		return true;
	}
}

class BotanSSLCertificate : SSLCertificate
{
}

// ***************************************************************************

unittest
{
	import std.file : readText;
	AETLSCredentialsManager.trustedRootCABundleProvider = () => readText("/home/vladimir/Downloads/ca-bundle.crt");

	void testServer(string host, ushort port)
	{
		auto c = new TcpConnection;
		auto ctx = ssl.createContext(SSLContext.Kind.client);
		auto s = ssl.createAdapter(ctx, c);
		Data allData;

		s.handleConnect =
		{
			debug(BotanSSL) stderr.writeln("Connected!");
			s.send(Data("GET /d/nettest/testUrl1 HTTP/1.0\r\nHost: thecybershadow.net\r\n\r\n"));
		};
		s.handleReadData = (Data data)
		{
			debug(BotanSSL) { stderr.write(cast(string)data.contents); stderr.flush(); }
			allData ~= data;
		};
		s.handleDisconnect = (string reason, DisconnectType type)
		{
			debug(BotanSSL) { stderr.writeln(reason); }
			assert(type == DisconnectType.graceful);
			import std.algorithm.searching : endsWith;
			assert((cast(string)allData.contents).endsWith("Hello world\n"));
		};
		s.setHostName("thecybershadow.net");
		c.connect(host, port);
		socketManager.loop();
	}

	testServer("thecybershadow.net", 443);
}

// version (unittest) import ae.net.ssl.test;
// unittest { testSSL(new BotanSSLProvider); }
