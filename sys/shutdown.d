/**
 * Application shutdown control (with SIGTERM handling).
 * Different from atexit in that it controls initiation
 * of graceful shutdown, as opposed to cleanup actions
 * that are done as part of the shutdown process.
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

module ae.sys.shutdown;

import ae.sys.signals;

void addShutdownHandler(void delegate() fn)
{
	if (handlers.length == 0)
		addSignalHandler(SIGTERM, { shutdown(); });
	handlers ~= fn;
}

/// Calls all registered handlers.
void shutdown()
{
	foreach (fn; handlers)
		fn();
}

private:

shared void delegate()[] handlers;
