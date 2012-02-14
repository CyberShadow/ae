/**
 * Common IRC code.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.irc.common;

import core.time;
import std.string;

import ae.net.asockets;

/// Types of a chat message.
enum IrcMessageType
{
	NORMAL,
	ACTION,
	NOTICE
}

// RFC1459 case mapping
static assert(toLower("[") == "[" && toUpper("[") == "[");
static assert(toLower("]") == "]" && toUpper("]") == "]");
static assert(toLower("{") == "{" && toUpper("{") == "{");
static assert(toLower("}") == "}" && toUpper("}") == "}");
static assert(toLower("|") == "|" && toUpper("|") == "|");
static assert(toLower("\\") == "\\" && toUpper("\\") == "\\");

string rfc1459toLower(string name)
{
	return toLower(name).tr("[]\\","{}|");
}

string rfc1459toUpper(string name)
{
	return toUpper(name).tr("{}|","[]\\");
}

unittest
{
	assert(rfc1459toLower("{}|[]\\") == "{}|{}|");
	assert(rfc1459toUpper("{}|[]\\") == "[]\\[]\\");
}

class IrcSocket : LineBufferedSocket
{
	this()
	{
		super(TickDuration.from!"seconds"(90));
		handleIdleTimeout = &onIdleTimeout;
	}

	this(Socket conn)
	{
		super.setIdleTimeout(TickDuration.from!"seconds"(60));
		super(conn);
		handleIdleTimeout = &onIdleTimeout;
	}

	override void markNonIdle()
	{
		if (pingSent)
			pingSent = false;
		super.markNonIdle();
	}

	void delegate (IrcSocket sender) handleInactivity;
	void delegate (IrcSocket sender) handleTimeout;

private:
	void onIdleTimeout(ClientSocket sender)
	{
		if (pingSent || handleInactivity is null)
		{
			if (handleTimeout)
				handleTimeout(this);
			else
				disconnect("Time-out", DisconnectType.Error);
		}
		else
		{
			handleInactivity(this);
			pingSent = true;
		}
	}

	bool pingSent;
}

alias GenericServerSocket!(IrcSocket) IrcServerSocket;

// TODO: this is server-specific
const string IRC_NICK_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-`";
const string IRC_USER_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const string IRC_HOST_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.";
