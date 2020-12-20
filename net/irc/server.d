/**
 * A simple IRC server.
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

module ae.net.irc.server;

import std.algorithm;
import std.conv;
import std.datetime;
import std.exception;
import std.range;
import std.regex;
import std.socket;
import std.string;

import ae.net.asockets;
import ae.utils.array;
import ae.sys.log;
import ae.utils.exception;
import ae.utils.meta;
import ae.utils.text;

import ae.net.irc.common;

alias std.string.indexOf indexOf;

class IrcServer
{
	// This class is currently intentionally written for readability, not performance.
	// Performance and scalability could be greatly improved by using numeric indices for users and channels
	// instead of associative arrays.

	/// Server configuration
	string hostname, password, network;
	string nicknameValidationPattern = "^[a-zA-Z][a-zA-Z0-9\\-`\\|\\[\\]\\{\\}_^]{0,14}$";
	uint nicknameMaxLength = 15; /// For the announced capabilities
	string serverVersion = "ae.net.irc.server";
	string[] motd;
	string chanTypes = "#&";
	SysTime creationTime;
	string operPassword;

	/// Channels can't be created by users, and don't disappear when they're empty
	bool staticChannels;
	/// If set, masks all IPs to the given mask
	string addressMask;

	Logger log;

	/// Client connection and information
	abstract static class Client
	{
		/// How to convert the IRC 8-bit data to and from UTF-8 (D strings must be valid UTF-8).
		string function(in char[]) decoder = &rawToUTF8, encoder = &UTF8ToRaw;

		/// Registration details
		string nickname, password;
		string username, hostname, servername, realname;
		bool identified;
		string prefix, publicPrefix; /// Full nick!user@host
		string away;

		bool registered;
		Modes modes;
		MonoTime lastActivity;

		Channel[] getJoinedChannels()
		{
			Channel[] result;
			foreach (channel; server.channels)
				if (nickname.normalized in channel.members)
					result ~= channel;
			return result;
		}

		string realHostname() { return remoteAddress.toAddrString; }
		string publicHostname() { return server.addressMask ? server.addressMask : realHostname; }
		bool realHostnameVisibleTo(Client viewer)
		{
			return server.addressMask is null
				|| viewer is this
				|| viewer.modes.flags['o']; // Oper
		}
		string hostnameAsVisibleTo(Client viewer) { return realHostnameVisibleTo(viewer) ? realHostname : publicHostname; }
		string prefixAsVisibleTo(Client viewer) { return realHostnameVisibleTo(viewer) ? prefix : publicPrefix; }

	protected:
		IrcServer server;
		Address remoteAddress;

		this(IrcServer server, Address remoteAddress)
		{
			this.server = server;
			lastActivity = MonoTime.currTime;
			server.clients.add(this);

			this.remoteAddress = remoteAddress;

			server.log("New IRC connection from " ~ remoteAddress.toString);
		}

		void onReadLine(string line)
		{
			try
			{
				if (decoder) line = decoder(line);

				if (!connConnected())
					return; // A previous line in the same buffer caused a disconnect

				enforce(line.indexOf('\0')<0 && line.indexOf('\r')<0 && line.indexOf('\n')<0, "Forbidden character");

				auto parameters = line.ircSplit();
				if (!parameters.length)
					return;

				auto command = parameters.shift.toUpper();
				onCommand(command, parameters);
			}
			catch (CaughtException e)
			{
				if (connConnected())
					disconnect(e.msg);
			}
		}

		void onCommand(string command, scope string[] parameters...)
		{
			switch (command)
			{
				case "PASS":
					if (registered)
						return sendReply(Reply.ERR_ALREADYREGISTRED, "You may not reregister");
					if (parameters.length != 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					password = parameters[0];
					break;
				case "NICK":
					if (parameters.length != 1)
						return sendReply(Reply.ERR_NONICKNAMEGIVEN, "No nickname given");
					if (!registered)
					{
						nickname = parameters[0];
						checkRegistration();
					}
					else
					{
						auto newNick = parameters[0];
						if (!newNick.match(server.nicknameValidationPattern))
							return sendReply(Reply.ERR_ERRONEUSNICKNAME, newNick, "Erroneous nickname");
						if (newNick.normalized in server.nicknames)
						{
							if (newNick.normalized != nickname.normalized)
								sendReply(Reply.ERR_NICKNAMEINUSE, newNick, "Nickname is already in use");
							return;
						}

						changeNick(newNick);
					}
					break;
				case "USER":
					if (registered)
						return sendReply(Reply.ERR_ALREADYREGISTRED, "You may not reregister");
					if (parameters.length != 4)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					username   = parameters[0];
					hostname   = parameters[1];
					servername = parameters[2];
					realname   = parameters[3];
					checkRegistration();
					break;

				case "PING":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered"); // KVIrc needs this.
					sendReply("PONG", parameters);
					break;
				case "PONG":
					break;
				case "QUIT":
					if (parameters.length)
						disconnect("Quit: " ~ parameters[0]);
					else
						disconnect("Quit");
					break;
				case "JOIN":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					string[] keys = parameters.length > 1 ? parameters[1].split(",") : null;
					foreach (i, channame; parameters[0].split(","))
					{
						auto key = i < keys.length ? keys[i] : null;
						if (!server.isChannelName(channame))
							{ sendReply(Reply.ERR_NOSUCHCHANNEL, channame, "No such channel"); continue; }
						auto normchan = channame.normalized;
						if (!mayJoin(normchan))
							continue;
						auto pchannel = normchan in server.channels;
						Channel channel;
						if (pchannel)
							channel = *pchannel;
						else
						{
							if (server.staticChannels)
								{ sendReply(Reply.ERR_NOSUCHCHANNEL, channame, "No such channel"); continue; }
							else
								channel = server.createChannel(channame);
						}
						if (nickname.normalized in channel.members)
							continue; // already on channel
						if (channel.modes.strings['k'] && channel.modes.strings['k'] != key)
							{ sendReply(Reply.ERR_BADCHANNELKEY, channame, "Cannot join channel (+k)"); continue; }
						if (channel.modes.masks['b'].any!(mask => prefix.maskMatch(mask)))
							{ sendReply(Reply.ERR_BANNEDFROMCHAN, channame, "Cannot join channel (+b)"); continue; }
						join(channel);
					}
					lastActivity = MonoTime.currTime;
					break;
				case "PART":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 1) // TODO: part reason
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					string reason = parameters.length < 2 ? null : parameters[1];
					foreach (channame; parameters[0].split(","))
					{
						auto pchan = channame.normalized in server.channels;
						if (!pchan)
							{ sendReply(Reply.ERR_NOSUCHCHANNEL, channame, "No such channel"); continue; }
						auto chan = *pchan;
						if (nickname.normalized !in chan.members)
							{ sendReply(Reply.ERR_NOTONCHANNEL, channame, "You're not on that channel"); continue; }
						part(chan, reason);
					}
					lastActivity = MonoTime.currTime;
					break;
				case "MODE":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					auto target = parameters.shift;
					if (server.isChannelName(target))
					{
						auto pchannel = target.normalized in server.channels;
						if (!pchannel)
							return sendReply(Reply.ERR_NOSUCHNICK, target, "No such nick/channel");
						auto channel = *pchannel;
						auto pmember = nickname.normalized in channel.members;
						if (!pmember)
							return sendReply(Reply.ERR_NOTONCHANNEL, target, "You're not on that channel");
						if (!parameters.length)
							return sendChannelModes(channel);
						return setChannelModes(channel, parameters);
					}
					else
					{
						auto pclient = target.normalized in server.nicknames;
						if (!pclient)
							return sendReply(Reply.ERR_NOSUCHNICK, target, "No such nick/channel");
						auto client = *pclient;
						if (parameters.length)
						{
							if (client !is this)
								return sendReply(Reply.ERR_USERSDONTMATCH, "Cannot change mode for other users");
							return setUserModes(parameters);
						}
						else
							return sendUserModes(client);
					}
				case "LIST":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					foreach (channel; getChannelList())
						if (!(channel.modes.flags['p'] || channel.modes.flags['s']) || nickname.normalized in channel.members)
							sendReply(Reply.RPL_LIST, channel.name, channel.members.length.text, channel.topic ? channel.topic : "");
					sendReply(Reply.RPL_LISTEND, "End of LIST");
					break;
				case "MOTD":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					sendMotd();
					break;
				case "NAMES":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					foreach (channame; parameters[0].split(","))
					{
						auto pchan = channame.normalized in server.channels;
						if (!pchan)
							{ sendReply(Reply.ERR_NOSUCHCHANNEL, channame, "No such channel"); continue; }
						auto channel = *pchan;
						auto pmember = nickname.normalized in channel.members;
						if (!pmember)
							{ sendReply(Reply.ERR_NOTONCHANNEL, channame, "You're not on that channel"); continue; }
						sendNames(channel);
					}
					break;
				case "WHO":
				{
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					auto mask = parameters.length ? parameters[0].among("", "*", "0") ? null : parameters[0] : null;
					string[string] result;
					foreach (channel; server.channels)
					{
						auto inChannel = nickname.normalized in channel.members;
						if (!inChannel && channel.modes.flags['s'])
							continue;
						foreach (member; channel.members)
							if (inChannel || !member.client.modes.flags['i'])
								if (!mask || channel.name.maskMatch(mask) || member.client.nickname.maskMatch(mask) || member.client.hostnameAsVisibleTo(this).maskMatch(mask))
								{
									auto phit = member.client.nickname in result;
									if (phit)
										*phit = "*";
									else
										result[member.client.nickname] = channel.name;
								}
					}

					foreach (client; server.nicknames)
						if (!client.modes.flags['i'])
							if (!mask || client.nickname.maskMatch(mask) || client.hostnameAsVisibleTo(this).maskMatch(mask))
								if (client.nickname !in result)
									result[client.nickname] = "*";

					foreach (nickname, channel; result)
					{
						auto client = server.nicknames[nickname.normalized];
						sendReply(Reply.RPL_WHOREPLY,
							channel,
							client.username,
							safeHostname(client.hostnameAsVisibleTo(this)),
							server.hostname,
							nickname,
							"H",
							"0 " ~ client.realname,
						);
					}
					sendReply(Reply.RPL_ENDOFWHO, mask ? mask : "*", "End of WHO list");
					break;
				}
				case "WHOIS":
				{
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					// Contrary to the RFC, and similar to e.g. Freenode, we don't support masks here.
					if (parameters.length < 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					foreach (nick; parameters[0].split(","))
					{
						auto pclient = nick.normalized in server.nicknames;
						if (!pclient)
							sendReply(Reply.ERR_NOSUCHNICK, nick, "No such nick");
						auto client = *pclient;

						// RPL_WHOISUSER
						sendReply(Reply.RPL_WHOISUSER,
							client.nickname,
							client.username,
							safeHostname(client.hostnameAsVisibleTo(this)),
							"*",
							client.realname,
						);
						// RPL_WHOISCHANNELS
						server.channels.byValue
							// Channel contents visible?
							.filter!(channel => !channel.modes.flags['s'] || this.nickname.normalized in channel.members)
							// Get channel member mode + name if target in channel, or null
							.map!(channel => (nick.normalized in channel.members).I!(pmember => pmember ? pmember.modeChar() ~ channel.name : null))
							.filter!(name => name !is null)
							.chunks(10)
							.each!(chunk => sendReply(Reply.RPL_WHOISCHANNELS, client.nickname, chunk.join(" ")));
						// RPL_WHOISOPERATOR
						if (client.modes.flags['o'])
							sendReply(Reply.RPL_WHOISOPERATOR, client.nickname, "is an IRC operator");
						// RPL_WHOISIDLE
						sendReply(Reply.RPL_WHOISIDLE, client.nickname,
							(MonoTime.currTime - client.lastActivity).total!"seconds".text,
							"seconds idle");
					}
					// RPL_ENDOFWHOIS
					sendReply(Reply.RPL_ENDOFWHOIS, parameters[0], "End of WHOIS list");
					break;
				}
				case "TOPIC":
				{
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					auto target = parameters.shift;
					auto pchannel = target.normalized in server.channels;
					if (!pchannel)
						return sendReply(Reply.ERR_NOSUCHNICK, target, "No such nick/channel");
					auto channel = *pchannel;
					auto pmember = nickname.normalized in channel.members;
					if (!pmember)
						return sendReply(Reply.ERR_NOTONCHANNEL, target, "You're not on that channel");
					if (!parameters.length)
						return sendTopic(channel);
					if (channel.modes.flags['t'] && (pmember.modes & Channel.Member.Modes.op) == 0)
						return sendReply(Reply.ERR_CHANOPRIVSNEEDED, target, "You're not channel operator");
					return setChannelTopic(channel, parameters[0]);
				}
				case "ISON":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					sendReply(Reply.RPL_ISON, parameters.filter!(nick => nick.normalized in server.nicknames).join(" "));
					break;
				case "USERHOST":
				{
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					string[] replies;
					foreach (nick; parameters)
					{
						auto pclient = nick.normalized in server.nicknames;
						if (!pclient)
							continue;
						auto client = *pclient;
						replies ~= "%s%s=%s%s@%s".format(
							nick,
							client.modes.flags['o'] ? "*" : "",
							client.away ? "+" : "-",
							client.username,
							client.hostnameAsVisibleTo(this),
						);
					}
					sendReply(Reply.RPL_USERHOST, replies.join(" "));
					break;
				}
				case "PRIVMSG":
				case "NOTICE":
				{
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 2)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					auto message = parameters[1];
					if (!message.length)
						return sendReply(Reply.ERR_NOTEXTTOSEND, command, "No text to send");
					foreach (target; parameters[0].split(","))
					{
						if (server.isChannelName(target))
						{
							auto pchannel = target.normalized in server.channels;
							if (!pchannel)
								{ sendReply(Reply.ERR_NOSUCHNICK, target, "No such nick/channel"); continue; }
							auto channel = *pchannel;
							auto pmember = nickname.normalized in channel.members;
							if (pmember) // On channel?
							{
								if (channel.modes.flags['m'] && (pmember.modes & Channel.Member.Modes.bypassM) == 0)
									{ sendReply(Reply.ERR_CANNOTSENDTOCHAN, target, "Cannot send to channel"); continue; }
							}
							else
							{
								if (channel.modes.flags['n']) // No external messages
									{ sendReply(Reply.ERR_NOTONCHANNEL, target, "You're not on that channel"); continue; }
							}
							sendToChannel(channel, command, message);
						}
						else
						{
							auto pclient = target.normalized in server.nicknames;
							if (!pclient)
								{ sendReply(Reply.ERR_NOSUCHNICK, target, "No such nick/channel"); continue; }
							sendToClient(*pclient, command, message);
						}
					}
					lastActivity = MonoTime.currTime;
					break;
				}
				case "OPER":
					if (!registered)
						return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
					if (parameters.length < 1)
						return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
					if (!server.operPassword || parameters[$-1] != server.operPassword)
						return sendReply(Reply.ERR_PASSWDMISMATCH, "Password incorrect");
					modes.flags['o'] = true;
					sendReply(Reply.RPL_YOUREOPER, "You are now an IRC operator");
					sendUserModes(this);
					foreach (channel; server.channels)
						if (nickname.normalized in channel.members)
							setChannelMode(channel, nickname, Channel.Member.Mode.op, true);
					break;

				default:
					if (registered)
						return sendReply(Reply.ERR_UNKNOWNCOMMAND, command, "Unknown command");
			}
		}

		final void onInactivity()
		{
			sendLine("PING %s".format(Clock.currTime.stdTime));
		}

		void disconnect(string why)
		{
			if (registered)
				unregister(why);
			sendLine("ERROR :Closing Link: %s[%s@%s] (%s)".format(nickname, username, realHostname, why));
			connDisconnect(why);
		}

		void onDisconnect(string reason, DisconnectType type)
		{
			if (registered)
				unregister(reason);
			server.clients.remove(this);
			server.log("IRC: %s disconnecting: %s".format(remoteAddress, reason));
		}

		void checkRegistration()
		{
			assert(!registered);

			if (nickname.length && username.length)
			{
				if (server.password && password != server.password)
				{
					password = null;
					return sendReply(Reply.ERR_PASSWDMISMATCH, "Password incorrect");
				}
				if (nickname.normalized in server.nicknames)
				{
					scope(exit) nickname = null;
					return sendReply(Reply.ERR_NICKNAMEINUSE, nickname, "Nickname is already in use");
				}
				if (!nickname.match(server.nicknameValidationPattern))
				{
					scope(exit) nickname = null;
					return sendReply(Reply.ERR_ERRONEUSNICKNAME, nickname, "Erroneous nickname");
				}
				if (!username.match(`[a-zA-Z]+`))
					return disconnect("Invalid username");

				// All OK
				register();
			}
		}

		void register()
		{
			if (!identified)
				username = "~" ~ username;
			update();

			registered = true;
			server.nicknames[nickname.normalized] = this;
			auto userCount = server.nicknames.length;
			if (server.maxUsers < userCount)
				server.maxUsers = userCount;
			sendReply(Reply.RPL_WELCOME      , "Welcome, %s!".format(nickname));
			sendReply(Reply.RPL_YOURHOST     , "Your host is %s, running %s".format(server.hostname, server.serverVersion));
			sendReply(Reply.RPL_CREATED      , "This server was created %s".format(server.creationTime));
			sendReply(Reply.RPL_MYINFO       , server.hostname, server.serverVersion, UserModes.supported, ChannelModes.supported, null);
			sendReply(cast(Reply)         005, server.capabilities ~ ["are supported by this server"]);
			sendReply(Reply.RPL_LUSERCLIENT  , "There are %d users and %d invisible on %d servers".format(userCount, 0, 1));
			sendReply(Reply.RPL_LUSEROP      , 0.text, "IRC Operators online"); // TODO: OPER
			sendReply(Reply.RPL_LUSERCHANNELS, server.channels.length.text, "channels formed");
			sendReply(Reply.RPL_LUSERME      , "I have %d clients and %d servers".format(userCount, 0));
			sendReply(cast(Reply)         265, "Current local  users: %d  Max: %d".format(userCount, server.maxUsers));
			sendReply(cast(Reply)         266, "Current global users: %d  Max: %d".format(userCount, server.maxUsers));
			sendReply(cast(Reply)         250, "Highest connection count: %d (%d clients) (%d since server was (re)started)".format(server.maxUsers, server.maxUsers, server.totalConnections));
			sendMotd();
		}

		void update()
		{
			prefix       = "%s!%s@%s".format(nickname, username, realHostname  );
			publicPrefix = "%s!%s@%s".format(nickname, username, publicHostname);
		}

		void unregister(string why)
		{
			assert(registered);
			auto channels = getJoinedChannels();
			foreach (channel; channels)
				channel.remove(this);
			foreach (client; server.allClientsInChannels(channels))
				client.sendCommand(this, "QUIT", why);
			server.nicknames.remove(nickname.normalized);
			registered = false;
		}

		void changeNick(string newNick)
		{
			auto channels = getJoinedChannels();
			auto witnesses = server.whoCanSee(this);

			foreach (channel; channels)
			{
				auto pmember = nickname.normalized in channel.members;
				assert(pmember);
				auto member = *pmember;
				channel.members.remove(nickname.normalized);
				channel.members[newNick.normalized] = member;
			}

			foreach (client; witnesses)
				client.sendCommand(this, "NICK", newNick, null);

			server.nicknames.remove(nickname.normalized);
			server.nicknames[newNick.normalized] = this;

			nickname = newNick;
			update();
		}

		void sendMotd()
		{
			sendReply(Reply.RPL_MOTDSTART    , "- %s Message of the Day - ".format(server.hostname));
			foreach (line; server.motd)
				sendReply(Reply.RPL_MOTD, "- %s".format(line));
			sendReply(Reply.RPL_ENDOFMOTD    , "End of /MOTD command.");
		}

		bool mayJoin(string name)
		{
			return true;
		}

		void join(Channel channel)
		{
			channel.add(this);
			foreach (member; channel.members)
				member.client.sendCommand(this, "JOIN", channel.name);
			sendTopic(channel);
			sendNames(channel);
			auto pmember = nickname.normalized in channel.members;
			// Sync OPER status with (initial) channel op status
			if (server.staticChannels || modes.flags['o'])
				setChannelMode(channel, nickname, Channel.Member.Mode.op, modes.flags['o']);
		}

		// For server-imposed mode changes.
		void setChannelMode(Channel channel, string nickname, Channel.Member.Mode mode, bool value)
		{
			auto pmember = nickname.normalized in channel.members;
			if (pmember.modeSet(mode) == value)
				return;

			pmember.setMode(mode, value);
			auto c = ChannelModes.memberModeChars[mode];
			foreach (member; channel.members)
				member.client.sendCommand(server.hostname, "MODE", channel.name, [value ? '+' : '-', c], nickname, null);
			server.channelChanged(channel);
		}

		void part(Channel channel, string reason=null)
		{
			foreach (member; channel.members)
				member.client.sendCommand(this, "PART", channel.name, reason);
			channel.remove(this);
		}

		void sendToChannel(Channel channel, string command, string message)
		{
			foreach (member; channel.members)
				if (member.client !is this)
					member.client.sendCommand(this, command, channel.name, message);
		}

		void sendToClient(Client client, string command, string message)
		{
			client.sendCommand(this, command, client.nickname, message);
		}

		void sendTopic(Channel channel)
		{
			if (channel.topic)
				sendReply(Reply.RPL_TOPIC, channel.name, channel.topic);
			else
				sendReply(Reply.RPL_NOTOPIC, channel.name, "No topic is set");
		}

		void sendNames(Channel channel)
		{
			foreach (chunk; channel.members.values.chunks(10)) // can't use byValue - https://issues.dlang.org/show_bug.cgi?id=11761
				sendReply(Reply.RPL_NAMREPLY, channel.modes.flags['s'] ? "@" : channel.modes.flags['p'] ? "*" : "=", channel.name, chunk.map!q{a.displayName}.join(" "));
			sendReply(Reply.RPL_ENDOFNAMES, channel.name, "End of /NAMES list");
		}

		/// For LIST
		Channel[] getChannelList()
		{
			return server.channels.values;
		}

		void sendChannelModes(Channel channel)
		{
			string modes = "+";
			string[] modeParams;
			foreach (c; 0..char.max)
				final switch (ChannelModes.modeTypes[c])
				{
					case ChannelModes.Type.none:
					case ChannelModes.Type.member:
						break;
					case ChannelModes.Type.mask:
						// sent after RPL_CHANNELMODEIS
						break;
					case ChannelModes.Type.flag:
						if (channel.modes.flags[c])
							modes ~= c;
						break;
					case ChannelModes.Type.str:
						if (channel.modes.strings[c])
						{
							modes ~= c;
							modeParams ~= channel.modes.strings[c];
						}
						break;
					case ChannelModes.Type.number:
						if (channel.modes.numbers[c])
						{
							modes ~= c;
							modeParams ~= channel.modes.numbers[c].text;
						}
						break;
				}
			sendReply(Reply.RPL_CHANNELMODEIS, channel.name, ([modes] ~ modeParams).join(" "), null);
		}

		void sendChannelModeMasks(Channel channel, char mode)
		{
			switch (mode)
			{
				case 'b':
					sendChannelMaskList(channel, channel.modes.masks[mode], Reply.RPL_BANLIST, Reply.RPL_ENDOFBANLIST, "End of channel ban list");
					break;
				default:
					assert(false);
			}
		}

		void sendChannelMaskList(Channel channel, string[] masks, Reply lineReply, Reply endReply, string endText)
		{
			foreach (mask; masks)
				sendReply(lineReply, channel.name, mask, null);
			sendReply(endReply, channel.name, endText);
		}

		void setChannelTopic(Channel channel, string topic)
		{
			channel.topic = topic;
			foreach (ref member; channel.members)
				member.client.sendCommand(this, "TOPIC", channel.name, topic);
			server.channelChanged(channel);
		}

		void setChannelModes(Channel channel, string[] modes)
		{
			auto pself = nickname.normalized in channel.members;
			bool op = (pself.modes & Channel.Member.Modes.op) != 0;

			string[2] effectedChars;
			string[][2] effectedParams;

			scope(exit) // Broadcast effected options
			{
				string[] parameters;
				foreach (adding; 0..2)
					if (effectedChars[adding].length)
						parameters ~= [(adding ? "+" : "-") ~ effectedChars[adding]] ~ effectedParams[adding];
				if (parameters.length)
				{
					assert(op);
					parameters = ["MODE", channel.name] ~ parameters ~ [string.init];
					foreach (ref member; channel.members)
						member.client.sendCommand(this, parameters);
				}
			}

			while (modes.length)
			{
				auto chars = modes.shift;

				bool adding = true;
				foreach (c; chars)
					if (c == '+')
						adding = true;
					else
					if (c == '-')
						adding = false;
					else
					final switch (ChannelModes.modeTypes[c])
					{
						case ChannelModes.Type.none:
							sendReply(Reply.ERR_UNKNOWNMODE, [c], "is unknown mode char to me for %s".format(channel.name));
							break;
						case ChannelModes.Type.flag:
							if (!op) return sendReply(Reply.ERR_CHANOPRIVSNEEDED, channel.name, "You're not channel operator");
							if (adding != channel.modes.flags[c])
							{
								channel.modes.flags[c] = adding;
								effectedChars[adding] ~= c;
							}
							break;
						case ChannelModes.Type.member:
						{
							if (!op) return sendReply(Reply.ERR_CHANOPRIVSNEEDED, channel.name, "You're not channel operator");
							if (!modes.length)
								{ sendReply(Reply.ERR_NEEDMOREPARAMS, "MODE", "Not enough parameters"); continue; }
							auto memberName = modes.shift;
							auto pmember = memberName.normalized in channel.members;
							if (!pmember)
								{ sendReply(Reply.ERR_USERNOTINCHANNEL, memberName, channel.name, "They aren't on that channel"); continue; }
							auto mode = ChannelModes.memberModes[c];
							if (pmember.modeSet(mode) != adding)
							{
								pmember.setMode(mode, adding);
								effectedChars[adding] ~= c;
								effectedParams[adding] ~= memberName;
							}
							break;
						}
						case ChannelModes.Type.mask:
						{
							if (!modes.length)
								return sendChannelModeMasks(channel, c);
							if (!op) return sendReply(Reply.ERR_CHANOPRIVSNEEDED, channel.name, "You're not channel operator");
							auto mask = modes.shift;
							if (adding)
							{
								if (channel.modes.masks[c].canFind(mask))
									continue;
								channel.modes.masks[c] ~= mask;
							}
							else
							{
								auto index = channel.modes.masks[c].countUntil(mask);
								if (index < 0)
									continue;
								channel.modes.masks[c] = channel.modes.masks[c][0..index] ~ channel.modes.masks[c][index+1..$];
							}
							effectedChars[adding] ~= c;
							effectedParams[adding] ~= mask;
							break;
						}
						case ChannelModes.Type.str:
							if (!op) return sendReply(Reply.ERR_CHANOPRIVSNEEDED, channel.name, "You're not channel operator");
							if (adding)
							{
								if (!modes.length)
									{ sendReply(Reply.ERR_NEEDMOREPARAMS, "MODE", "Not enough parameters"); continue; }
								auto str = modes.shift;
								if (channel.modes.strings[c] == str)
									continue;
								channel.modes.strings[c] = str;
								effectedChars[adding] ~= c;
								effectedParams[adding] ~= str;
							}
							else
							{
								if (!channel.modes.strings[c])
									continue;
								channel.modes.strings[c] = null;
								effectedChars[adding] ~= c;
							}
							break;
						case ChannelModes.Type.number:
							if (!op) return sendReply(Reply.ERR_CHANOPRIVSNEEDED, channel.name, "You're not channel operator");
							if (adding)
							{
								if (!modes.length)
									{ sendReply(Reply.ERR_NEEDMOREPARAMS, "MODE", "Not enough parameters"); continue; }
								auto numText = modes.shift;
								auto num = numText.to!long;
								if (channel.modes.numbers[c] == num)
									continue;
								channel.modes.numbers[c] = num;
								effectedChars[adding] ~= c;
								effectedParams[adding] ~= numText;
							}
							else
							{
								if (!channel.modes.numbers[c])
									continue;
								channel.modes.numbers[c] = 0;
								effectedChars[adding] ~= c;
							}
							break;
					}
			}
			server.channelChanged(channel);
		}

		void setUserModes(string[] modes)
		{
			while (modes.length)
			{
				auto chars = modes.shift;

				bool adding = true;
				foreach (c; chars)
					if (c == '+')
						adding = true;
					else
					if (c == '-')
						adding = false;
					else
					final switch (UserModes.modeTypes[c])
					{
						case UserModes.Type.none:
							sendReply(Reply.ERR_UMODEUNKNOWNFLAG, "Unknown MODE flag");
							break;
						case UserModes.Type.flag:
							if (UserModes.isSettable[c])
								this.modes.flags[c] = adding;
							break;
					}
			}
		}

		void sendUserModes(Client client)
		{
			string modeString = "+";
			foreach (char c, on; modes.flags)
				if (on)
					modeString ~= c;
			return sendReply(Reply.RPL_UMODEIS, modeString, null);
		}

		void sendCommand(Client from, string[] parameters...)
		{
			return sendCommand(this is from ? prefix : from.prefixAsVisibleTo(this), parameters);
		}

		void sendCommand(string from, string[] parameters...)
		{
			assert(parameters.length, "At least one parameter expected");
			foreach (parameter; parameters[0..$-1])
				assert(parameter.length && parameter[0] != ':' && parameter.indexOf(' ') < 0, "Invalid parameter: " ~ parameter);
			if (parameters[$-1] is null)
				parameters = parameters[0..$-1];
			else
				parameters = parameters[0..$-1] ~ [":" ~ parameters[$-1]];
			auto line = ":%s %-(%s %)".format(from, parameters);
			sendLine(line);
		}

		void sendReply(Reply reply, string[] parameters...)
		{
			return sendReply("%03d".format(reply), parameters);
		}

		void sendReply(string command, string[] parameters...)
		{
			return sendCommand(server.hostname, [command, nickname ? nickname : "*"] ~ parameters);
		}

		void sendServerNotice(string text)
		{
			sendReply("NOTICE", "*** Notice -- " ~ text);
		}

		void sendLine(string line)
		{
			if (encoder) line = encoder(line);
			connSendLine(line);
		}

		abstract bool connConnected();
		abstract void connSendLine(string line);
		abstract void connDisconnect(string reason);
	}

	static class NetworkClient : Client
	{
	protected:
		IrcConnection conn;

		this(IrcServer server, IrcConnection incoming, Address remoteAddress)
		{
			super(server, remoteAddress);

			conn = incoming;
			conn.handleReadLine = &onReadLine;
			conn.handleInactivity = &onInactivity;
			conn.handleDisconnect = &onDisconnect;
		}

		override bool connConnected()
		{
			return conn.state == ConnectionState.connected;
		}

		override void connSendLine(string line)
		{
			conn.send(line);
		}

		override void connDisconnect(string reason)
		{
			conn.disconnect(reason);
		}
	}

	HashSet!Client clients; /// All clients
	Client[string] nicknames; /// Registered clients only

	/// Statistics
	ulong maxUsers, totalConnections;

	final class Channel
	{
		string name;
		string topic;

		Modes modes;

		struct Member
		{
			enum Mode
			{
				op,
				voice,
				max
			}

			enum Modes
			{
				none  = 0,
				op    = 1 << Mode.op,
				voice = 1 << Mode.voice,

				bypassM = op | voice, // which modes bypass +m
			}

			Client client;
			Modes modes;

			bool modeSet(Mode mode) { return (modes & (1 << mode)) != 0; }
			void setMode(Mode mode, bool value)
			{
				auto modeMask = 1 << mode;
				if (value)
					modes |= modeMask;
				else
					modes &= ~modeMask;
			}

			string modeChar()
			{
				foreach (mode; Mode.init..Mode.max)
					if ((1 << mode) & modes)
						return [ChannelModes.memberModePrefixes[mode]];
				return "";
			}
			string displayName() { return modeChar ~ client.nickname; }
		}

		Member[string] members;

		this(string name)
		{
			this.name = name;
			modes.flags['t'] = modes.flags['n'] = true;
		}

		void add(Client client)
		{
			auto modes = staticChannels || members.length ? Member.Modes.none : Member.Modes.op;
			members[client.nickname.normalized] = Member(client, modes);
		}

		void remove(Client client)
		{
			members.remove(client.nickname.normalized);
			if (!staticChannels && !members.length && !modes.flags['P'])
				channels.remove(name.normalized);
		}
	}

	Channel[string] channels;

	TcpServer conn;

	this()
	{
		conn = new TcpServer;
		conn.handleAccept = &onAccept;

		hostname = Socket.hostName;
		creationTime = Clock.currTime;
	}

	ushort listen(ushort port=6667, string addr = null)
	{
		port = conn.listen(port, addr);
		return port;
	}

	Channel createChannel(string name)
	{
		return channels[name.normalized] = new Channel(name);
	}

	void close(string reason)
	{
		conn.close();
		foreach (client; clients.keys)
			client.disconnect("Server is shutting down" ~ (reason.length ? ": " ~ reason : ""));
	}

protected:
	Client createClient(TcpConnection incoming)
	{
		return new NetworkClient(this, new IrcConnection(incoming), incoming.remoteAddress);
	}

	void onAccept(TcpConnection incoming)
	{
		createClient(incoming);
		totalConnections++;
	}

	Client[string] allClientsInChannels(Channel[] channels)
	{
		Client[string] result;
		foreach (channel; channels)
			foreach (ref member; channel.members)
				result[member.client.nickname.normalized] = member.client;
		return result;
	}

	/// Clients who can see the given client (are in the same channer).
	/// Includes the target client himself.
	Client[string] whoCanSee(Client who)
	{
		auto clients = allClientsInChannels(who.getJoinedChannels());
		clients[who.nickname.normalized] = who;
		return clients;
	}

	bool isChannelName(string target)
	{
		foreach (prefix; chanTypes)
			if (target.startsWith(prefix))
				return true;
		return false;
	}

	string[] capabilities()
	{
		string[] result;
		result ~= "PREFIX=(%s)%s".format(ChannelModes.memberModeChars, ChannelModes.memberModePrefixes);
		result ~= "CHANTYPES=" ~ chanTypes;
		result ~= "CHANMODES=%-(%s,%)".format(
			[ChannelModes.Type.mask, ChannelModes.Type.str, ChannelModes.Type.number, ChannelModes.Type.flag].map!(type => ChannelModes.byType(type))
		);
		if (network)
			result ~= "NETWORK=" ~ network;
		result ~= "CASEMAPPING=rfc1459";
		result ~= "NICKLEN=" ~ text(nicknameMaxLength);
		return result;
	}

	/// Persistence hook
	void channelChanged(Channel channel)
	{
	}
}

bool maskMatch(string subject, string mask)
{
	import std.path;
	return globMatch!(CaseSensitive.no)(subject, mask);
}


string safeHostname(string s)
{
	assert(s.length);
	if (s[0] == ':')
		s = '0' ~ s;
	return s;
}

alias rfc1459toUpper normalized;

string[] ircSplit(string line)
{
	auto colon = line.indexOf(":");
	if (colon < 0)
		return line.split;
	else
		return line[0..colon].strip.split ~ [line[colon+1..$]];
}

struct Modes
{
	bool[char.max] flags;
	string[char.max] strings;
	long[char.max] numbers;
	string[][char.max] masks;
}

mixin template CommonModes()
{
//static immutable:
	Type[char.max] modeTypes;
	string supported()       pure { return modeTypes.length.iota.filter!(m => modeTypes[m]        ).map!(m => cast(char)m).array; }
	string byType(Type type) pure { return modeTypes.length.iota.filter!(m => modeTypes[m] == type).map!(m => cast(char)m).array; }
}

struct ChannelModes
{
static immutable:
	enum Type { none, flag, member, mask, str, number }
	mixin CommonModes;
	IrcServer.Channel.Member.Mode[char.max] memberModes;
	char[IrcServer.Channel.Member.Mode.max] memberModeChars, memberModePrefixes;

	shared static this()
	{
		foreach (c; "ntpsP")
			modeTypes[c] = Type.flag;
		foreach (c; "ov")
			modeTypes[c] = Type.member;
		foreach (c; "b")
			modeTypes[c] = Type.mask;
		foreach (c; "k")
			modeTypes[c] = Type.str;

		memberModes['o'] = IrcServer.Channel.Member.Mode.op;
		memberModes['v'] = IrcServer.Channel.Member.Mode.voice;

		memberModeChars    = "ov";
		memberModePrefixes = "@+";
	}
}

struct UserModes
{
static immutable:
	enum Type { none, flag }
	mixin CommonModes;
	bool[char.max] isSettable;

	shared static this()
	{
		foreach (c; "io")
			modeTypes[c] = Type.flag;
		foreach (c; "i")
			isSettable[c] = true;
	}
}
