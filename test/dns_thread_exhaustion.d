/**
 * End-to-end regression test for DNS worker-thread address-space exhaustion.
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

module ae.test.dns_thread_exhaustion;

import std.socket : Address;
import std.stdio : stderr;
import std.conv : to;

import core.stdc.stdlib : exit;
import core.time : seconds;

import ae.net.asockets : resolveHost, socketManager, TcpServer, TcpConnection;
import ae.sys.timing : TimerTask, setTimeout;

void main()
{
	enum iterations = 3000;

	foreach (size_t i; 0 .. iterations)
	{
		auto server = new TcpServer();
		server.listen(0, "localhost");
		server.handleAccept = (TcpConnection incoming) {};

		bool resolved;
		TimerTask timeoutTask;

		try
		{
			resolveHost("127.0.0.1", 80, (Address[] addresses) {
				assert(addresses.length > 0);
				resolved = true;
				timeoutTask.cancel();
				server.close();
			}, (string error) {
				stderr.writefln("iteration %s: lookup error: %s", i, error);
				exit(1);
			});
		}
		catch (Throwable t)
		{
			stderr.writefln("iteration %s: %s: %s", i, typeid(t), t.msg);
			exit(1);
		}

		timeoutTask = setTimeout({
			assert(false, "Timed out waiting for DNS resolution at iteration " ~ i.to!string);
		}, 10.seconds);

		socketManager.loop();
		assert(resolved);
	}
}
