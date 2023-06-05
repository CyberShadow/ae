/**
 * X11 demo.
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

module ae.demo.x11.demo;

import std.algorithm.iteration;
import std.array;

import ae.net.asockets;
import ae.net.x11;
import ae.utils.array;
import ae.utils.promise;

// Pro tip: Build with -debug=PRINTDATA to see the raw bytes sent and
// received from the X server!

void main()
{
	auto x11 = new X11Client();

	// Maintain a dictionary of known interred atoms.
	Atom[string] atoms;
	Promise!Atom getAtom(string name)
	{
		auto p = new Promise!Atom;
		if (auto patom = name in atoms)
			p.fulfill(*patom);
		else
			x11.sendInternAtom(false, name)
				.dmd21804workaround
 				.then((result) {
					atoms[name] = result.atom;
					p.fulfill(result.atom);
				});
		return p;
	}

	// Our window, and the context we use to draw on it.
	Window wid;
	GContext gc;

	// All operations can only be done once the handshake completes.
	x11.handleConnect = {
		wid = x11.newRID(); // ID generation happens completely locally.

		// Create our window.
		WindowAttributes windowAttributes;
		windowAttributes.eventMask = ExposureMask;
		x11.sendCreateWindow(
			0,
			wid,
			x11.roots[0].root.windowId,
			0, 0,
			256, 256,
			10,
			InputOutput,
			x11.roots[0].root.rootVisualID,
			windowAttributes,
		);
		x11.sendMapWindow(wid);

		// Create a graphics context from the window.
		gc = x11.newRID();
		GCAttributes gcAttributes;
		gcAttributes.foreground = x11.roots[0].root.blackPixel;
		gcAttributes.background = x11.roots[0].root.whitePixel;
		x11.sendCreateGC(
			gc, wid,
			gcAttributes,
		);

		// Announce our support of the WM_DELETE_WINDOW window manager
		// protocol.  To do that, we need to intern some atoms first.
		["WM_PROTOCOLS", "WM_DELETE_WINDOW", "ATOM"]
			.map!getAtom
			.array
			.all
			.then((result) {
				x11.sendChangeProperty(
					PropModeReplace,
					wid,
					atoms["WM_PROTOCOLS"], atoms["ATOM"],
					32,
					[atoms["WM_DELETE_WINDOW"]].asBytes,
				);
			});
	};

	// The expose event informs us when it's time to repaint our window.
	// Register a handler here.
	x11.handleExpose = (event) {
		if (event.window == wid)
		{
			x11.sendPolyFillRectangle(wid, gc, [xRectangle(0, 0, ushort.max, ushort.max)]);
			// Query the current window geometry, so that we can draw the text in the center.
			x11.sendGetGeometry(wid)
				.dmd21804workaround
				.then((result) {
					x11.sendImageText8(wid, gc, result.width / 2, result.height / 2, "Hello X11!");
				});
		}
	};

	// Register a handler for the client message event, so that we can
	// be notified of when the window manager is asking our window to
	// please go away.
	x11.handleClientMessage = (event) {
		if (event.type == atoms["WM_PROTOCOLS"])
		{
			auto messageAtoms = event.asBytes.as!(Atom[]);
			if (messageAtoms[0] == atoms["WM_DELETE_WINDOW"])
			{
				// As the X11 connection is the only object in the
				// event loop, disconnecting from the X server will
				// gracefully stop our application.
				x11.conn.disconnect();
			}
		}
	};
	x11.handleDisconnect = (string error, DisconnectType type) {
		import std.stdio : writefln;
		writefln("Disconnected (%s): %s", type, error);
	};

	// Run the event loop.
	socketManager.loop();
}
