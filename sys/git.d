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

	string[] argsPrefix;

	this(string path)
	{
		path = path.absolutePath();
		enforce(path.exists, "Repository path does not exist");
		auto dotGit = path.buildPath(".git");
		if (dotGit.isFile)
			dotGit = path.buildPath(dotGit.readText().strip()[8..$]);
		//path = path.replace(`\`, `/`);
		this.path = path;
		this.argsPrefix = [`git`, `--work-tree=` ~ path, `--git-dir=` ~ dotGit];
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
}
