/**
 * SSL tests.
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

module ae.net.ssl.test;

import std.exception;

import ae.net.asockets;
import ae.net.ssl;

package(ae):

version (SSL_test)
	void testSSL(SSLProvider ssl) {}
else:

import std.stdio : stderr;

void testSSL(SSLProvider ssl)
{
	import std.algorithm.searching : startsWith;
	debug(SSL) import std.stdio : stderr;

	void testServer(string host, ushort port = 443)
	{
		stderr.writeln("Testing: ", host);
		auto c = new TcpConnection;
		auto ctx = ssl.createContext(SSLContext.Kind.client);
		ctx.setPeerVerify(SSLContext.Verify.require);
		auto s = ssl.createAdapter(ctx, c);
		Data allData;

		s.handleConnect =
		{
			debug(SSL) stderr.writeln("Connected!");
			s.send(Data("GET / HTTP/1.0\r\nHost: " ~ host ~ "\r\n\r\n"));
		};
		s.handleReadData = (Data data)
		{
			debug(SSL) { stderr.write(cast(string)data.contents); stderr.flush(); }
			allData ~= data;
		};
		s.handleDisconnect = (string reason, DisconnectType type)
		{
			debug(SSL) { stderr.writeln(reason); }
			enforce(type == DisconnectType.graceful, "Unexpected disconnection: " ~ reason);
			enforce((cast(string)allData.contents).startsWith("HTTP/1.1 200 OK\r\n"), "Unexpected response");
		};
		s.setHostName(host);
		c.connect(host, port);
		socketManager.loop();
	}

	testServer(              "expired.badssl.com").assertThrown;
	testServer(           "wrong.host.badssl.com").assertThrown;
	testServer(          "self-signed.badssl.com").assertThrown;
	testServer(       "untrusted-root.badssl.com").assertThrown;
	// testServer(              "revoked.badssl.com").assertThrown; // TODO!
	// testServer(         "pinning-test.badssl.com").assertThrown; // TODO!

	// testServer(       "no-common-name.badssl.com").assertNotThrown; // Currently expired
	// testServer(           "no-subject.badssl.com").assertNotThrown; // Currently expired
	// testServer(     "incomplete-chain.badssl.com").assertNotThrown; // TODO?

	testServer(               "sha256.badssl.com").assertNotThrown;
	// testServer(               "sha384.badssl.com").assertNotThrown; // Currently expired
	// testServer(               "sha512.badssl.com").assertNotThrown; // Currently expired

	// testServer(            "1000-sans.badssl.com").assertNotThrown; // Currently expired
	testServer(           "10000-sans.badssl.com").assertThrown;

	testServer(               "ecc256.badssl.com").assertNotThrown;
	testServer(               "ecc384.badssl.com").assertNotThrown;

	testServer(              "rsa2048.badssl.com").assertNotThrown;
	testServer(              "rsa4096.badssl.com").assertNotThrown;
	testServer(              "rsa8192.badssl.com").assertNotThrown;

	// testServer(  "extended-validation.badssl.com").assertNotThrown; // Currently expired - https://github.com/chromium/badssl.com/issues/516

	testServer(                  "cbc.badssl.com").assertNotThrown;
	testServer(              "rc4-md5.badssl.com").assertThrown;
	testServer(                  "rc4.badssl.com").assertThrown;
	testServer(                 "3des.badssl.com").assertThrown;
	testServer(                 "null.badssl.com").assertThrown;

	testServer(          "mozilla-old.badssl.com").assertNotThrown; // Watch me, browsers may drop support soon
	testServer( "mozilla-intermediate.badssl.com").assertNotThrown;
	testServer(       "mozilla-modern.badssl.com").assertNotThrown;

	testServer(                "dh480.badssl.com").assertThrown;
	testServer(                "dh512.badssl.com").assertThrown;
	testServer(               "dh1024.badssl.com").assertThrown;
	testServer(               "dh2048.badssl.com").assertThrown;

	testServer(    "dh-small-subgroup.badssl.com").assertThrown;
	testServer(         "dh-composite.badssl.com").assertThrown;

	testServer(           "static-rsa.badssl.com").assertNotThrown;

	testServer(             "tls-v1-0.badssl.com", 1010).assertThrown;
	testServer(             "tls-v1-1.badssl.com", 1011).assertThrown;
	testServer(             "tls-v1-2.badssl.com", 1012).assertNotThrown;
}
