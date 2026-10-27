/**
 * Thread-exit checks for leaked promises.
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

module ae.utils.promise.leakcheck;

// The leak checks of all `Promise` instantiations run from the static
// destructor of this module, instead of from a static destructor in the
// `Promise` class template. A static destructor in a template is a
// static destructor of every module instantiating the template, so
// that the runtime could not order the destruction of any two such
// modules which import each other (directly or not), and would abort
// with "Cyclic dependency between module constructors/destructors".
// This module imports nothing, and is therefore never part of a cycle.

package(ae):

/// Register `check` to be called when the current thread exits.
void registerLeakCheck(void function() check) nothrow @safe
{
	leakChecks ~= check;
}

private:

void function()[] leakChecks;

static ~this()
{
	foreach (check; leakChecks)
		check();
}
