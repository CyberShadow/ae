/**
 * SSL support.
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

module ae.net.ssl.ssl;

import std.functional;

import ae.net.asockets;

alias ClientSocket delegate() SSLSocketFactory;

SSLSocketFactory sslSocketFactory;
static this()
{
	assert(!sslSocketFactory);
	sslSocketFactory = toDelegate(&defaultProvider);
}

private ClientSocket defaultProvider()
{
	assert(false, "No SSL provider (import a provider from ae.net.ssl.*)");
}
