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
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 */

module ae.ui.timer.timer;

import ae.ui.app.application;

class Timer
{
	abstract TimerEvent setTimeout (AppCallback fn, uint ms);
	abstract TimerEvent setInterval(AppCallback fn, uint ms);
}

class TimerEvent
{
	abstract void cancel();
}
