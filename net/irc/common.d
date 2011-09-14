/* ***** BEGIN LICENSE BLOCK *****
 * Version: MPL 1.1/GPL 3.0
 *
 * The contents of this file are subject to the Mozilla Public License Version
 * 1.1 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 * http://www.mozilla.org/MPL/
 *
 * Software distributed under the License is distributed on an "AS IS" basis,
 * WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License
 * for the specific language governing rights and limitations under the
 * License.
 *
 * The Original Code is the Team15 library.
 *
 * The Initial Developer of the Original Code is
 * Stéphan Kochen <stephan@kochen.nl>
 * Portions created by the Initial Developer are Copyright (C) 2006
 * the Initial Developer. All Rights Reserved.
 *
 * Contributor(s):
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 *
 * Alternatively, the contents of this file may be used under the terms of the
 * GNU General Public License Version 3 (the "GPL") or later, in which case
 * the provisions of the GPL are applicable instead of those above. If you
 * wish to allow use of your version of this file only under the terms of the
 * GPL, and not to allow others to use your version of this file under the
 * terms of the MPL, indicate your decision by deleting the provisions above
 * and replace them with the notice and other provisions required by the GPL.
 * If you do not delete the provisions above, a recipient may use your version
 * of this file under the terms of either the MPL or the GPL.
 *
 * ***** END LICENSE BLOCK ***** */

/// Common IRC code.
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
