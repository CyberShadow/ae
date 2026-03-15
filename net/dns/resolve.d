/**
 * Asynchronous DNS resolution.
 *
 * Promise-based wrapper around `ae.net.asockets.resolveHost`.
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

module ae.net.dns.resolve;

import std.socket : Address;

import ae.net.asockets : resolveHost;
import ae.utils.promise;

/// Asynchronously resolve a hostname. Returns a `Promise` that is
/// fulfilled with the resolved addresses, or rejected on error.
Promise!(Address[]) resolveAsync(string host, ushort port = 0)
{
	auto promise = new Promise!(Address[]);
	resolveHost(host, port, (Address[] addresses) {
		promise.fulfill(addresses);
	}, (string error) {
		promise.reject(new Exception(error));
	});
	return promise;
}

debug(ae_unittest) unittest
{
	import ae.net.asockets : socketManager, TcpServer, TcpConnection;
	import ae.sys.timing : setTimeout, TimerTask;
	import core.time : seconds;

	// Keep the event loop alive (non-daemon), and give us a handle to
	// stop it once resolution completes.
	auto server = new TcpServer();
	server.listen(0, "localhost");
	server.handleAccept = (TcpConnection incoming) {};

	bool resolved;
	TimerTask timeoutTask;

	resolveHost("127.0.0.1", 80, (Address[] addresses) {
		assert(addresses.length > 0);
		resolved = true;
		timeoutTask.cancel();
		server.close();
	}, (string error) {
		assert(false, error);
	});

	timeoutTask = setTimeout({
		assert(false, "Timed out");
	}, 10.seconds);

	socketManager.loop();
	assert(resolved);
}
