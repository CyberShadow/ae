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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.net.ssl;

import ae.net.asockets : IConnection, ConnectionAdapter;

class SSLProvider
{
	abstract SSLContext createContext(SSLContext.Kind kind);
	abstract SSLAdapter createAdapter(SSLContext context, IConnection next);
}

class NoSSLProvider : SSLProvider
{
	override SSLContext createContext(SSLContext.Kind kind)
	{
		assert(false, "SSL implementation not set");
	}

	override SSLAdapter createAdapter(SSLContext context, IConnection next)
	{
		assert(false, "SSL implementation not set");
	}
}

abstract class SSLContext
{
	enum Kind { client, server }
	enum Verify { none, verify, require }

	abstract void setCipherList(string[] ciphers);
	abstract void enableDH(int bits);
	abstract void enableECDH();
	abstract void setCertificate(string path);
	abstract void setPrivateKey(string path);
	abstract void setPeerVerify(Verify verify);
	abstract void setPeerRootCertificate(string path);
	abstract void setFlags(int); // implementation-specific
}

abstract class SSLAdapter : ConnectionAdapter
{
	this(IConnection next) { super(next); }
	abstract void setHostName(string hostname, ushort port = 0, string service = null);
	abstract SSLCertificate getHostCertificate();
	abstract SSLCertificate getPeerCertificate();
}

abstract class SSLCertificate
{
	abstract string getSubjectName();
}

SSLProvider ssl;

static this()
{
	assert(!ssl);
	ssl = new NoSSLProvider();
}
