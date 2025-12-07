/**
 * Demonstrates the ASOCKETS_DEBUG_SHUTDOWN feature.
 *
 * This demo shows how to diagnose stuck shutdown scenarios where the
 * event loop doesn't exit cleanly because some objects weren't properly
 * cleaned up.
 *
 * The demo creates:
 * - A TCP listener (server socket)
 * - A periodic timer
 * - An idle handler
 *
 * Then it requests a shutdown but intentionally "forgets" to clean up
 * some of these objects. When compiled with debug=ASOCKETS_DEBUG_SHUTDOWN,
 * the debug machinery will print information about what's blocking
 * the event loop from exiting.
 *
 * Usage:
 *   dub run                          # Run with default 5 second timeout
 *   AE_DEBUG_SHUTDOWN_TIMEOUT="2 secs" dub run   # Custom timeout
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

module ae.demo.debug_shutdown.debug_shutdown;

import core.stdc.stdlib : exit;
import std.stdio;

import ae.net.asockets;
import ae.net.shutdown;
import ae.sys.timing;

void main()
{
	writeln("=== Shutdown Debug Demo ===");
	writeln();
	writeln("This demo illustrates the ASOCKETS_DEBUG_SHUTDOWN feature.");
	writeln("It creates several event loop objects but intentionally doesn't");
	writeln("clean them all up when shutdown is requested.");
	writeln();

	// Create a TCP server that listens on a port
	auto server = new TcpServer();
	server.listen(0, "127.0.0.1"); // Listen on random available port
	auto serverPort = server.localAddresses[0].toPortString();
	writeln("Created TCP server listening on port ", serverPort);

	// Create a client connection to the server
	auto client = new TcpConnection();
	import std.conv : to;
	client.connect("127.0.0.1", serverPort.to!ushort);
	// Set up a read handler so the socket actively waits for data
	client.handleReadData = (data) {
		writeln("Received data (unexpected in this demo)");
	};
	writeln("Created TCP client connecting to server");

	// Create a periodic timer that fires every 10 seconds
	auto periodicTimer = setInterval({
		writeln("Periodic timer fired (this shouldn't happen after shutdown)");
	}, 10.seconds);
	writeln("Created periodic timer (fires every 10 seconds)");

	// Create an idle handler
	socketManager.addIdleHandler({
		// This idle handler does nothing but prevents clean exit
	});
	writeln("Created idle handler");

	// Create another timer that will request shutdown after 1 second
	setTimeout({
		writeln();
		writeln("Requesting shutdown now...");
		writeln("(But we intentionally forgot to clean up some objects!)");
		writeln();

		// Proper cleanup would be:
		//   server.close();
		//   client.disconnect();
		//   periodicTimer.cancel();
		//   socketManager.removeIdleHandler(...);
		//
		// But we intentionally leave things uncleaned to demonstrate stuck shutdown:
		// - server is NOT closed (will block!)
		// - client is NOT disconnected (will block!)
		// - periodicTimer is NOT cancelled (will block!)
		// - idle handler is NOT removed (will block!)

		// Note: server, client, periodicTimer, and idle handler are NOT cleaned up!
		// The debug machinery should report them.

		shutdown("demo");

		// Schedule exit shortly after the debug watchdog has printed its report.
		// The watchdog timeout can be configured via AE_DEBUG_SHUTDOWN_TIMEOUT.
		// We add 1 extra second to ensure the watchdog fires first.
		import std.process : environment;
		import ae.utils.time.parsedur : parseDuration;
		auto watchdogTimeout = parseDuration(environment.get("AE_DEBUG_SHUTDOWN_TIMEOUT", "5 secs"));
		setTimeout({
			writeln();
			writeln("Demo complete. Exiting forcefully.");
			writeln("(In a real application, you would fix the leak instead!)");
			exit(0);
		}, watchdogTimeout + 1.seconds);
	}, 1.seconds);
	writeln("Shutdown will be requested in 1 second...");
	writeln();

	// Register a shutdown handler that would normally do cleanup
	addShutdownHandler((reason) {
		writeln("Shutdown handler called with reason: ", reason ? reason : "(none)");
		// In a real application, you would clean up resources here.
		// For this demo, we intentionally don't clean up everything.
	});

	writeln("Starting event loop...");
	writeln("(The debug watchdog will trigger after the configured timeout)");
	writeln();

	// Run the event loop - it should hang because of uncleaned resources
	socketManager.loop();

	// This line should not be reached in this demo
	writeln("Event loop exited cleanly (unexpected in this demo)");
}
