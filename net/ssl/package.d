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

abstract class SSLAdapter : ConnectionAdapter
{
	this(IConnection next) { super(next); }
}

class SSLProvider
{
	abstract SSLContext createContext(SSLContext.Kind kind);
	abstract SSLAdapter createAdapter(SSLContext context, IConnection next);
}

abstract class SSLContext
{
	enum Kind { client, server }
	abstract void setCertificate(string path);
	abstract void setPrivateKey(string path);
	abstract void setCipherList(string[] ciphers);
}

SSLProvider ssl;
