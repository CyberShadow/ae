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
class DCustomizer : DManager
{
	alias resultDir = subDir!"result";

	void initialize()
	{
		if (!repoDir.exists)
			log("First run detected.\nPlease be patient, " ~
				"cloning everything might take a few minutes...\n");

		log("Preparing repository...");
		prepareRepo(true);

		log("Preparing component repositories...");
		foreach (component; listComponents().parallel)
		{
			auto crepo = componentRepo(component);

			log(component ~ ": Resetting repository...");
			crepo.run("reset", "--hard");

			log(component ~ ": Cleaning up...");
			crepo.run("clean", "--force", "-x", "-d", "--quiet");

			log(component ~ ": Fetching pull requests...");
			crepo.run("fetch", "origin", "+refs/pull/*/head:refs/remotes/origin/pr/*");

			log(component ~ ": Creating work branch...");
			crepo.run("checkout", "-B", "custom", "origin/master");
		}

		log("Preparing tools...");
		preparePrerequisites();

		clean();

		log("Ready.");
	}

	static const mergeCommitMessage = "ae-custom-pr-%s-merge";

	void merge(string component, string pull)
	{
		enforce(component.match(`^[a-z]+$`), "Bad component");
		enforce(pull.match(`^\d+$`), "Bad pull number");

		auto crepo = componentRepo(component);

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

	void unmerge(string component, string pull)
	{
		enforce(component.match(`^[a-z]+$`), "Bad component");
		enforce(pull.match(`^\d+$`), "Bad pull number");

		auto crepo = componentRepo(component);

		log("Rebasing...");
		environment["GIT_EDITOR"] = "%s do unmerge-rebase-edit %s".format(escapeShellFileName(thisExePath), pull);
		// "sed -i \"s#.*" ~ mergeCommitMessage.format(pull).escapeRE() ~ ".*##g\"";
		crepo.run("rebase", "--interactive", "--preserve-merges", "origin/master");

		log("Unmerge successful.");
	}

	void unmergeRebaseEdit(string pull, string fileName)
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

	void runBuild()
	{
		log("Preparing build...");
		prepareEnv();
		prepareBuilder();

		log("Building...");
		builder.build();

		log("Moving...");
		if (resultDir.exists)
			resultDir.rmdirRecurse();
		rename(buildDir, resultDir);

		log("Build successful.\n\nAdd %s to your PATH to start using it.".format(
			resultDir.buildPath("bin").absolutePath()
		));
	}
}
