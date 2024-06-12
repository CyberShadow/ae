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
 *   Vladimir Panteleev <ae@cy.md>
 *   Vincent Povirk <madewokherd@gmail.com>
 *   Simon Arlott
 */

module ae.net.irc.common;

import core.time;
import std.algorithm.comparison;
import std.algorithm.iteration;
import std.array;
import std.exception;
import std.string;
import std.utf;

import ae.net.asockets;
import ae.utils.array : asBytes;

debug(IRC) import std.stdio : stderr;

/// Types of a chat message.
enum IrcMessageType
{
	NORMAL,  /// PRIVMSG.
	ACTION,  /// PRIVMSG with an ACTION CTCP. (TODO remove this, as it is orthogonal to the IRC message type)
	NOTICE,  /// NOTICE message.
}

static assert(toLower("[") == "[" && toUpper("[") == "[");
static assert(toLower("]") == "]" && toUpper("]") == "]");
static assert(toLower("{") == "{" && toUpper("{") == "{");
static assert(toLower("}") == "}" && toUpper("}") == "}");
static assert(toLower("|") == "|" && toUpper("|") == "|");
static assert(toLower("\\") == "\\" && toUpper("\\") == "\\");

/// RFC1459 case mapping.
char rfc1459toLower(char c) pure
{
	if (c >= 'A' && c <= ']')
		c += ('a' - 'A');
	return c;
}

/// ditto
char rfc1459toUpper(char c) pure
{
	if (c >= 'a' && c <= '}')
		c -= ('a' - 'A');
	return c;
}

/// ditto
string rfc1459toLower(string name) pure
{
	return name.byChar.map!rfc1459toLower.array;
}


/// ditto
string rfc1459toUpper(string name) pure
{
	return name.byChar.map!rfc1459toUpper.array;
}

debug(ae_unittest) unittest
{
	assert(rfc1459toLower("{}|[]\\") == "{}|{}|");
	assert(rfc1459toUpper("{}|[]\\") == "[]\\[]\\");
}

/// Like `icmp`, but honoring RFC1459 case mapping rules.
int rfc1459cmp(in char[] a, in char[] b)
{
	return cmp(a.byChar.map!rfc1459toUpper, b.byChar.map!rfc1459toUpper);
}

debug(ae_unittest) unittest
{
	assert(rfc1459cmp("{}|[]\\", "[]\\[]\\") == 0);
	assert(rfc1459cmp("a", "b") == -1);
}

/// Base class for an IRC client-server connection.
final class IrcConnection
{
private:
	LineBufferedAdapter line;
	TimeoutAdapter timer;

public:
	IConnection conn; /// Underlying transport.

	this(IConnection c, size_t maxLineLength = 512)
	{
		c = line = new LineBufferedAdapter(c);
		line.delimiter = "\n";
		line.maxLength = maxLineLength;

		c = timer = new TimeoutAdapter(c);
		timer.setIdleTimeout(90.seconds);
		timer.handleIdleTimeout = &onIdleTimeout;
		timer.handleNonIdle = &onNonIdle;

		conn = c;
		conn.handleReadData = &onReadData;
	} ///

	/// Send `line`, plus a newline.
	void send(string line)
	{
		debug(IRC) stderr.writeln("> ", line);
		// Send with \r\n, but support receiving with \n
		import ae.sys.data;
		conn.send(Data(line.asBytes ~ "\r\n".asBytes));
	}

	/// Inactivity handler (for sending a `PING` request).
	void delegate() handleInactivity;

	/// Timeout handler - called if `handleInactivity` was null or did not result in activity.
	void delegate() handleTimeout;

	/// Data handler.
	void delegate(string line) handleReadLine;

	/// Forwards to the underlying transport.
	@property void handleConnect(IConnection.ConnectHandler value) { conn.handleConnect = value; }
	@property void handleDisconnect(IConnection.DisconnectHandler value) { conn.handleDisconnect = value; } /// ditto
	void disconnect(string reason = IConnection.defaultDisconnectReason, DisconnectType type = DisconnectType.requested) { conn.disconnect(reason, type); } /// ditto
	@property ConnectionState state() { return conn.state; } /// ditto

private:
	void onNonIdle()
	{
		if (pingSent)
			pingSent = false;
	}

	void onReadData(Data data)
	{
		string line = data.asDataOf!char.toGC().chomp("\r");
		debug(IRC) stderr.writeln("< ", line);

		if (handleReadLine)
			handleReadLine(line);
	}

	void onIdleTimeout()
	{
		if (pingSent || handleInactivity is null || conn.state != ConnectionState.connected)
		{
			if (handleTimeout)
				handleTimeout();
			else
				conn.disconnect("Time-out", DisconnectType.error);
		}
		else
		{
			handleInactivity();
			pingSent = true;
		}
	}

	bool pingSent;
}

// TODO: this is server-specific
deprecated const string IRC_NICK_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-`";
deprecated const string IRC_USER_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
deprecated const string IRC_HOST_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.";

/// Numeric IRC replies.
enum Reply
{
	RPL_WELCOME             = 001,  ///
	RPL_YOURHOST            = 002,  ///
	RPL_CREATED             = 003,  ///
	RPL_MYINFO              = 004,  ///
	RPL_BOUNCE              = 005,  ///
	RPL_TRACELINK           = 200,  ///
	RPL_TRACECONNECTING     = 201,  ///
	RPL_TRACEHANDSHAKE      = 202,  ///
	RPL_TRACEUNKNOWN        = 203,  ///
	RPL_TRACEOPERATOR       = 204,  ///
	RPL_TRACEUSER           = 205,  ///
	RPL_TRACESERVER         = 206,  ///
	RPL_TRACESERVICE        = 207,  ///
	RPL_TRACENEWTYPE        = 208,  ///
	RPL_TRACECLASS          = 209,  ///
	RPL_TRACERECONNECT      = 210,  ///
	RPL_STATSLINKINFO       = 211,  ///
	RPL_STATSCOMMANDS       = 212,  ///
	RPL_STATSCLINE          = 213,  ///
	RPL_STATSNLINE          = 214,  ///
	RPL_STATSILINE          = 215,  ///
	RPL_STATSKLINE          = 216,  ///
	RPL_STATSQLINE          = 217,  ///
	RPL_STATSYLINE          = 218,  ///
	RPL_ENDOFSTATS          = 219,  ///
	RPL_UMODEIS             = 221,  ///
	RPL_SERVICEINFO         = 231,  ///
	RPL_ENDOFSERVICES       = 232,  ///
	RPL_SERVICE             = 233,  ///
	RPL_SERVLIST            = 234,  ///
	RPL_SERVLISTEND         = 235,  ///
	RPL_STATSVLINE          = 240,  ///
	RPL_STATSLLINE          = 241,  ///
	RPL_STATSUPTIME         = 242,  ///
	RPL_STATSOLINE          = 243,  ///
	RPL_STATSHLINE          = 244,  ///
	RPL_STATSSLINE          = 244,  ///
	RPL_STATSPING           = 246,  ///
	RPL_STATSBLINE          = 247,  ///
	RPL_STATSDLINE          = 250,  ///
	RPL_LUSERCLIENT         = 251,  ///
	RPL_LUSEROP             = 252,  ///
	RPL_LUSERUNKNOWN        = 253,  ///
	RPL_LUSERCHANNELS       = 254,  ///
	RPL_LUSERME             = 255,  ///
	RPL_ADMINME             = 256,  ///
	RPL_ADMINLOC1           = 257,  ///
	RPL_ADMINLOC2           = 258,  ///
	RPL_ADMINEMAIL          = 259,  ///
	RPL_TRACELOG            = 261,  ///
	RPL_TRACEEND            = 262,  ///
	RPL_TRYAGAIN            = 263,  ///
	RPL_NONE                = 300,  ///
	RPL_AWAY                = 301,  ///
	RPL_USERHOST            = 302,  ///
	RPL_ISON                = 303,  ///
	RPL_UNAWAY              = 305,  ///
	RPL_NOWAWAY             = 306,  ///
	RPL_WHOISUSER           = 311,  ///
	RPL_WHOISSERVER         = 312,  ///
	RPL_WHOISOPERATOR       = 313,  ///
	RPL_WHOWASUSER          = 314,  ///
	RPL_ENDOFWHO            = 315,  ///
	RPL_WHOISCHANOP         = 316,  ///
	RPL_WHOISIDLE           = 317,  ///
	RPL_ENDOFWHOIS          = 318,  ///
	RPL_WHOISCHANNELS       = 319,  ///
	RPL_LISTSTART           = 321,  ///
	RPL_LIST                = 322,  ///
	RPL_LISTEND             = 323,  ///
	RPL_CHANNELMODEIS       = 324,  ///
	RPL_UNIQOPIS            = 325,  ///
	RPL_NOTOPIC             = 331,  ///
	RPL_TOPIC               = 332,  ///
	RPL_INVITING            = 341,  ///
	RPL_SUMMONING           = 342,  ///
	RPL_INVITELIST          = 346,  ///
	RPL_ENDOFINVITELIST     = 347,  ///
	RPL_EXCEPTLIST          = 348,  ///
	RPL_ENDOFEXCEPTLIST     = 349,  ///
	RPL_VERSION             = 351,  ///
	RPL_WHOREPLY            = 352,  ///
	RPL_NAMREPLY            = 353,  ///
	RPL_KILLDONE            = 361,  ///
	RPL_CLOSING             = 362,  ///
	RPL_CLOSEEND            = 363,  ///
	RPL_LINKS               = 364,  ///
	RPL_ENDOFLINKS          = 365,  ///
	RPL_ENDOFNAMES          = 366,  ///
	RPL_BANLIST             = 367,  ///
	RPL_ENDOFBANLIST        = 368,  ///
	RPL_ENDOFWHOWAS         = 369,  ///
	RPL_INFO                = 371,  ///
	RPL_MOTD                = 372,  ///
	RPL_INFOSTART           = 373,  ///
	RPL_ENDOFINFO           = 374,  ///
	RPL_MOTDSTART           = 375,  ///
	RPL_ENDOFMOTD           = 376,  ///
	RPL_YOUREOPER           = 381,  ///
	RPL_REHASHING           = 382,  ///
	RPL_YOURESERVICE        = 383,  ///
	RPL_MYPORTIS            = 384,  ///
	RPL_TIME                = 391,  ///
	RPL_USERSSTART          = 392,  ///
	RPL_USERS               = 393,  ///
	RPL_ENDOFUSERS          = 394,  ///
	RPL_NOUSERS             = 395,  ///
	ERR_NOSUCHNICK          = 401,  ///
	ERR_NOSUCHSERVER        = 402,  ///
	ERR_NOSUCHCHANNEL       = 403,  ///
	ERR_CANNOTSENDTOCHAN    = 404,  ///
	ERR_TOOMANYCHANNELS     = 405,  ///
	ERR_WASNOSUCHNICK       = 406,  ///
	ERR_TOOMANYTARGETS      = 407,  ///
	ERR_NOSUCHSERVICE       = 408,  ///
	ERR_NOORIGIN            = 409,  ///
	ERR_NORECIPIENT         = 411,  ///
	ERR_NOTEXTTOSEND        = 412,  ///
	ERR_NOTOPLEVEL          = 413,  ///
	ERR_WILDTOPLEVEL        = 414,  ///
	ERR_BADMASK             = 415,  ///
	ERR_UNKNOWNCOMMAND      = 421,  ///
	ERR_NOMOTD              = 422,  ///
	ERR_NOADMININFO         = 423,  ///
	ERR_FILEERROR           = 424,  ///
	ERR_NONICKNAMEGIVEN     = 431,  ///
	ERR_ERRONEUSNICKNAME    = 432,  ///
	ERR_NICKNAMEINUSE       = 433,  ///
	ERR_NICKCOLLISION       = 436,  ///
	ERR_UNAVAILRESOURCE     = 437,  ///
	ERR_USERNOTINCHANNEL    = 441,  ///
	ERR_NOTONCHANNEL        = 442,  ///
	ERR_USERONCHANNEL       = 443,  ///
	ERR_NOLOGIN             = 444,  ///
	ERR_SUMMONDISABLED      = 445,  ///
	ERR_USERSDISABLED       = 446,  ///
	ERR_NOTREGISTERED       = 451,  ///
	ERR_NEEDMOREPARAMS      = 461,  ///
	ERR_ALREADYREGISTRED    = 462,  ///
	ERR_NOPERMFORHOST       = 463,  ///
	ERR_PASSWDMISMATCH      = 464,  ///
	ERR_YOUREBANNEDCREEP    = 465,  ///
	ERR_YOUWILLBEBANNED     = 466,  ///
	ERR_KEYSET              = 467,  ///
	ERR_CHANNELISFULL       = 471,  ///
	ERR_UNKNOWNMODE         = 472,  ///
	ERR_INVITEONLYCHAN      = 473,  ///
	ERR_BANNEDFROMCHAN      = 474,  ///
	ERR_BADCHANNELKEY       = 475,  ///
	ERR_BADCHANMASK         = 476,  ///
	ERR_NOCHANMODES         = 477,  ///
	ERR_BANLISTFULL         = 478,  ///
	ERR_NOPRIVILEGES        = 481,  ///
	ERR_CHANOPRIVSNEEDED    = 482,  ///
	ERR_CANTKILLSERVER      = 483,  ///
	ERR_RESTRICTED          = 484,  ///
	ERR_UNIQOPPRIVSNEEDED   = 485,  ///
	ERR_NOOPERHOST          = 491,  ///
	ERR_NOSERVICEHOST       = 492,  ///
	ERR_UMODEUNKNOWNFLAG    = 501,  ///
	ERR_USERSDONTMATCH      = 502,  ///
}
