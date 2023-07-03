/**
 * Promise-based timing utilities.
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

module ae.utils.promise.timing;

import ae.utils.promise;
import ae.sys.timing;

Promise!void sleep(Duration delay)
{
	auto p = new Promise!void;
	setTimeout(&p.fulfill, delay);
	return p;
}

Promise!void sleepUntil(MonoTime when)
{
	auto p = new Promise!void;
	auto task = new TimerTask((Timer /*timer*/, TimerTask /*task*/) {
		p.fulfill();
	});
	mainTimer.add(task, when);
	return p;
}
