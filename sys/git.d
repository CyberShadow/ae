/**
 * Wrappers for the git command-line tools.
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

module ae.sys.git;

import std.conv;
import std.exception;
import std.file;
import std.path;
import std.process;
import std.string;

import ae.sys.cmd;
import ae.sys.file;

struct Repository
{
	string path;

	// TODO: replace this with using the std.process workDir parameter in 2.066
	string[] argsPrefix;

	this(string path)
	{
		path = path.absolutePath();
		enforce(path.exists, "Repository path does not exist");
		auto dotGit = path.buildPath(".git");
		if (dotGit.exists && dotGit.isFile)
			dotGit = path.buildPath(dotGit.readText().strip()[8..$]);
		//path = path.replace(`\`, `/`);
		this.path = path;
		this.argsPrefix = [`git`, `--work-tree=` ~ path, `--git-dir=` ~ dotGit];
	}

	invariant()
	{
		assert(argsPrefix.length, "Not initialized");
	}

	// Have just some primitives here.
	// Higher-level functionality can be added using UFCS.
	void   run  (string[] args...) { auto owd = pushd(workPath(args[0])); return .run  (argsPrefix ~ args); }
	string query(string[] args...) { auto owd = pushd(workPath(args[0])); return .query(argsPrefix ~ args); }
	bool   check(string[] args...) { auto owd = pushd(workPath(args[0])); return spawnProcess(argsPrefix ~ args).wait() == 0; }

	/// Certain git commands (notably, bisect) must
	/// be run in the repository's root directory.
	private string workPath(string cmd)
	{
		switch (cmd)
		{
			case "bisect":
			case "submodule":
				return path;
			default:
				return null;
		}
	}

	History getHistory()
	{
		History history;

		Commit* getCommit(Hash hash)
		{
			auto pcommit = hash in history.commits;
			return pcommit ? *pcommit : (history.commits[hash] = new Commit(history.numCommits++, hash));
		}

		Commit* commit;

		foreach (line; query([`log`, `--all`, `--pretty=raw`]).splitLines())
		{
			if (!line.length)
				continue;

			if (line.startsWith("commit "))
			{
				auto hash = line[7..$].toCommitHash();
				commit = getCommit(hash);
			}
			else
			if (line.startsWith("tree "))
				continue;
			else
			if (line.startsWith("parent "))
			{
				auto hash = line[7..$].toCommitHash();
				auto parent = getCommit(hash);
				commit.parents ~= parent;
				parent.children ~= commit;
			}
			else
			if (line.startsWith("author "))
				commit.author = line[7..$];
			else
			if (line.startsWith("committer "))
			{
				commit.committer = line[10..$];
				commit.time = line.split(" ")[$-2].to!int();
			}
			else
			if (line.startsWith("    "))
				commit.message ~= line[4..$];
			else
				//enforce(false, "Unknown line in git log: " ~ line);
				commit.message[$-1] ~= line;
		}

		foreach (line; query([`show-ref`, `--dereference`]).splitLines())
		{
			auto h = line[0..40].toCommitHash();
			if (h in history.commits)
				history.refs[line[41..$]] = h;
		}

		return history;
	}
}

static struct History
{
	Commit*[Hash] commits;
	uint numCommits = 0;
	Hash[string] refs;
}

alias ubyte[20] Hash;

struct Commit
{
	uint id;
	Hash hash;
	uint time;
	string author, committer;
	string[] message;
	Commit*[] parents, children;
}

Hash toCommitHash(string hash)
{
	enforce(hash.length == 40, "Bad hash length");
	ubyte[20] result;
	foreach (i, ref b; result)
		b = to!ubyte(hash[i*2..i*2+2], 16);
	return result;
}

string toString(ref Hash hash)
{
	return format("%(%02x%)", hash[]);
}

unittest
{
	assert(toCommitHash("0123456789abcdef0123456789ABCDEF01234567") == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67]);
}

/// Tries to match the default destination of `git clone`.
string repositoryNameFromURL(string url)
{
	return url
		.split(":")[$-1]
		.split("/")[$-1]
		.chomp(".git");
}

unittest
{
	assert(repositoryNameFromURL("https://github.com/CyberShadow/ae.git") == "ae");
	assert(repositoryNameFromURL("git@example.com:ae.git") == "ae");
}
