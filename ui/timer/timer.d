/**
 * ae.ui.timer.timer
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

module ae.ui.timer.timer;

import ae.ui.app.application;

/// Abstract timer interface.
class Timer
{
	/// Run `fn` after `ms` milliseconds.
	abstract TimerEvent setTimeout (AppCallback fn, uint ms);
	/// Run `fn` every `ms` milliseconds.
	abstract TimerEvent setInterval(AppCallback fn, uint ms);
}

/// Abstract interface for registered timer events.
class TimerEvent
{
	/// Cancel the timer task.
	abstract void cancel();
}
