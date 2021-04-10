﻿/**
 * A simple IRC client.
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

module ae.net.irc.client;

import std.conv;
import std.datetime;
import std.exception;
import std.random;
import std.string;

import ae.net.asockets;
import ae.sys.log;
import ae.utils.text;

public import ae.net.irc.common;

/// An IRC client class.
class IrcClient
{
private:
	/// The socket this class wraps.
	IrcConnection conn;
	/// Whether the socket is connected
	bool _connected;

	/// Helper function for sending a command.
	void command(string command, string[] params ...)
	{
		assert(command.length > 1);
		string message = toUpper(command);

		while ((params.length > 1) && (params[$-1]==null || params[$-1]==""))
			params.length = params.length-1;

		assert(params.length <= 15);

		foreach (i, parameter; params)
		{
			message ~= " ";
			if (parameter.indexOf(" ") != -1 || !parameter.length || parameter.startsWith(":"))
			{
				assert(i == params.length-1, "Malformed non-terminal parameter: " ~ parameter);
				message ~= ":";
			}
			message ~= parameter;
		}

		sendRaw(message);
	}

	/// Called when a connection has been established.
	void onConnect()
	{
		if (log) log("* Connected.");
		if (password.length > 0)
		{
			// Use sendRaw for hacked-up finicky IRC servers (WormNET)
			sendRaw("PASS " ~ password);
		}
		currentNickname = connectNickname;
		command("NICK", currentNickname);
		command("USER", username ? username : currentNickname, "hostname", "servername", realname);
	}

	/// Called when a connection was closed.
	void onDisconnect(string reason, DisconnectType type)
	{
		if (log) log(format("* Disconnected (%s)", reason));
		currentNickname = null;
		_connected = false;
		if (handleDisconnect)
			handleDisconnect(reason, type);
		channels = null;
		users = null;
		canonicalChannelNames = canonicalUserNames = null;
	}

	/// Remove the @+ etc. prefix from a nickname
	string removePrefix(string nick)
	{
		// TODO: do this properly, maybe?
		if (nick[0]=='@' || nick[0]=='+')
			return nick[1..$];
		else
			return nick;
	}

	/// Called when a line has been received.
	void onReadLine(string line)
	{
		line = decoder(line);
		if (handleRaw)
		{
			handleRaw(line);
			if (line is null)
				return;
		}
		if (log) log("< " ~ line);
		string nick, username, hostname;
		if (line.startsWith(":"))
		{
			auto space = line.indexOf(' ');
			string target = line[1 .. space];
			parseTarget(target, nick, username, hostname);
			//std.stdio.writefln("%s => %s!%s@%s", target, nick, username, hostname);
			nick = canonicalUserName(nick);
			auto userptr = nick in users;
			if (userptr)
			{
				userptr.username = username;
				userptr.hostname = hostname;
			}
			line = line[space + 1 .. line.length];
		}

		string[] params;
		auto colon = line.indexOf(" :");
		if (colon == -1)
			params = split(line);
		else
		{
			params = split(line[0 .. colon]);
			params ~= line[colon + 2 .. line.length];
		}

		string command = toUpper(params[0]);
		params = params[1 .. params.length];

		// Whenever D supports this, turn this into a
		// constant associative array of anonymous functions.
		// VP 2006.12.16: for now, moving functions inside the switch, because the code is too cumbersome to read and maintain with each handler in a separate function
		switch (command)
		{
		case "001":     // login successful
			// VP 2006.12.13: changing 376 to 001, since 376 doesn't appear on all servers and it's safe to send commands after 001 anyway
			_connected = true;
			onEnter(currentNickname, username, hostname, realname); // add ourselves

			if (handleConnect)
				handleConnect();
			if (autoWho)
				who();  // get info on all users
			break;

		case "433":     // nickname in use
			if (exactNickname)
				disconnect("Nickname in use", DisconnectType.error);
			else
			{
				currentNickname = "%s%03d".format(connectNickname, uniform(0, 1000));
				this.command("NICK", currentNickname);
			}
			break;

		case "321":     // LIST channel start
			channelList = null; // clear list
			break;

		case "322":     // LIST channel line
			channelList ~= params[1];
			break;

		case "323":     // LIST channel end
			if (handleChannelList)
				handleChannelList(channelList);
			break;

		case "353":     // NAMES line
			string channel = canonicalChannelName(params[$-2]);
			assert(channel in channels);
			string[] nicks = params[$-1].split(" ");
			foreach (fullnick; nicks)
				if (fullnick.length>0)
				{
					auto nickname = removePrefix(fullnick);
					if (!(nickname in users))
						onEnter(nickname, null, null);
					else
						users[nickname].channelsJoined++;
					channels[channel].users[nickname] = true;
				}
			break;

		case "366":     // NAMES end
			// VP 2007.01.07: perhaps the onJoin handler code for when we join a channel ought to be moved here...
			break;

		case "352":     // WHO line
			//                          0           1 2        3                                  4                   5           6 7
			// :wormnet1.team17.com 352 CyberShadow * Username host-86-106-217-211.moldtelecom.md wormnet1.team17.com CyberShadow H :0 40 0 RO
			//void delegate(string channel, string username, string host, string server, string name, string flags, string userinfo) handleWho;
			while (params.length<8)
				params ~= [null];

			string[] gecos = params[7].split(" ");
			int hopcount = 0;
			try
				hopcount = to!int(gecos[0]);
			catch (Exception e)
				hopcount = 0;
			if (gecos.length > 1)
				gecos = gecos[1..$];
			else
				gecos = null;

			string nickname = params[5];
			username = params[2];
			hostname = params[3];
			auto userptr = nickname in users;
			if (userptr)
			{
				if (userptr.username is null)
					userptr.username = username;
				else
					assert(userptr.username == username, userptr.username ~ " != " ~ username);
				if (userptr.hostname is null)
					userptr.hostname = hostname;
				//else
				//	assert(userptr.hostname == hostname, userptr.hostname ~ " != " ~ hostname);
				string realname = std.string.join(gecos, " ");
				if (userptr.realname is null)
					userptr.realname = realname;
				else
					assert(userptr.realname == realname);
			}

			if (handleWho)
				handleWho(params[1], params[2], params[3], params[4], params[5], params[6], hopcount, std.string.join(gecos, " "));
			break;

		case "315":     // WHO end
			if (handleWhoEnd)
				handleWhoEnd(params.length>=2 ? params[1] : null);
			break;

		case "437":     // Nick/channel is temporarily unavailable
			if (handleUnavailable)
				handleUnavailable(params[1], params[2]);
			break;

		case "471":     // Channel full
			if (handleChannelFull)
				handleChannelFull(params[1], params[2]);
			break;

		case "473":     // Invite only
			if (handleInviteOnly)
				handleInviteOnly(params[1], params[2]);
			break;

		case "474":     // Banned
			if (handleBanned)
				handleBanned(params[1], params[2]);
			break;

		case "475":     // Wrong key
			if (handleChannelKey)
				handleChannelKey(params[1], params[2]);
			break;

		case "PING":
			if (params.length == 1)
				this.command("PONG", params[0]);
			break;

		case "PRIVMSG":
			if (params.length != 2)
				return;

			string target = canonicalName(params[0]);
			IrcMessageType type = IrcMessageType.NORMAL;
			string text = params[1];
			if (text.startsWith("\x01ACTION"))
			{
				type = IrcMessageType.ACTION;
				text = text[7 .. $];
				if (text.startsWith(" "))
					text = text[1..$];
				if (text.endsWith("\x01"))
					text = text[0..$-1];
			}
			onMessage(nick, target, text, type);
			break;

		case "NOTICE":
			if (params.length != 2)
				return;

			string target = canonicalName(params[0]);
			onMessage(nick, target, params[1], IrcMessageType.NOTICE);
			break;

		case "JOIN":
			if (params.length != 1)
				return;

			string channel = canonicalChannelName(params[0]);

			if (!(nick in users))
			{
				onEnter(nick, username, hostname);
				if (autoWho)
					who(nick);
			}
			else
				users[nick].channelsJoined++;

			if (nick == currentNickname)
			{
				assert(!(channel in channels));
				channels[channel] = Channel();
				if (autoWho)
					who(channel);
			}
			else
			{
				assert(channel in channels);
				channels[channel].users[nick] = true;
			}

			if (handleJoin)
				handleJoin(channel, nick);

			break;

		case "PART":
			if (params.length < 1 || params.length > 2)
				return;

			string channel = canonicalChannelName(params[0]);

			if (handlePart)
				handlePart(channel, nick, params.length == 2 ? params[1] : null);

			onUserParted(nick, channel);
			break;

		case "QUIT":
			string[] oldChannels;
			foreach (channelName, channel; channels)
				if (nick in channel.users)
					oldChannels ~= channelName;

			if (handleQuit)
				handleQuit(nick, params.length == 1 ? params[0] : null, oldChannels);

			foreach (channel; channels)
				if (nick in channel.users)
					channel.users.remove(nick);

			onLeave(nick);
			break;

		case "KICK":
			if (params.length < 2 || params.length > 3)
				return;

			string channel = canonicalChannelName(params[0]);

			string user = canonicalUserName(params[1]);
			if (handleKick)
			{
				if (params.length == 3)
					handleKick(channel, user, nick, params[2]);
				else
					handleKick(channel, user, nick, null);
			}

			onUserParted(user, channel);
			break;

		case "NICK":
			if (params.length != 1)
				return;

			onNick(nick, params[0]);
			break;

		case "INVITE":
			if (params.length != 2)
				return;

			if (handleInvite)
				handleInvite(params[0], params[1]);
			break;

		default:
			break;
		}
	}

	void onUserParted(string nick, string channel)
	{
		assert(channel in channels);
		if (nick == currentNickname)
		{
			foreach (user, b; channels[channel].users)
				users[user].channelsJoined--;
			purgeUsers();
			channels.remove(channel);
		}
		else
		{
			channels[channel].users.remove(nick);
			users[nick].channelsJoined--;
			if (users[nick].channelsJoined==0)
				onLeave(nick);
		}
	}

	/// Remove users that aren't in any channels
	void purgeUsers()
	{
		throw new Exception("not implemented");
	}

	void parseTarget(string target, out string nickname, out string username, out string hostname)
	{
		username = hostname = null;
		auto userdelimpos = target.indexOf('!');
		if (userdelimpos == -1)
			nickname = target;
		else
		{
			nickname = target[0 .. userdelimpos];

			auto hostdelimpos = target.indexOf('@');
			if (hostdelimpos == -1)
				assert(0);
			else
			{
				//bool identified = target[userdelimpos + 1] != '~';
				//if (!identified)
				//	userdelimpos++;

				username = target[userdelimpos + 1 .. hostdelimpos];
				hostname = target[hostdelimpos + 1 .. target.length];

				//if (hostname == "no.address.for.you") // WormNET hack
				//	hostname = null;
			}
		}
	}

	void onSocketInactivity()
	{
		command("PING", to!string(Clock.currTime().toUnixTime()));
	}

	void onSocketTimeout()
	{
		disconnect("Time-out", DisconnectType.error);
	}

protected: // overridable methods
	void onEnter(string nick, string username, string hostname, string realname = null)
	{
		users[nick] = User(1, username, hostname, realname);
		canonicalUserNames[rfc1459toLower(nick)] = nick;
		if (handleEnter)
			handleEnter(nick);
	}

	void onLeave(string nick)
	{
		users.remove(nick);
		canonicalUserNames.remove(rfc1459toLower(nick));
		if (handleLeave)
			handleLeave(nick);
	}

	void onNick(string oldNick, string newNick)
	{
		users[newNick] = users[oldNick];
		users.remove(oldNick);
		canonicalUserNames.remove(rfc1459toLower(oldNick));
		canonicalUserNames[rfc1459toLower(newNick)] = newNick;

		foreach (ref channel; channels)
			if (oldNick in channel.users)
			{
				channel.users[newNick] = channel.users[oldNick];
				channel.users.remove(oldNick);
			}
	}

	void onMessage(string from, string to, string message, IrcMessageType type)
	{
		if (handleMessage)
			handleMessage(from, to, message, type);
	}

public:
	/// The nickname to identify with.
	string connectNickname;
	/// Fail to connect if the specified nickname is taken.
	bool exactNickname;
	/// The nickname we are logged in with.
	/// May be different from connectNickname if
	/// exactNickname is false.
	string currentNickname;
	/// Refers to currentNickname when connected, connectNickname otherwise.
	@property ref string nickname() { return connected ? currentNickname : connectNickname; }

	/// The user's information.
	string realname;
	/// The password used when logging in.
	string password;
	/// Username field (shown before the @ in the hostmask).
	/// If not set, defaults to the nickname.
	string username;
	/// A list of joined channels.
	Channel[string] channels;
	/// Canonical names
	string[string] canonicalChannelNames, canonicalUserNames;
	/// Known user info
	User[string] users;
	/// Channel list for LIST command
	string[] channelList;

	/// Whether to automatically send WHO requests
	bool autoWho;
	/// Log all input/output to this logger.
	Logger log;
	/// How to convert the IRC 8-bit data to and from UTF-8 (D strings must be valid UTF-8).
	string function(in char[]) decoder = &rawToUTF8, encoder = &UTF8ToRaw;

	/// An IRC channel.
	struct Channel
	{
		/// Visible users in this channel.
		bool[string] users;
	}

	/// A user that we know of.
	struct User
	{
		/// Number of channels that we can see the user in.
		int channelsJoined; // acts as a reference count
		/// User information.
		string username, hostname, realname;
	}

	/// Get a channel's canonical name,
	/// using the observed name if known.
	string canonicalChannelName(string channel)
	{
		string channelLower = rfc1459toLower(channel);
		if (channelLower in canonicalChannelNames)
			return canonicalChannelNames[channelLower];
		else
		{
			canonicalChannelNames[channelLower] = channel; // for consistency!
			return channel;
		}
	}

	/// Get a user's canonical name,
	/// using the observed name if known.
	string canonicalUserName(string user)
	{
		string userLower = rfc1459toLower(user);
		if (userLower in canonicalUserNames)
			return canonicalUserNames[userLower];
		else
			return user;
	}

	/// Get a user or channel's canonical name,
	/// using the observed name if known.
	string canonicalName(string name)
	{
		string nameLower = rfc1459toLower(name);
		if (name[0]=='#')
			if (nameLower in canonicalChannelNames)
				return canonicalChannelNames[nameLower];
			else
				return name;
		else
			if (nameLower in canonicalUserNames)
				return canonicalUserNames[nameLower];
			else
				return name;
	}

	/// Get the list of channels that we can see a user in.
	string[] getUserChannels(string name)
	{
		string[] result;
		foreach (channelName, ref channel; channels)
			if (name in channel.users)
				result ~= channelName;
		return result;
	}

	this(IConnection c)
	{
		conn = new IrcConnection(c);
		conn.handleConnect = &onConnect;
		conn.handleDisconnect = &onDisconnect;
		conn.handleReadLine = &onReadLine;
		conn.handleInactivity = &onSocketInactivity;
		conn.handleTimeout = &onSocketTimeout;
	} ///

	/// Returns true if the connection was successfully established,
	/// and we have authorized ourselves to the server
	/// (and can thus join channels, send private messages, etc.)
	@property bool connected() { return _connected; }

	/// Cancel a connection.
	void disconnect(string reason = null, DisconnectType type = DisconnectType.requested)
	{
		if (conn.state == ConnectionState.connected && reason)
			command("QUIT", reason);
		conn.disconnect(reason, type);
	}

	/// Send raw string to server.
	void sendRaw(in char[] message)
	{
		enforce(!message.contains("\n"), "Newline in outgoing IRC line: " ~ message);
		if (log) log("> " ~ message);
		conn.send(encoder(message));
	}

	/// Join a channel on the network.
	void join(string channel, string password=null)
	{
		assert(connected);

		canonicalChannelNames[rfc1459toLower(channel)] = channel;
		if (password.length)
			command("JOIN", channel, password);
		else
			command("JOIN", channel);
	}

	/// Get a list of channels on the server
	void requestChannelList()
	{
		assert(connected);

		channelList = null;  // clear channel list
		command("LIST");
	}

	/// Get a list of logged on users
	void who(string mask=null)
	{
		command("WHO", mask);
	}

	/// Send a regular message to the target.
	void message(string name, string text)
	{
		command("PRIVMSG", name, text);
	}

	/// Perform an action for the target.
	void action(string name, string text)
	{
		command("PRIVMSG", name, "\x01" ~ "ACTION " ~ text ~ "\x01");
	}

	/// Send a notice to the target.
	void notice(string name, string text)
	{
		command("NOTICE", name, text);
	}

	/// Get/set IRC mode
	void mode(string[] params ...)
	{
		command("MODE", params);
	}

	/// Callback for received data before it's processed.
	void delegate(ref string s) handleRaw;

	/// Callback for when we have succesfully logged in.
	void delegate() handleConnect;
	/// Callback for when the socket was closed.
	void delegate(string reason, DisconnectType type) handleDisconnect;
	/// Callback for when a message has been received.
	void delegate(string from, string to, string message, IrcMessageType type) handleMessage;
	/// Callback for when someone has joined a channel.
	void delegate(string channel, string nick) handleJoin;
	/// Callback for when someone has left a channel.
	void delegate(string channel, string nick, string reason) handlePart;
	/// Callback for when someone was kicked from a channel.
	void delegate(string channel, string nick, string op, string reason) handleKick;
	/// Callback for when someone has quit from the network.
	void delegate(string nick, string reason, string[] channels) handleQuit;
	/// Callback for an INVITE command.
	void delegate(string nick, string channel) handleInvite;
	/// Callback for when the channel list was retreived
	void delegate(string[] channelList) handleChannelList;
	/// Callback for a WHO result line
	void delegate(string channel, string username, string host, string server, string name, string flags, int hopcount, string realname) handleWho;
	/// Callback for a WHO listing end
	void delegate(string mask) handleWhoEnd;

	/// Callback for when we're banned from a channel.
	void delegate(string channel, string reason) handleBanned;
	/// Callback for when a channel is invite only.
	void delegate(string channel, string reason) handleInviteOnly;
	/// Callback for when a nick/channel is unavailable.
	void delegate(string what, string reason) handleUnavailable;
	/// Callback for when a channel is full.
	void delegate(string channel, string reason) handleChannelFull;
	/// Callback for when a channel needs a key.
	void delegate(string channel, string reason) handleChannelKey;

	/// Callback for when a user enters our sight.
	void delegate(string nick) handleEnter;
	/// Callback for when a user leaves our sight.
	void delegate(string nick) handleLeave;
}
