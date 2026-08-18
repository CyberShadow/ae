/**
 * EXTERNAL authentication for a D-Bus connection attempt.
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

module ae.net.dbus.auth;

import ae.sys.data : Data;
import ae.utils.array : asBytes;

import ae.net.dbus.common : DbusAuthenticationException,
	DbusServerGuid, DbusValidationException;

version(Posix)
import core.sys.posix.unistd : getuid;

debug(ae_unittest)
import core.exception : AssertError;
debug(ae_unittest)
import core.memory : GC;

private enum size_t dbusAuthenticationMaxLineBytes = 4096;

package(ae.net.dbus) alias DbusAuthenticationSender = void delegate(Data data);

/**
 * The result of the one transition from text authentication to binary D-Bus
 * bytes.  binarySuffix owns every byte received after the accepted CRLF.
 */
package(ae.net.dbus) struct DbusAuthenticationResult
{
	bool complete;
	DbusServerGuid serverGuid;
	Data binarySuffix;
}

/**
 * Hex-encode the decimal ASCII spelling of a POSIX UID for EXTERNAL.
 */
private string encodeDbusExternalIdentity(ulong uid) pure
{
	char[20] decimalDigits;
	size_t first = decimalDigits.length;
	do
	{
		decimalDigits[--first] = cast(char) ('0' + uid % 10);
		uid /= 10;
	}
	while (uid);

	char[] result = new char[(decimalDigits.length - first) * 2];
	foreach (index, character; decimalDigits[first .. $])
	{
		auto value = cast(ubyte) character;
		result[index * 2] = cast(char) (value >> 4 < 10 ? '0' + (value >> 4) :
			'a' + (value >> 4) - 10);
		result[index * 2 + 1] = cast(char) ((value & 0x0f) < 10 ?
			'0' + (value & 0x0f) : 'a' + (value & 0x0f) - 10);
	}
	return result.idup;
}

/**
 * A fresh EXTERNAL-only authentication state machine for one connected
 * transport attempt.  The caller owns the transport and supplies only its
 * ordered byte sender.
 */
package(ae.net.dbus) final class DbusExternalAuthenticator
{
private:
	enum State
	{
		initial,
		waitingForOk,
		binary,
		failed,
	}

	State state_;
	DbusAuthenticationSender sender_;
	DbusServerGuid expectedGuid_;
	bool hasExpectedGuid_;
	ubyte[dbusAuthenticationMaxLineBytes] line;
	size_t lineLength;

	void fail(string message)
	{
		state_ = State.failed;
		lineLength = 0;
		throw new DbusAuthenticationException(message);
	}

	DbusAuthenticationResult acceptLine(scope const(ubyte)[] response,
		scope const(ubyte)[] suffix)
	{
		if (response.length != 35 || response[0] != 'O' || response[1] != 'K' ||
			response[2] != ' ')
			fail("the D-Bus server rejected EXTERNAL authentication");

		DbusServerGuid serverGuid;
		try
			serverGuid = DbusServerGuid.parse(cast(string) response[3 .. $]);
		catch (DbusValidationException)
			fail("the D-Bus server sent a malformed authentication GUID");

		if (hasExpectedGuid_ && serverGuid != expectedGuid_)
			fail("the D-Bus server GUID does not match the address GUID");

		state_ = State.binary;
		lineLength = 0;
		sender_(Data("BEGIN\r\n".asBytes));

		DbusAuthenticationResult result;
		result.complete = true;
		result.serverGuid = serverGuid;
		result.binarySuffix = Data(suffix);
		return result;
	}

	void startWithIdentity(DbusAuthenticationSender sender, string identity)
	{
		assert(state_ == State.initial);
		assert(sender !is null);
		sender_ = sender;
		state_ = State.waitingForOk;

		ubyte[1] nul = [0];
		sender_(Data(nul[]));
		sender_(Data(("AUTH EXTERNAL " ~ identity ~ "\r\n").asBytes));
	}

package:
	this(DbusServerGuid expectedGuid = DbusServerGuid.init)
	{
		hasExpectedGuid_ = expectedGuid.text.length != 0;
		expectedGuid_ = expectedGuid;
	}

	version(Posix)
	void start(DbusAuthenticationSender sender)
	{
		startWithIdentity(sender, encodeDbusExternalIdentity(cast(ulong) getuid()));
	}

	DbusAuthenticationResult feed(Data fragment)
	{
		assert(state_ == State.waitingForOk);
		DbusAuthenticationResult result;
		fragment.enter((scope input)
		{
			foreach (size_t index, octet; input)
			{
				if (octet == 0)
					fail("D-Bus authentication responses must not contain NUL");
				if (octet > 0x7f)
					fail("D-Bus authentication responses must be ASCII");

				if (lineLength && line[lineLength - 1] == '\r')
				{
					if (octet != '\n')
						fail("D-Bus authentication lines must end with CRLF");
					result = acceptLine(line[0 .. lineLength - 1], input[index + 1 .. $]);
					return;
				}

				if (octet == '\n')
					fail("D-Bus authentication lines must end with CRLF");
				if (lineLength == dbusAuthenticationMaxLineBytes)
					fail("D-Bus authentication input exceeds the local resource limit");
				line[lineLength++] = octet;
			}
		});
		return result;
	}
}

debug(ae_unittest)
private enum dbusAuthenticationTestGuid = "0123456789abcdef0123456789abcdef";

debug(ae_unittest)
private enum dbusAuthenticationOtherTestGuid = "fedcba98765432100123456789abcdef";

debug(ae_unittest)
private void expectDbusAuthenticationFailure(void delegate() action)
{
	bool caught;
	try
		action();
	catch (DbusAuthenticationException)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private void expectDbusAuthenticationAssert(void delegate() action)
{
	bool caught;
	try
		action();
	catch (AssertError)
		caught = true;
	assert(caught);
}

debug(ae_unittest)
private DbusExternalAuthenticator startDbusAuthenticationTestAuthenticator(
	DbusServerGuid expectedGuid = DbusServerGuid.init)
{
	auto authenticator = new DbusExternalAuthenticator(expectedGuid);
	authenticator.startWithIdentity((Data) {}, "30");
	return authenticator;
}

debug(ae_unittest) unittest
{
	assert(encodeDbusExternalIdentity(0) == "30");
	assert(encodeDbusExternalIdentity(1000) == "31303030");

	Data[] sent;
	auto authenticator = new DbusExternalAuthenticator;
	authenticator.startWithIdentity((Data data) { sent ~= data.dup; },
		encodeDbusExternalIdentity(1000));
	assert(sent.length == 2);
	assert(sent[0].toGC == [cast(ubyte) 0]);
	assert(sent[1].toGC == "AUTH EXTERNAL 31303030\r\n".asBytes);

	auto result = authenticator.feed(Data(("OK " ~ dbusAuthenticationTestGuid ~
		"\r\n").asBytes));
	assert(result.complete);
	assert(result.serverGuid.text == dbusAuthenticationTestGuid);
	assert(result.binarySuffix.length == 0);
	assert(sent.length == 3);
	assert(sent[2].toGC == "BEGIN\r\n".asBytes);
}

debug(ae_unittest) unittest
{
	version(Posix)
	{
		Data[] sent;
		auto authenticator = new DbusExternalAuthenticator;
		authenticator.start((Data data) { sent ~= data.dup; });
		assert(sent.length == 2);
		assert(sent[0].toGC == [cast(ubyte) 0]);
		assert(sent[1].toGC == ("AUTH EXTERNAL " ~
			encodeDbusExternalIdentity(cast(ulong) getuid()) ~ "\r\n").asBytes);
	}
}

debug(ae_unittest) unittest
{
	auto fragmented = startDbusAuthenticationTestAuthenticator();
	auto incomplete = fragmented.feed(Data("O".asBytes));
	assert(!incomplete.complete);
	incomplete = fragmented.feed(Data(("K " ~ dbusAuthenticationTestGuid ~ "\r").asBytes));
	assert(!incomplete.complete);
	ubyte[] fragmentedSuffix = [0, cast(ubyte) 0xff, 'b'];
	auto fragmentedInput = [cast(ubyte) '\n'] ~ fragmentedSuffix;
	auto fragmentedResult = fragmented.feed(Data(fragmentedInput));
	assert(fragmentedResult.complete);
	assert(fragmentedResult.serverGuid.text == dbusAuthenticationTestGuid);
	assert(fragmentedResult.binarySuffix.toGC == fragmentedSuffix);

	auto coalesced = startDbusAuthenticationTestAuthenticator();
	auto response = "OK " ~ dbusAuthenticationTestGuid ~ "\r\n";
	ubyte[] coalescedSuffix = [cast(ubyte) 'x', 0, 0xfe];
	ubyte[] coalescedInput = response.asBytes.dup;
	coalescedInput ~= coalescedSuffix;
	auto source = Data(coalescedInput);
	auto coalescedResult = coalesced.feed(source);
	assert(coalescedResult.complete);
	source[response.length] = cast(ubyte) 'y';
	assert(coalescedResult.binarySuffix.toGC == coalescedSuffix);
}

debug(ae_unittest) unittest
{
	auto response = "OK " ~ dbusAuthenticationTestGuid ~ "\r\n";
	foreach (split; 0 .. response.length + 1)
	{
		Data[] sent;
		auto authenticator = new DbusExternalAuthenticator;
		authenticator.startWithIdentity((Data data) { sent ~= data.dup; }, "30");
		auto result = authenticator.feed(Data(response.asBytes[0 .. split]));
		if (split < response.length)
		{
			assert(!result.complete);
			result = authenticator.feed(Data(response.asBytes[split .. $]));
		}
		assert(result.complete);
		assert(result.serverGuid.text == dbusAuthenticationTestGuid);
		assert(result.binarySuffix.length == 0);
		assert(sent.length == 3);
	}
}

debug(ae_unittest) unittest
{
	auto authenticator = startDbusAuthenticationTestAuthenticator();
	auto line = new ubyte[dbusAuthenticationMaxLineBytes];
	line[] = cast(ubyte) 'x';
	auto partial = authenticator.feed(Data(line));
	assert(!partial.complete);
	expectDbusAuthenticationFailure({
		authenticator.feed(Data([cast(ubyte) 'x']));
	});
}

debug(ae_unittest) unittest
{
	auto input = new ubyte[1024 * 1024];
	input[] = cast(ubyte) 'x';
	auto fragment = Data(input);
	auto authenticator = startDbusAuthenticationTestAuthenticator();
	auto before = GC.stats.allocatedInCurrentThread;
	expectDbusAuthenticationFailure({
		authenticator.feed(fragment);
	});
	auto after = GC.stats.allocatedInCurrentThread;
	assert(after - before < 64 * 1024,
		"over-cap authentication input must not be copied before rejection");
}

debug(ae_unittest) unittest
{
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data([cast(ubyte) 0]));
		});
	}
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data([cast(ubyte) 0x80]));
		});
	}
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data(("OK " ~ dbusAuthenticationTestGuid ~ "\n").asBytes));
		});
	}
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data(("OKX " ~ dbusAuthenticationTestGuid ~ "\r\n").asBytes));
		});
	}
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data("OK 0123456789abcdef0123456789abcdeg\r\n".asBytes));
		});
	}
	foreach (response; [
		"OK\r\n",
		"OK \r\n",
		"OK  " ~ dbusAuthenticationTestGuid ~ "\r\n",
		"OK " ~ dbusAuthenticationTestGuid ~ " extra\r\n",
		"OK 0123456789abcdef0123456789abcde\r\n",
		"OK 0123456789abcdef0123456789abcdef0\r\n",
	])
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data(response.asBytes));
		});
	}

	foreach (response; [
		"REJECTED EXTERNAL\r\n",
		"ERROR EXTERNAL\r\n",
		"DATA 3130\r\n",
		"UNRECOGNIZED\r\n",
	])
	{
		auto authenticator = startDbusAuthenticationTestAuthenticator();
		expectDbusAuthenticationFailure({
			authenticator.feed(Data(response.asBytes));
		});
	}
}

debug(ae_unittest) unittest
{
	auto expectedGuid = DbusServerGuid.parse(dbusAuthenticationTestGuid);
	auto matching = startDbusAuthenticationTestAuthenticator(expectedGuid);
	auto result = matching.feed(Data(
		"OK 0123456789ABCDEF0123456789ABCDEF\r\n".asBytes));
	assert(result.complete);
	assert(result.serverGuid == expectedGuid);

	auto mismatch = startDbusAuthenticationTestAuthenticator(expectedGuid);
	expectDbusAuthenticationFailure({
		mismatch.feed(Data(("OK " ~ dbusAuthenticationOtherTestGuid ~ "\r\n").asBytes));
	});
}

debug(ae_unittest) unittest
{
	auto initial = new DbusExternalAuthenticator;
	expectDbusAuthenticationAssert({
		initial.feed(Data(("OK " ~ dbusAuthenticationTestGuid ~ "\r\n").asBytes));
	});

	Data[] sent;
	auto authenticator = new DbusExternalAuthenticator;
	authenticator.startWithIdentity((Data data) { sent ~= data.dup; }, "30");
	expectDbusAuthenticationAssert({
		authenticator.startWithIdentity((Data) {}, "30");
	});
	authenticator.feed(Data(("OK " ~ dbusAuthenticationTestGuid ~ "\r\n").asBytes));
	expectDbusAuthenticationAssert({
		authenticator.feed(Data([cast(ubyte) 0]));
	});

	auto failed = startDbusAuthenticationTestAuthenticator();
	expectDbusAuthenticationFailure({
		failed.feed(Data("REJECTED EXTERNAL\r\n".asBytes));
	});
	expectDbusAuthenticationAssert({
		failed.feed(Data("REJECTED EXTERNAL\r\n".asBytes));
	});
}
