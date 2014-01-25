/**
 * NNTP client supporting a small subset of the protocol.
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

module ae.net.nntp.client;

import std.conv;
import std.string;
import std.exception;

import ae.net.asockets;
import ae.sys.log;
import ae.utils.array;

import core.time;

public import ae.net.asockets : DisconnectType;

struct GroupInfo { string name; int high, low; char mode; }

class NntpClient
{
private:
	/// Socket connection.
	LineBufferedSocket conn;

	/// Protocol log.
	Logger log;

	/// One possible reply to an NNTP command
	static struct Reply
	{
		bool multiLine;
		void delegate(string[] lines) handleReply;

		this(void delegate(string[] lines) handler)
		{
			multiLine = true;
			handleReply = handler;
		}

		this(void delegate(string line) handler)
		{
			multiLine = false;
			handleReply = (string[] lines) { assert(lines.length==1); handler(lines[0]); };
		}

		this(void delegate() handler)
		{
			multiLine = false;
			handleReply = (string[] lines) { assert(lines.length==1); handler(); };
		}
	}

	/// One pipelined command
	static struct Command
	{
		string[] lines;
		bool pipelineable;
		Reply[int] replies;
		void delegate(string error) handleError;
	}

	/// Commands queued to be sent to the NNTP server.
	Command[] queuedCommands;

	/// Commands that have been sent to the NNTP server, and are expecting a reply.
	Command[] sentCommands;

	void onConnect(ClientSocket sender)
	{
		log("* Connected, waiting for greeting...");
	}

	void onDisconnect(ClientSocket sender, string reason, DisconnectType type)
	{
		log("* Disconnected (" ~ reason ~ ")");
		foreach (command; queuedCommands ~ sentCommands)
			if (command.handleError)
				command.handleError("Disconnected from server (" ~ reason ~ ")");

		queuedCommands = sentCommands = null;
		replyLines = null;
		currentReply = null;

		if (handleDisconnect)
			handleDisconnect(reason, type);
	}

	void sendLine(string line)
	{
		log("< " ~ line);
		conn.send(line);
	}

	/// Reply line buffer.
	string[] replyLines;

	/// Reply currently being received/processed.
	Reply* currentReply;

	void onReadLine(LineBufferedSocket s, string line)
	{
		try
		{
			log("> " ~ line);

			bool replyDone;
			if (replyLines.length==0)
			{
				enforce(sentCommands.length, "No command was queued when the server sent line: " ~ line);
				auto command = sentCommands.queuePeek();

				int code = line.split()[0].to!int();
				currentReply = code in command.replies;

				// Assume that unknown replies are single-line error messages.
				replyDone = currentReply ? !currentReply.multiLine : true;
				replyLines = [line];
			}
			else
			{
				if (line == ".")
					replyDone = true;
				else
				{
					if (line.length && line[0] == '.')
						line = line[1..$];
					replyLines ~= line;
				}
			}

			if (replyDone)
			{
				auto command = sentCommands.queuePop();
				void handleReply()
				{
					enforce(currentReply, `Unexpected reply "` ~ replyLines[0] ~ `" to command "` ~ command.lines[0] ~ `"`);
					currentReply.handleReply(replyLines);
				}

				if (command.handleError)
					try
						handleReply();
					catch (Exception e)
						command.handleError(e.msg);
				else
					handleReply(); // In the absence of an error handler, treat command handling exceptions like fatal protocol errors

				replyLines = null;
				currentReply = null;

				updateQueue();
			}
		}
		catch (Exception e)
			conn.disconnect("Unhandled " ~ e.classinfo.name ~ ": " ~ e.msg);
	}

	enum PIPELINE_LIMIT = 64;

	void updateQueue()
	{
		if (!sentCommands.length && !queuedCommands.length && handleIdle)
			handleIdle();
		else
		while (
			queuedCommands.length                                                   // Got something to send?
		 && (sentCommands.length == 0 || sentCommands.queuePeekLast().pipelineable) // Can pipeline?
		 && sentCommands.length < PIPELINE_LIMIT)                                   // Not pipelining too much?
			send(queuedCommands.queuePop());
	}

	void queue(Command command)
	{
		queuedCommands.queuePush(command);
		updateQueue();
	}

	void send(Command command)
	{
		foreach (line; command.lines)
			sendLine(line);
		sentCommands.queuePush(command);
	}

public:
	this(Logger log)
	{
		this.log = log;
	}

	void connect(string server, void delegate() handleConnect=null)
	{
		conn = new LineBufferedSocket(30.seconds);
		conn.handleConnect = &onConnect;
		conn.handleDisconnect = &onDisconnect;
		conn.handleReadLine = &onReadLine;

		// Manually place a fake command in the queue
		// (server automatically sends a greeting when a client connects).
		sentCommands ~= Command(null, false, [
			200:Reply({
				if (handleConnect)
					handleConnect();
			}),
		]);

		log("* Connecting to " ~ server ~ "...");
		conn.connect(server, 119);
	}

	void disconnect()
	{
		conn.disconnect();
	}

	void listGroups(void delegate(GroupInfo[] groups) handleGroups, void delegate(string) handleError=null)
	{
		queue(Command(["LIST"], true, [
			215:Reply((string[] reply) {
				GroupInfo[] groups = new GroupInfo[reply.length-1];
				foreach (i, line; reply[1..$])
				{
					auto info = split(line);
					enforce(info.length == 4, "Unrecognized LIST reply");
					groups[i] = GroupInfo(info[0], to!int(info[1]), to!int(info[2]), info[3][0]);
				}
				if (handleGroups)
					handleGroups(groups);
			}),
		], handleError));
	}

	void selectGroup(string name, void delegate() handleSuccess=null, void delegate(string) handleError=null)
	{
		queue(Command(["GROUP " ~ name], true, [
			211:Reply({
				if (handleSuccess)
					handleSuccess();
			}),
		], handleError));
	}

	void listGroup(string name, int from/* = 1*/, void delegate(string[] messages) handleListGroup, void delegate(string) handleError=null)
	{
		string line = from > 1 ? format("LISTGROUP %s %d-", name, from) : format("LISTGROUP %s", name);

		queue(Command([line], true, [
			211:Reply((string[] reply) {
				if (handleListGroup)
					handleListGroup(reply[1..$]);
			}),
		], handleError));
	}

	void listGroup(string name, void delegate(string[] messages) handleListGroup, void delegate(string) handleError=null) { listGroup(name, 1, handleListGroup, handleError); }

	void listGroupXover(string name, int from/* = 1*/, void delegate(string[] messages) handleListGroup, void delegate(string) handleError=null)
	{
		// TODO: handle GROUP command failure
		selectGroup(name);
		queue(Command([format("XOVER %d-", from)], true, [
			224:Reply((string[] reply) {
				auto messages = new string[reply.length-1];
				foreach (i, line; reply[1..$])
					messages[i] = line.split("\t")[0];
				if (handleListGroup)
					handleListGroup(messages);
			}),
		], handleError));
	}

	void listGroupXover(string name, void delegate(string[] messages) handleListGroup, void delegate(string) handleError=null) { listGroupXover(name, 1, handleListGroup, handleError); }

	void getMessage(string numOrID, void delegate(string[] lines, string num, string id) handleMessage, void delegate(string) handleError=null)
	{
		queue(Command(["ARTICLE " ~ numOrID], true, [
			220:Reply((string[] reply) {
				auto message = reply[1..$];
				auto firstLine = reply[0].split();
				if (handleMessage)
					handleMessage(message, firstLine[1], firstLine[2]);
			}),
		], handleError));
	}

	void getDate(void delegate(string date) handleDate, void delegate(string) handleError=null)
	{
		queue(Command(["DATE"], true, [
			111:Reply((string reply) {
				auto date = reply.split()[1];
				enforce(date.length == 14, "Invalid DATE format");
				if (handleDate)
					handleDate(date);
			}),
		], handleError));
	}

	void getNewNews(string wildmat, string dateTime, void delegate(string[] messages) handleNewNews, void delegate(string) handleError=null)
	{
		queue(Command(["NEWNEWS " ~ wildmat ~ " " ~ dateTime], true, [
			230:Reply((string[] reply) {
				if (handleNewNews)
					handleNewNews(reply);
			}),
		], handleError));
	}

	void postMessage(string[] lines, void delegate() handlePosted=null, void delegate(string) handleError=null)
	{
		queue(Command(["POST"], false, [
			340:Reply({
				string[] postLines;
				foreach (line; lines)
					if (line.startsWith("."))
						postLines ~= "." ~ line;
					else
						postLines ~= line;
				postLines ~= ".";

				send(Command(postLines, true, [
					240:Reply({
						if (handlePosted)
							handlePosted();
					}),
				], handleError));
			}),
		], handleError));
	}

	void delegate(string reason, DisconnectType type) handleDisconnect;
	void delegate() handleIdle;
}
