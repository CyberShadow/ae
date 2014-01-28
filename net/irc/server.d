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
import std.range;
import std.regex;
import std.socket;
import std.string;

import ae.net.asockets;
import ae.utils.array;
import ae.sys.log;

import ae.net.irc.common;

alias std.string.indexOf indexOf;

class IrcServer
{
	// This class is currently intentionally written for readability, not performance.
	// Performance and scalability could be greatly improved by using numeric indices for users and channels
	// instead of associative arrays.

	/// Server configuration
	string hostname, password, network;
	string nicknameValidationPattern = "^[a-zA-Z][a-zA-Z0-9\\-`\\|]{0,14}$";
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
	final static class Client
	{
		/// Registration details
		string nickname, password;
		string username, hostname, servername, realname;
		bool identified;
		string prefix, publicPrefix; /// Full nick!user@host
		string away;

		bool registered;
		bool[char.max] modeFlags;

		Channel[] joinedChannels()
		{
			Channel[] result;
			foreach (channel; server.channels)
				if (nickname.normalized in channel.members)
					result ~= channel;
			return result;
		}

		string realHostname() { return conn.remoteAddress.toAddrString; }
		string publicHostname() { return server.addressMask ? server.addressMask : realHostname; }

	private:
		IrcServer server;
		IrcSocket conn;

		this(IrcServer server, IrcSocket incoming)
		{
			this.server = server;

			conn = incoming;
			conn.handleReadLine = &onReadLine;
			conn.handleInactivity = &onInactivity;
			conn.handleDisconnect = &onDisconnect;

			server.log("New IRC connection from " ~ incoming.remoteAddress.toString);
		}

		void onReadLine(LineBufferedSocket sender, string line)
		{
			try
			{
				enforce(line.indexOf('\0')<0 && line.indexOf('\r')<0 && line.indexOf('\n')<0, "Forbidden character");

				auto parameters = line.strip.ircSplit();
				if (!parameters.length)
					return;

				auto command = parameters.shift.toUpper();

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
						if (registered)
							return sendServerNotice("Nick change not allowed."); // TODO. NB: update prefix, nicknames and Channel.members keys
						if (parameters.length != 1)
							return sendReply(Reply.ERR_NONICKNAMEGIVEN, "No nickname given");
						nickname = parameters[0];
						checkRegistration();
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
							if (channel.modeStrings['k'] && channel.modeStrings['k'] != key)
								{ sendReply(Reply.ERR_BADCHANNELKEY, channame, "Cannot join channel (+k)"); continue; }
							if (channel.modeMasks['b'].any!(mask => prefix.maskMatch(mask)))
								{ sendReply(Reply.ERR_BANNEDFROMCHAN, channame, "Cannot join channel (+b)"); continue; }
							join(channel);
						}
						break;
					case "PART":
						if (!registered)
							return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
						if (parameters.length < 1) // TODO: part reason
							return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
						foreach (channame; parameters[0].split(","))
						{
							auto pchan = channame.normalized in server.channels;
							if (!pchan)
								{ sendReply(Reply.ERR_NOSUCHCHANNEL, channame, "No such channel"); continue; }
							auto chan = *pchan;
							if (nickname.normalized !in chan.members)
								{ sendReply(Reply.ERR_NOTONCHANNEL, channame, "You're not on that channel"); continue; }
							part(chan);
						}
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
							if ((pmember.modes & Channel.Member.Modes.op) == 0)
								return sendReply(Reply.ERR_CHANOPRIVSNEEDED, target, "You're not channel operator");
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
						foreach (channel; server.channels)
							if (!(channel.modeFlags['p'] || channel.modeFlags['s']) || nickname.normalized in channel.members)
								sendReply(Reply.RPL_LIST, channel.name, channel.members.length.text, channel.topic ? channel.topic : "");
						sendReply(Reply.RPL_LISTEND, "End of LIST");
						break;
					case "WHO":
					{
						if (!registered)
							return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
						auto mask = parameters.length ? parameters[0] != "*" && parameters[0] != "0" ? parameters[0] : null : null;
						string[string] result;
						foreach (channel; server.channels)
						{
							auto inChannel = nickname.normalized in channel.members;
							if (!inChannel && channel.modeFlags['s'])
								continue;
							foreach (member; channel.members)
								if (inChannel || !member.client.modeFlags['i'])
									if (!mask || member.client.publicPrefix.maskMatch(mask))
									{
										auto phit = member.client.nickname in result;
										if (phit)
											*phit = "*";
										else
											result[member.client.nickname] = channel.name;
									}
						}

						foreach (client; server.nicknames)
							if (!client.modeFlags['i'])
								if (!mask || client.publicPrefix.maskMatch(mask))
									if (client.nickname !in result)
										result[client.nickname] = "*";

						foreach (nickname, channel; result)
						{
							auto client = server.nicknames[nickname.normalized];
							sendReply(Reply.RPL_WHOREPLY,
								channel,
								client.username,
								this is client ? client.realHostname : client.publicHostname,
								server.hostname,
								nickname,
								"H",
								"0 " ~ client.realname,
							);
						}
						sendReply(Reply.RPL_ENDOFWHO, mask ? mask : "*", "End of WHO list");
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
						if (channel.modeFlags['t'] && (pmember.modes & Channel.Member.Modes.op) == 0)
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
								client.modeFlags['o'] ? "*" : "",
								client.away ? "+" : "-",
								client.username,
								this is client ? client.realHostname : client.publicHostname,
							);
						}
						sendReply(Reply.RPL_USERHOST, replies.join(" "));
						break;
					}
					case "PRIVMSG":
					case "NOTICE":
						if (!registered)
							return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
						if (parameters.length < 2)
							return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
						auto message = parameters[1];
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
									if (channel.modeFlags['m'] && (pmember.modes & Channel.Member.Modes.bypassM) == 0)
										{ sendReply(Reply.ERR_CANNOTSENDTOCHAN, target, "Cannot send to channel"); continue; }
								}
								else
								{
									if (channel.modeFlags['n']) // No external messages
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
						break;
					case "OPER":
						if (!registered)
							return sendReply(Reply.ERR_NOTREGISTERED, "You have not registered");
						if (parameters.length < 1)
							return sendReply(Reply.ERR_NEEDMOREPARAMS, command, "Not enough parameters");
						if (!server.operPassword || parameters[$-1] != server.operPassword)
							return sendReply(Reply.ERR_PASSWDMISMATCH, "Password incorrect");
						modeFlags['o'] = true;
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
			catch (Exception e)
			{
				disconnect(e.msg);
			}
		}

		void onInactivity(IrcSocket sender)
		{
			sendReply("PING", Clock.currTime.stdTime.text);
		}

		void disconnect(string why)
		{
			if (registered)
				unregister(why);
			sendLine("ERROR :Closing Link: %s[%s@%s] (%s)".format(nickname, username, realHostname, why));
			conn.disconnect(why);
		}

		void onDisconnect(ClientSocket sender, string reason, DisconnectType type)
		{
			if (registered)
				unregister(reason);
			server.log("IRC: %s disconnecting: %s".format(conn.remoteAddress, reason));
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
					return sendReply(Reply.ERR_ERRONEUSNICKNAME, nickname, "Erroneus nickname");
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
			prefix       = "%s!%s@%s".format(nickname, username, realHostname  );
			publicPrefix = "%s!%s@%s".format(nickname, username, publicHostname);

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

		void unregister(string why)
		{
			assert(registered);
			auto channels = joinedChannels;
			foreach (client; server.allClientsInChannels(joinedChannels))
				client.sendCommand(this, "QUIT", why);
			foreach (channel; channels)
				channel.remove(this);
			server.nicknames.remove(nickname.normalized);
			registered = false;
		}

		void sendMotd()
		{
			sendReply(Reply.RPL_MOTDSTART    , "- %s Message of the Day - ".format(server.hostname));
			foreach (line; server.motd)
				sendReply(Reply.RPL_MOTD, "- %s".format(line));
			sendReply(Reply.RPL_ENDOFMOTD    , "End of /MOTD command.");
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
			if (server.staticChannels || modeFlags['o'])
				setChannelMode(channel, nickname, Channel.Member.Mode.op, modeFlags['o']);
		}

		// For server-imposed mode changes.
		void setChannelMode(Channel channel, string nickname, Channel.Member.Mode mode, bool value)
		{
			auto pmember = nickname.normalized in channel.members;
			if (pmember.modeSet(mode) == value)
				return;

			pmember.setMode(Channel.Member.Mode.op, value);
			auto c = ChannelModes.memberModeChars[mode];
			foreach (member; channel.members)
				member.client.sendCommand(server.hostname, "MODE", channel.name, [value ? '+' : '-', c], nickname, null);
		}

		void part(Channel channel)
		{
			foreach (member; channel.members)
				member.client.sendCommand(this, "PART", channel.name);
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
			foreach (chunk; channel.members.values.chunks(10)) // can't use byValue - http://j.mp/IUhhGC (Issue 11761)
				sendReply(Reply.RPL_NAMREPLY, channel.modeFlags['s'] ? "@" : channel.modeFlags['p'] ? "*" : "=", channel.name, chunk.map!q{a.displayName}.join(" "));
			sendReply(Reply.RPL_ENDOFNAMES, channel.name, "End of /NAMES list");
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
						if (channel.modeFlags[c])
							modes ~= c;
						break;
					case ChannelModes.Type.str:
						if (channel.modeStrings[c])
						{
							modes ~= c;
							modeParams ~= channel.modeStrings[c];
						}
						break;
					case ChannelModes.Type.number:
						if (channel.modeNumbers[c])
						{
							modes ~= c;
							modeParams ~= channel.modeNumbers[c].text;
						}
						break;
				}
			sendReply(Reply.RPL_CHANNELMODEIS, channel.name, ([modes] ~ modeParams).join(" "), null);
			sendChannelMaskList(channel, channel.modeMasks['b'], Reply.RPL_BANLIST, Reply.RPL_ENDOFBANLIST, "End of channel ban list");
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
		}

		void setChannelModes(Channel channel, string[] modes)
		{
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
					parameters = ["MODE", channel.name] ~ parameters ~ null;
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
							if (adding != channel.modeFlags[c])
							{
								channel.modeFlags[c] = adding;
								effectedChars[adding] ~= c;
							}
							break;
						case ChannelModes.Type.member:
						{
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
								{ sendReply(Reply.ERR_NEEDMOREPARAMS, "MODE", "Not enough parameters"); continue; }
							auto mask = modes.shift;
							if (adding)
							{
								if (channel.modeMasks[c].canFind(mask))
									continue;
								channel.modeMasks[c] ~= mask;
							}
							else
							{
								auto index = channel.modeMasks[c].countUntil(mask);
								if (index < 0)
									continue;
								channel.modeMasks[c] = channel.modeMasks[c][0..index] ~ channel.modeMasks[c][index+1..$];
							}
							effectedChars[adding] ~= c;
							effectedParams[adding] ~= mask;
							break;
						}
						case ChannelModes.Type.str:
							if (adding)
							{
								if (!modes.length)
									{ sendReply(Reply.ERR_NEEDMOREPARAMS, "MODE", "Not enough parameters"); continue; }
								auto str = modes.shift;
								if (channel.modeStrings[c] == str)
									continue;
								channel.modeStrings[c] = str;
								effectedChars[adding] ~= c;
								effectedParams[adding] ~= str;
							}
							else
							{
								if (!channel.modeStrings[c])
									continue;
								channel.modeStrings[c] = null;
								effectedChars[adding] ~= c;
							}
							break;
						case ChannelModes.Type.number:
							if (adding)
							{
								if (!modes.length)
									{ sendReply(Reply.ERR_NEEDMOREPARAMS, "MODE", "Not enough parameters"); continue; }
								auto numText = modes.shift;
								auto num = numText.to!long;
								if (channel.modeNumbers[c] == num)
									continue;
								channel.modeNumbers[c] = num;
								effectedChars[adding] ~= c;
								effectedParams[adding] ~= numText;
							}
							else
							{
								if (!channel.modeNumbers[c])
									continue;
								channel.modeNumbers[c] = 0;
								effectedChars[adding] ~= c;
							}
							break;
					}
			}
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
								modeFlags[c] = adding;
							break;
					}
			}
		}

		void sendUserModes(Client client)
		{
			string modeString = "+";
			foreach (char c, on; modeFlags)
				if (on)
					modeString ~= c;
			return sendReply(Reply.RPL_UMODEIS, modeString, null);
		}

		void sendCommand(Client from, string[] parameters...)
		{
			return sendCommand(this is from ? prefix : from.publicPrefix, parameters);
		}

		void sendCommand(string from, string[] parameters...)
		{
			assert(parameters.length, "At least one parameter expected");
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
			return sendCommand(server.hostname, [command, nickname] ~ parameters);
		}

		void sendServerNotice(string text)
		{
			sendReply("NOTICE", "*** Notice -- " ~ text);
		}

		void sendLine(string line)
		{
			conn.send(line);
		}
	}

	Client[string] nicknames;

	/// Statistics
	ulong maxUsers, totalConnections;

	final class Channel
	{
		string name;
		string topic;

		bool[char.max] modeFlags;
		string[char.max] modeStrings;
		long[char.max] modeNumbers;
		string[][char.max] modeMasks;

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
			modeFlags['t'] = modeFlags['n'] = true;
		}

		void add(Client client)
		{
			auto modes = members.length ? Member.Modes.none : Member.Modes.op;
			members[client.nickname.normalized] = Member(client, modes);
		}

		void remove(Client client)
		{
			members.remove(client.nickname.normalized);
			if (!staticChannels && !members.length)
				channels.remove(name.normalized);
		}
	}

	Channel[string] channels;

	IrcServerSocket conn;

	this()
	{
		conn = new IrcServerSocket;
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

private:
	void onAccept(IrcSocket incoming)
	{
		new Client(this, incoming);
		totalConnections++;
	}

	Client[] allClientsInChannels(Channel[] channels)
	{
		Client[string] result;
		foreach (channel; channels)
			foreach (ref member; channel.members)
				result[member.client.nickname.normalized] = member.client;
		return result.values;
	}

	Client[] inSameChannelAs(Client client)
	{
		return allClientsInChannels(client.joinedChannels);
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
		return result;
	}
}

private:

bool maskMatch(string subject, string mask)
{
	import std.path;
	return globMatch!(CaseSensitive.no)(subject, mask);
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

mixin template CommonModes()
{
	Type[char.max] modeTypes;
	string supported()       { return modeTypes.length.iota.filter!(m => modeTypes[m]        ).map!(m => cast(char)m).array.assumeUnique; }
	string byType(Type type) { return modeTypes.length.iota.filter!(m => modeTypes[m] == type).map!(m => cast(char)m).array.assumeUnique; }
}

struct ChannelModes
{
static:
	enum Type { none, flag, member, mask, str, number }
	mixin CommonModes;
	IrcServer.Channel.Member.Mode[char.max] memberModes;
	char[IrcServer.Channel.Member.Mode.max] memberModeChars, memberModePrefixes;

	static this()
	{
		foreach (c; "ntps")
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
static:
	enum Type { none, flag }
	mixin CommonModes;
	Type[char.max] modeTypes;
	bool[char.max] isSettable;

	static this()
	{
		foreach (c; "io")
			modeTypes[c] = Type.flag;
		foreach (c; "i")
			isSettable[c] = true;
	}
}
