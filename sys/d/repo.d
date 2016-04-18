/**
 * Code to manage a D component repository.
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

module ae.sys.d.repo;

import std.algorithm;
import std.conv : text;
import std.exception;
import std.file;
import std.process : environment;
import std.range;
import std.regex;
import std.string;
import std.path;

import ae.sys.git;
import ae.utils.exception;
import ae.utils.json;
import ae.utils.regex;

/// Base class for a managed repository.
class ManagedRepository
{
	/// Git repository we manage.
	public Repository git;

	/// Should we fetch the latest stuff?
	public bool offline;

	/// Ensure we have a repository.
	public void needRepo()
	{
		assert(git.path, "No repository");
	}

	public @property string name() { needRepo(); return git.path.baseName; }

	// Head

	/// Ensure the repository's HEAD is as indicated.
	public void needHead(string hash)
	{
		needClean();
		if (getHead() == hash)
			return;

		try
			performCheckout(hash);
		catch (Exception e)
		{
			log("Error checking out %s: %s".format(hash, e));

			// Might be a GC-ed merge. Try to recreate the merge
			auto hit = mergeCache.find!(entry => entry.result == hash)();
			enforce(!hit.empty, "Unknown hash %s".format(hash));
			performMerge(hit.front.base, hit.front.branch, hit.front.revert, hit.front.mainline);
			enforce(getHead() == hash, "Unexpected merge result: expected %s, got %s".format(hash, getHead()));
		}
	}

	private string currentHead = null;

	/// Returns the SHA1 of the given named ref.
	public string getRef(string name)
	{
		return git.query("rev-parse", name);
	}

	/// Return the commit the repository HEAD is pointing at.
	/// Cache the result.
	public string getHead()
	{
		if (!currentHead)
			currentHead = getRef("HEAD");

		return currentHead;
	}

	protected void performCheckout(string hash)
	{
		needClean();

		log("Checking out %s commit %s...".format(name, hash));

		if (offline)
			git.run("checkout", hash);
		else
		{
			try
				git.run("checkout", hash);
			catch (Exception e)
			{
				log("Checkout failed, updating and retrying...");
				update();
				git.run("checkout", hash);
			}
		}

		currentHead = hash;
	}

	/// Update the remote.
	public void update()
	{
		if (!offline)
		{
			needRepo();
			log("Updating " ~ name ~ "...");
			git.run("-c", "fetch.recurseSubmodules=false", "remote", "update", "--prune");
			git.run("-c", "fetch.recurseSubmodules=false", "fetch", "--tags");
		}
	}

	// Clean

	bool clean = false;

	/// Ensure the repository's working copy is clean.
	public void needClean()
	{
		if (clean)
			return;
		performCleanup();
		clean = true;
	}

	private void performCleanup()
	{
		log("Cleaning repository %s...".format(name));
		needRepo();
		try
		{
			git.run("reset", "--hard");
			git.run("clean", "--force", "-x", "-d", "--quiet");
		}
		catch (Exception e)
			throw new RepositoryCleanException(e.msg, e);
	}

	// Merge cache

	private static struct MergeInfo
	{
		string base, branch;
		bool revert = false;
		int mainline = 0;
		string result;
	}
	private alias MergeCache = MergeInfo[];
	private MergeCache mergeCacheData;
	private bool haveMergeCache;

	private @property ref MergeCache mergeCache()
	{
		if (!haveMergeCache)
		{
			if (mergeCachePath.exists)
				mergeCacheData = mergeCachePath.readText().jsonParse!MergeCache;
			haveMergeCache = true;
		}

		return mergeCacheData;
	}

	private void saveMergeCache()
	{
		std.file.write(mergeCachePath(), toJson(mergeCache));
	}

	private @property string mergeCachePath()
	{
		needRepo();
		return buildPath(git.gitDir, "ae-sys-d-mergecache.json");
	}

	// Merge

	private void setupGitEnv()
	{
		string[string] mergeEnv;
		foreach (person; ["AUTHOR", "COMMITTER"])
		{
			mergeEnv["GIT_%s_DATE".format(person)] = "Thu, 01 Jan 1970 00:00:00 +0000";
			mergeEnv["GIT_%s_NAME".format(person)] = "ae.sys.d";
			mergeEnv["GIT_%s_EMAIL".format(person)] = "ae.sys.d\x40thecybershadow.net";
		}
		foreach (k, v; mergeEnv)
			environment[k] = v;
		// TODO: restore environment
	}

	/// Returns the hash of the merge between the base and branch commits.
	/// Performs the merge if necessary. Caches the result.
	public string getMerge(string base, string branch)
	{
		return getMergeImpl(base, branch, false, 0);
	}

	/// Returns the resulting hash when reverting the branch from the base commit.
	/// Performs the revert if necessary. Caches the result.
	/// mainline is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	public string getRevert(string base, string branch, int mainline)
	{
		return getMergeImpl(base, branch, true, mainline);
	}

	private string getMergeImpl(string base, string branch, bool revert, int mainline)
	{
		auto hit = mergeCache.find!(entry =>
			entry.base == base &&
			entry.branch == branch &&
			entry.revert == revert &&
			entry.mainline == mainline)();
		if (!hit.empty)
			return hit.front.result;

		performMerge(base, branch, revert, mainline);

		auto head = getHead();
		mergeCache ~= MergeInfo(base, branch, revert, mainline, head);
		saveMergeCache();
		return head;
	}

	private static const string mergeCommitMessage = "ae.sys.d merge";
	private static const string revertCommitMessage = "ae.sys.d revert";

	// Performs a merge or revert.
	private void performMerge(string base, string branch, bool revert, int mainline)
	{
		needHead(base);
		currentHead = null;

		log("%s %s into %s.".format(revert ? "Reverting" : "Merging", branch, base));

		scope (failure)
		{
			if (!revert)
			{
				log("Aborting merge...");
				git.run("merge", "--abort");
			}
			else
			{
				log("Aborting revert...");
				git.run("revert", "--abort");
			}
			clean = false;
		}

		void doMerge()
		{
			setupGitEnv();
			if (!revert)
				git.run("merge", "--no-ff", "-m", mergeCommitMessage, branch);
			else
			{
				string[] args = ["revert", "--no-edit"];
				if (mainline)
					args ~= ["--mainline", text(mainline)];
				args ~= [branch];
				git.run(args);
			}
		}

		if (git.path.baseName() == "dmd")
		{
			try
				doMerge();
			catch (Exception)
			{
				log("Merge failed. Attempting conflict resolution...");
				git.run("checkout", "--theirs", "test");
				git.run("add", "test");
				if (!revert)
					git.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage);
				else
					git.run("revert", "--continue");
			}
		}
		else
			doMerge();

		log("Merge successful.");
	}

	/// Finds and returns the merge parents of the given merge commit.
	/// Queries the git repository if necessary. Caches the result.
	public MergeInfo getMergeInfo(string merge)
	{
		auto hit = mergeCache.find!(entry => entry.result == merge && !entry.revert)();
		if (!hit.empty)
			return hit.front;

		auto parents = git.query(["log", "--pretty=%P", "-n", "1", merge]).split();
		enforce(parents.length > 1, "Not a merge: " ~ merge);
		enforce(parents.length == 2, "Too many parents: " ~ merge);

		auto info = MergeInfo(parents[0], parents[1], false, 0, merge);
		mergeCache ~= info;
		return info;
	}

	/// Follows the string of merges starting from the given
	/// head commit, up till the merge with the given branch.
	/// Then, reapplies all merges in order,
	/// except for that with the given branch.
	public string getUnMerge(string head, string branch)
	{
		// This could be optimized using an interactive rebase

		auto info = getMergeInfo(head);
		if (info.branch == branch)
			return info.base;

		return getMerge(getUnMerge(info.base, branch), info.branch);
	}

	// Branches, forks and customization

	/// Return SHA1 of the given remote ref.
	/// Fetches the remote first, unless offline mode is on.
	string getRemoteRef(string remote, string remoteRef, string localRef)
	{
		needRepo();
		if (!offline)
		{
			log("Fetching from %s (%s -> %s) ...".format(remote, remoteRef, localRef));
			git.run("fetch", remote, "+%s:%s".format(remoteRef, localRef));
		}
		return getRef(localRef);
	}

	private void fetchPull(int pull)
	{
		if (offline)
			return;

		needRepo();

		log("Fetching pull request %d...".format(pull));
		git.run("fetch", "--no-tags", "origin", "+refs/pull/%d/head:refs/pull/origin/%d/head".format(pull, pull));
	}

	/// Return SHA1 of the given pull request #.
	/// Fetches the pull request first, unless offline mode is on.
	string getPull(int pull)
	{
		return getRemoteRef(
			"origin",
			"refs/pull/%d/head".format(pull),
			"refs/digger/pull/%d".format(pull),
		);
	}

	/// Return SHA1 of the given GitHub fork.
	/// Fetches the fork first, unless offline mode is on.
	/// (This is a thin wrapper around getRemoteBranch.)
	string getFork(string user, string branch)
	{
		enforce(user  .match(re!`^\w[\w\-]*$`), "Bad remote name");
		enforce(branch.match(re!`^\w[\w\-\.]*$`), "Bad branch name");

		return getRemoteRef(
			"https://github.com/%s/%s".format(user, name),
			"refs/heads/%s".format(branch),
			"refs/digger/fork/%s/%s".format(user, branch),
		);
	}

	/// Find the child of a commit, and, if the commit was a merge,
	/// the mainline index of said commit for the child.
	void getChild(string commit, out string child, out int mainline)
	{
		auto hit = mergeCache.find!(entry => entry.base == commit && !entry.revert)();
		if (!hit.empty)
		{
			child = hit.front.result;
			mainline = 2;
			return;
		}

		hit = mergeCache.find!(entry => entry.branch == commit && !entry.revert)();
		if (!hit.empty)
		{
			child = hit.front.result;
			mainline = 1;
			return;
		}

		log("Querying history for commit children...");
		auto history = git.getHistory();
		auto commitHash = commit.toCommitHash();
		auto pCommit = commitHash in history.commits;
		enforce(pCommit, "Can't find commit in history");
		auto children = (*pCommit).children;
		enforce(children.length, "Commit has no children");
		enforce(children.length == 1, "Commit has more than one child");
		auto childCommit = children[0];
		child = childCommit.hash.toString();

		if (childCommit.parents.length == 1)
			mainline = 0;
		else
		{
			enforce(childCommit.parents.length == 2, "Can't get mainline of multiple-branch merges");
			if (childCommit.parents[0] is *pCommit)
				mainline = 2;
			else
				mainline = 1;

			mergeCache ~= MergeInfo(
				childCommit.parents[0].hash.toString(),
				childCommit.parents[1].hash.toString(),
				true, mainline, commit);
			saveMergeCache();
		}
	}

	// Misc

	/// Override to add logging.
	protected abstract void log(string line);
}

/// Used to communicate that a "reset --hard" failed.
/// Generally this indicates git repository corruption.
mixin DeclareException!q{RepositoryCleanException};
