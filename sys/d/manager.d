/**
 * Code to manage a D checkout and its dependencies.
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

module ae.sys.d.manager;

import std.algorithm;
import std.array;
import std.file;
import std.parallelism : parallel;
import std.path;
import std.range;
import std.string;

import ae.sys.cmd;
import ae.sys.git;

class DManager
{
	/// URL of D git repository hosting D components.
	/// Defaults to (and must have the layout of) D.git:
	/// https://github.com/CyberShadow/D-dot-git
	enum REPO_URL = "https://bitbucket.org/cybershadow/d.git";

	/// Checkout location.
	string repoDir = "repo";

	this(string repoDir)
	{
		this.repoDir = repoDir;
	}

	/// The repository.
	/// Call prepare() to initialize.
	Repository repo;

	/// Return array of component (submodule) names.
	string[] listComponents()
	{
		return repo
			.query("ls-files")
			.splitLines()
			.filter!(r => r != ".gitmodules")
			.array();
	}

	/// Return the Git repository of the specified component.
	Repository componentRepo(string component)
	{
		return Repository(buildPath(repoDir, component));
	}

	/// Prepare the checkout and initialize the repository.
	/// Clone if necessary, checkout master, optionally update.
	void prepareRepo(bool update)
	{
		if (!repoDir.exists)
		{
			log("Cloning initial repository...");
			scope(failure) log("Check that you have git installed and accessible from PATH.");
			run(["git", "clone", "--recursive", REPO_URL, repoDir]);
			return;
		}

		repo = Repository(repoDir);
		repo.run("bisect", "reset");
		repo.run("checkout", "--force", "master");

		if (update)
		{
			log("Updating repositories...");
			auto allRepos = listComponents()
				.map!(r => buildPath(repoDir, r))
				.chain(repoDir.only)
				.array();
			foreach (r; allRepos.parallel)
				Repository(r).run("-c", "fetch.recurseSubmodules=false", "remote", "update");
		}

		repo.run("reset", "--hard", "origin/master");
	}

protected:
	/// Override to add logging.
	void log(string line)
	{
	}
}
