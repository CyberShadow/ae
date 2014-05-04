/**
 * Code to manage a customized D checkout.
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

module ae.sys.d.customizer;

import std.algorithm;
import std.exception;
import std.file;
import std.path;
import std.process : environment, escapeShellFileName;
import std.regex;
import std.string;

import ae.sys.d.manager;

/// Class which manages a customized D checkout and its dependencies.
class DCustomizer
{
	DManager d;

	this(DManager manager) { this.d = manager; }

	/// Initialize the repository and prerequisites.
	void initialize()
	{
		d.initialize(true);
		d.reset();

		log("Preparing component repositories...");
		foreach (component; d.listComponents().parallel)
		{
			auto crepo = d.componentRepo(component);

			log(component ~ ": Fetching pull requests...");
			crepo.run("fetch", "origin", "+refs/pull/*/head:refs/remotes/origin/pr/*");

			log(component ~ ": Creating work branch...");
			crepo.run("checkout", "-B", "custom", "origin/master");
		}
	}

	private static const mergeCommitMessage = "ae-custom-pr-%s-merge";

	/// Merge in the specified pull request.
	void merge(string component, string pull)
	{
		enforce(component.match(`^[a-z]+$`), "Bad component");
		enforce(pull.match(`^\d+$`), "Bad pull number");

		auto crepo = d.componentRepo(component);

		scope(failure)
		{
			log("Aborting merge...");
			crepo.run("merge", "--abort");
		}

		log("Merging...");

		void doMerge()
		{
			crepo.run("merge", "--no-ff", "-m", mergeCommitMessage.format(pull), "origin/pr/" ~ pull);
		}

		if (component == "dmd")
		{
			try
				doMerge();
			catch (Exception)
			{
				log("Merge failed. Attempting conflict resolution...");
				crepo.run("checkout", "--theirs", "test");
				crepo.run("add", "test");
				crepo.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage.format(pull));
			}
		}
		else
			doMerge();

		log("Merge successful.");
	}

	/// Unmerge the specified pull request.
	/// Requires additional set-up - see callback below.
	void unmerge(string component, string pull)
	{
		enforce(component.match(`^[a-z]+$`), "Bad component");
		enforce(pull.match(`^\d+$`), "Bad pull number");

		auto crepo = d.componentRepo(component);

		log("Rebasing...");
		environment["GIT_EDITOR"] = "%s %s %s".format(getCallbackCommand(), unmergeRebaseEditAction, pull);
		// "sed -i \"s#.*" ~ mergeCommitMessage.format(pull).escapeRE() ~ ".*##g\"";
		crepo.run("rebase", "--interactive", "--preserve-merges", "origin/master");

		log("Unmerge successful.");
	}

	/// Override this method with one which return a command,
	/// which will invoke the unmergeRebaseEdit function below,
	/// passing to it any additional parameters.
	abstract string getCallbackCommand();

	/// This function must be invoked when the command line
	/// returned by getUnmergeEditorCommand() is ran.
	void callback(string[] args)
	{
		enforce(args.length, "No callback parameters");
		switch (args[0])
		{
			case unmergeRebaseEditAction:
				enforce(args.length == 3, "Invalid argument count");
				unmergeRebaseEdit(args[1], args[2]);
				break;
			default:
				throw new Exception("Unknown callback");
		}
	}

	private enum unmergeRebaseEditAction = "unmerge-rebase-edit";

	private void unmergeRebaseEdit(string pull, string fileName)
	{
		auto lines = fileName.readText().splitLines();

		bool removing, remaining;
		foreach_reverse (ref line; lines)
			if (line.startsWith("pick "))
			{
				if (line.match(`^pick [0-9a-f]+ ` ~ mergeCommitMessage.format(`\d+`) ~ `$`))
					removing = line.canFind(mergeCommitMessage.format(pull));
				if (removing)
					line = "# " ~ line;
				else
					remaining = true;
			}
		if (!remaining)
			lines = ["noop"];

		std.file.write(fileName, lines.join("\n"));
	}

	void log(string s)
	{
		d.log(s);
	}
}
