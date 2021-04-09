/**
 * FPS counter
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

module ae.utils.fps;

import std.datetime;
import std.string;

/// FPS counter. Calls a user-supplied delegate with a formatted string.
struct FPSCounter
{
	/// Update. Once a second, calls `setter` with a string containing
	/// the number of `tick` calls during the last second.
	void tick(void delegate(string) setter)
	{
		auto thisSecond = Clock.currTime().second;
		if (thisSecond != lastSecond)
		{
			setter(format("%03d (%d us)", frames, frames?1_000_000/frames:0));
			frames = 0;
			lastSecond = thisSecond;
		}
		frames++;
	}

private:
	uint frames, lastSecond;
}
