/**
 * Automatically select the event loop implementation
 * that's most likely to work in the current environment.
 *
 * Note: currently, ae supports only one concurrent event
 * loop implementation (decided at compilation time).
 *
 * This may change in the future, allowing different threads
 * to use different event loops.
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

module ae.sys.event.system;

version (LIBEV)
	public import ae.sys.event.libev;
else
	public import ae.sys.event.select;
