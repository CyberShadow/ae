/**
 * SSL support.
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

module ae.net.ssl;

import ae.net.asockets : IConnection, ConnectionAdapter;

/// Abstract interface for an SSL context provider.
class SSLProvider
{
	/// Create an SSL context of the given kind (client or server).
	abstract SSLContext createContext(SSLContext.Kind kind);

	/// Create a connection adapter using the given context.
	abstract SSLAdapter createAdapter(SSLContext context, IConnection next);
}

/// The default (null) `SSLProvider` implementation.
/// Throws an assertion failure.
class NoSSLProvider : SSLProvider
{
	override SSLContext createContext(SSLContext.Kind kind)
	{
		assert(false, "SSL implementation not set");
	} ///

	override SSLAdapter createAdapter(SSLContext context, IConnection next)
	{
		assert(false, "SSL implementation not set");
	} ///
}

enum SSLVersion
{
	unspecified,
	ssl3,
	tls1,
	tls11,
	tls12,
	tls13,
}

/// Abstract interface for an SSL context.
abstract class SSLContext
{
	/// Context kind.
	enum Kind
	{
		client, ///
		server,	///
	}

	/// Whether to verify the peer certificate.
	enum Verify
	{
		none,    /// Do not verify or require.
		verify,  /// Verify the certificate if one is specified.
		require, /// Require a certificate and verify it.
	}

	abstract void setCipherList(string[] ciphers);                /// Configure OpenSSL-like cipher list.
	abstract void enableDH(int bits);                             /// Enable Diffie-Hellman key exchange with the specified key size.
	abstract void enableECDH();                                   /// Enable elliptic-curve DH key exchange.
	abstract void setCertificate(string path);                    /// Load and use a local certificate from the given file.
	abstract void setPrivateKey(string path);                     /// Load and use the certificate private key from the given file.
	abstract void setPreSharedKey(string id, const(ubyte)[] key); /// Use a pre-shared key instead of using certificate-based peer verification.
	abstract void setPeerVerify(Verify verify);                   /// Configure peer certificate verification.
	abstract void setPeerRootCertificate(string path);            /// Require that peer certificates are signed by the specified root certificate.
	abstract void setFlags(int);                                  /// Configure provider-specific flags.
	abstract void setMinimumVersion(SSLVersion);                  /// Set the minimum protocol version.
	abstract void setMaximumVersion(SSLVersion);                  /// Set the maximum protocol version.
}

/// Base class for a connection adapter with TLS encryption.
abstract class SSLAdapter : ConnectionAdapter
{
	this(IConnection next) { super(next); } ///

	/// Specifies the expected host name (used for peer verification).
	abstract void setHostName(string hostname, ushort port = 0, string service = null);

	/// Retrieves the SNI hostname, if one was indicated.
	abstract string getSNIHostname();

	/// Retrieves the host (local) certificate.
	abstract SSLCertificate getHostCertificate();

	/// Retrieves the peer (remote) certificate.
	abstract SSLCertificate getPeerCertificate();
}

/// Abstract interface for an SSL certificate.
abstract class SSLCertificate
{
	/// Returns the full certificate subject name.
	abstract string getSubjectName();
}

/// The current global SSL provider.
SSLProvider ssl;

static this()
{
	assert(!ssl);
	ssl = new NoSSLProvider();
}
