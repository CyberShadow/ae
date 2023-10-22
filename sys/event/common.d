/**
 * Event loop common declarations.
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

module ae.sys.event.common;

/// Schedule a function to run on the next event loop iteration.
/// Can be used to queue logic to run once all current execution frames exit.
/// Similar to e.g. process.nextTick in Node.
void onNextTick(ref EventLoop eventLoop, void delegate() dg) pure @safe nothrow
{
	eventLoop.nextTickHandlers ~= dg;
}

/// The current logical monotonic time.
/// Updated by the event loop whenever it is awoken.
@property MonoTime now()
{
	if (eventLoop.now == MonoTime.init)
	{
		// Event loop not yet started.
		eventLoop.now = MonoTime.currTime();
	}
	return eventLoop.now;
}
