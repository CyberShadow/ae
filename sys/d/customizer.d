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
import ae.utils.regex;

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
		}
	}

	/// Begin customization, starting at the specified revision
	/// (master by default).
	void begin(string rev = null)
	{
		d.checkout(rev);

		foreach (component; d.listComponents())
		{
			auto crepo = d.componentRepo(component);

			log(component ~ ": Creating work branch...");
			crepo.run("checkout", "-B", "custom", "origin/master");
		}
	}

	private enum mergeMessagePrefix = "ae-custom-merge-";
	private enum pullMessageTemplate = mergeMessagePrefix ~ "pr-%s";
	private enum remoteMessageTemplate = mergeMessagePrefix ~ "remote-%s-%s";

	void mergeRef(string component, string refName, string mergeCommitMessage)
	{
		auto crepo = d.componentRepo(component);

		scope(failure)
		{
			log("Aborting merge...");
			crepo.run("merge", "--abort");
		}

		void doMerge()
		{
			crepo.run("merge", "--no-ff", "-m", mergeCommitMessage, refName);
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
				crepo.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage);
			}
		}
		else
			doMerge();

		log("Merge successful.");
	}

	void unmergeRef(string component, string mergeCommitMessage)
	{
		auto crepo = d.componentRepo(component);

		// "sed -i \"s#.*" ~ mergeCommitMessage.escapeRE() ~ ".*##g\"";
		environment["GIT_EDITOR"] = "%s %s %s"
			.format(getCallbackCommand(), unmergeRebaseEditAction, mergeCommitMessage);
		scope(exit) environment.remove("GIT_EDITOR");

		crepo.run("rebase", "--interactive", "--preserve-merges", "origin/master");

		log("Unmerge successful.");
	}

	/// Merge in the specified pull request.
	void mergePull(string component, string pull)
	{
		enforce(component.match(re!`^[a-z]+$`), "Bad component");
		enforce(pull.match(re!`^\d+$`), "Bad pull number");

		log("Merging %s pull request %s...".format(component, pull));

		mergeRef(component, "origin/pr/" ~ pull, pullMessageTemplate.format(pull));
	}

	/// Unmerge the specified pull request.
	/// Requires additional set-up - see callback below.
	void unmergePull(string component, string pull)
	{
		enforce(component.match(re!`^[a-z]+$`), "Bad component");
		enforce(pull.match(re!`^\d+$`), "Bad pull number");

		log("Rebasing to unmerge %s pull request %s...".format(component, pull));

		unmergeRef(component, pullMessageTemplate.format(pull));
	}

	/// Merge in a branch from the given remote.
	void mergeRemoteBranch(string component, string remoteName, string repoUrl, string branch)
	{
		enforce(component.match(re!`^[a-z]+$`), "Bad component");
		enforce(remoteName.match(re!`^\w[\w\-]*$`), "Bad remote name");
		enforce(repoUrl.match(re!`^\w[\w\-]*:[\w/\-\.]+$`), "Bad remote URL");
		enforce(branch.match(re!`^\w[\w\-]*$`), "Bad branch name");

		auto crepo = d.componentRepo(component);
		try
			crepo.run("remote", "rm", remoteName);
		catch (Exception e) {}
		crepo.run("remote", "add", "-f", "--tags", remoteName, repoUrl);

		mergeRef(component,
			"%s/%s".format(remoteName, branch),
			remoteMessageTemplate.format(remoteName, branch));
	}

	/// Undo a mergeRemoteBranch call.
	void unmergeRemoteBranch(string component, string remoteName, string branch)
	{
		enforce(component.match(re!`^[a-z]+$`), "Bad component");
		enforce(remoteName.match(re!`^\w[\w\-]*$`), "Bad remote name");
		enforce(branch.match(re!`^\w[\w\-]*$`), "Bad branch name");

		unmergeRef(component, remoteMessageTemplate.format(remoteName, branch));
	}

	void mergeFork(string user, string repo, string branch)
	{
		mergeRemoteBranch(repo, user, "https://github.com/%s/%s".format(user, repo), branch);
	}

	void unmergeFork(string user, string repo, string branch)
	{
		unmergeRemoteBranch(repo, user, branch);
	}

	/// Override this method with one which returns a command,
	/// which will invoke the unmergeRebaseEdit function below,
	/// passing to it any additional parameters.
	abstract string getCallbackCommand();

	private enum unmergeRebaseEditAction = "unmerge-rebase-edit";

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

	private void unmergeRebaseEdit(string mergeCommitMessage, string fileName)
	{
		auto lines = fileName.readText().splitLines();

		bool removing, remaining;
		foreach_reverse (ref line; lines)
			if (line.startsWith("pick "))
			{
				if (line.match(re!(`^pick [0-9a-f]+ ` ~ escapeRE(mergeMessagePrefix))))
					removing = line.canFind(mergeCommitMessage);
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
