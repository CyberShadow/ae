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

abstract class SSLAdapter : ConnectionAdapter
{
	this(IConnection next) { super(next); }
}

alias SSLAdapter delegate(IConnection next) SSLAdapterFactory;

SSLAdapterFactory sslAdapterFactory;
static this()
{
	assert(!sslAdapterFactory);
	sslAdapterFactory = toDelegate(&defaultProvider);
}

private SSLAdapter defaultProvider(IConnection next)
{
	assert(false, "No SSL provider (import a provider from ae.net.ssl.*)");
}
