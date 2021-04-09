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
 *   Vladimir Panteleev <ae@cy.md>
 */

module ae.sys.d.repo;

import std.algorithm;
import std.conv : text;
import std.datetime : SysTime;
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
import ae.utils.time : StdTime;

/// Base class for a managed repository.
class ManagedRepository
{
	/// Git repository we manage.
	public @property ref const(Git) git()
	{
		if (!gitRepo.path)
		{
			gitRepo = getRepo();
			assert(gitRepo.path, "No repository");
			foreach (person; ["AUTHOR", "COMMITTER"])
			{
				gitRepo.environment["GIT_%s_DATE".format(person)] = "Thu, 01 Jan 1970 00:00:00 +0000";
				gitRepo.environment["GIT_%s_NAME".format(person)] = "ae.sys.d";
				gitRepo.environment["GIT_%s_EMAIL".format(person)] = "ae.sys.d\x40thecybershadow.net";
			}
		}
		return gitRepo;
	}

	/// Should we fetch the latest stuff?
	public bool offline;

	/// Verify working tree state to make sure we don't clobber user changes?
	public bool verify;

	private Git gitRepo;

	/// Repository provider
	abstract protected Git getRepo();

	/// Base name of the repository directory
	public @property string name() { return git.path.baseName; }

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
			performMerge(hit.front.spec);
			enforce(getHead() == hash, "Unexpected merge result: expected %s, got %s".format(hash, getHead()));
		}
	}

	private string currentHead = null;

	/// Returns the SHA1 of the given named ref.
	public string getRef(string name)
	{
		return git.query("rev-parse", "--verify", "--quiet", name);
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
		needCommit(hash);

		log("Checking out %s commit %s...".format(name, hash));

		git.run("checkout", hash);

		saveState();
		currentHead = hash;
	}

	/// Ensure that the specified commit is fetched.
	protected void needCommit(string hash)
	{
		void check()
		{
			enforce(git.query(["cat-file", "-t", hash]) == "commit",
				"Unexpected object type");
		}

		try
			check();
		catch (Exception e)
		{
			if (offline)
			{
				log("Don't have commit " ~ hash ~ " and in offline mode, can't proceed.");
				throw new Exception("Giving up");
			}
			else
			{
				log("Don't have commit " ~ hash ~ ", updating and retrying...");
				update();
				check();
			}
		}
	}

	/// Update the remote.
	/// Return true if any updates were fetched.
	public bool update()
	{
		if (!offline)
		{
			log("Updating " ~ name ~ "...");
			auto oldRefs = git.query(["show-ref"]);
			git.run("-c", "fetch.recurseSubmodules=false", "remote", "update", "--prune");
			git.run("-c", "fetch.recurseSubmodules=false", "fetch", "--force", "--tags");
			auto newRefs = git.query(["show-ref"]);
			return oldRefs != newRefs;
		}
		else
			return false;
	}

	// Clean

	bool clean = false; /// True when we know that the repository is currently clean.

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
		checkState();
		clearState();

		log("Cleaning repository %s...".format(name));
		try
		{
			git.run("reset", "--hard");
			git.run("clean", "--force", "--force" /*Sic*/, "-x", "-d", "--quiet");
		}
		catch (Exception e)
			throw new RepositoryCleanException(e.msg, e);
		saveState();
	}

	// Merge cache

	/// How to merge a branch into another
	enum MergeMode
	{
		merge,      /// git merge (commit with multiple parents) of the target and branch tips
		cherryPick, /// apply the commits as a patch
	}
	private static struct MergeSpec
	{
		string target;
		string[2] branch; // [base, tip]
		MergeMode mode;
		bool revert = false;
	}
	private static struct MergeInfo
	{
		MergeSpec spec;
		string result;
		int mainline = 0; // git parent index of the "target", if any
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
		return buildPath(git.gitDir, "ae-sys-d-mergecache-v2.json");
	}

	// Merge

	/// Returns the hash of the merge between the target and branch commits.
	/// Performs the merge if necessary. Caches the result.
	public string getMerge(string target, string[2] branch, MergeMode mode)
	{
		return getMergeImpl(MergeSpec(target, branch, mode, false));
	}

	/// Returns the resulting hash when reverting the branch from the base commit.
	/// Performs the revert if necessary. Caches the result.
	/// mainline is the 1-based mainline index (as per `man git-revert`),
	/// or 0 if commit is not a merge commit.
	public string getRevert(string target, string[2] branch, MergeMode mode)
	{
		return getMergeImpl(MergeSpec(target, branch, mode, true));
	}

	private string getMergeImpl(MergeSpec spec)
	{
		auto hit = mergeCache.find!(entry => entry.spec == spec)();
		if (!hit.empty)
			return hit.front.result;

		performMerge(spec);

		auto head = getHead();
		mergeCache ~= MergeInfo(spec, head);
		saveMergeCache();
		return head;
	}

	private static const string mergeCommitMessage = "ae.sys.d merge";
	private static const string revertCommitMessage = "ae.sys.d revert";

	// Performs a merge or revert.
	private void performMerge(MergeSpec spec)
	{
		needHead(spec.target);
		currentHead = null;

		log("%s %s into %s.".format(spec.revert ? "Reverting" : "Merging", spec.branch, spec.target));

		scope(exit) saveState();

		scope (failure)
		{
			string op;
			final switch (spec.mode)
			{
				case MergeMode.merge:
					op = spec.revert ? "revert" : "merge";
					break;
				case MergeMode.cherryPick:
					op = spec.revert ? "revert" : "cherry-pick";
					break;
			}

			log("Aborting " ~ op ~ "...");
			git.run(op, "--abort");
			clean = false;
		}

		void doMerge()
		{
			final switch (spec.mode)
			{
				case MergeMode.merge:
					if (!spec.revert)
						git.run("merge", "--no-ff", "-m", mergeCommitMessage, spec.branch[1]);
					else
					{
						// When reverting in merge mode, we try to
						// find the merge commit following the branch
						// tip, and revert only that merge commit.
						string mergeCommit; int mainline;
						getChild(spec.target, spec.branch[1], /*out*/mergeCommit, /*out*/mainline);

						string[] args = ["revert", "--no-edit"];
						if (mainline)
							args ~= ["--mainline", text(mainline)];
						args ~= [mergeCommit];
						git.run(args);
					}
					break;
				case MergeMode.cherryPick:
					enforce(spec.branch[0], "Must specify a branch base for a cherry-pick merge");
					auto range = spec.branch[0] ~ ".." ~ spec.branch[1];
					if (!spec.revert)
						git.run("cherry-pick", range);
					else
						git.run("revert", "--no-edit", range);
					break;
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
				if (!spec.revert)
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
		auto hit = mergeCache.find!(entry => entry.result == merge && !entry.spec.revert)();
		if (!hit.empty)
			return hit.front;

		auto parents = git.query(["log", "--pretty=%P", "-n", "1", merge]).split();
		enforce(parents.length > 1, "Not a merge: " ~ merge);
		enforce(parents.length == 2, "Too many parents: " ~ merge);

		auto info = MergeInfo(MergeSpec(parents[0], [null, parents[1]], MergeMode.merge, false), merge, 1);
		mergeCache ~= info;
		return info;
	}

	/// Follows the string of merges starting from the given
	/// head commit, up till the merge with the given branch.
	/// Then, reapplies all merges in order,
	/// except for that with the given branch.
	public string getUnMerge(string head, string[2] branch, MergeMode mode)
	{
		// This could be optimized using an interactive rebase

		auto info = getMergeInfo(head);
		if (info.spec.branch[1] == branch[1])
			return info.spec.target;

		// Recurse to keep looking
		auto unmerge = getUnMerge(info.spec.target, branch, mode);
		// Re-apply this non-matching merge
		return getMerge(unmerge, info.spec.branch, info.spec.mode);
	}

	// Branches, forks and customization

	/// Return SHA1 of the given remote ref.
	/// Fetches the remote first, unless offline mode is on.
	string getRemoteRef(string remote, string remoteRef, string localRef)
	{
		if (!offline)
		{
			log("Fetching from %s (%s -> %s) ...".format(remote, remoteRef, localRef));
			git.run("fetch", remote, "+%s:%s".format(remoteRef, localRef));
		}
		return getRef(localRef);
	}

	/// Return SHA1 of the given pull request #.
	/// Fetches the pull request first, unless offline mode is on.
	string getPullTip(int pull)
	{
		return getRemoteRef(
			"origin",
			"refs/pull/%d/head".format(pull),
			"refs/digger/pull/%d".format(pull),
		);
	}

	private static bool isCommitHash(string s)
	{
		return s.length == 40 && s.representation.all!(c => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
	}

	/// Return SHA1 (base, tip) of the given branch (possibly of GitHub fork).
	/// Fetches the fork first, unless offline mode is on.
	/// (This is a thin wrapper around getRemoteRef.)
	string[2] getBranch(string user, string base, string tip)
	{
		if (user) enforce(user.match(re!`^\w[\w\-]*$`), "Bad remote name");
		if (base) enforce(base.match(re!`^\w[\w\-\.]*$`), "Bad branch base name");
		if (true) enforce(tip .match(re!`^\w[\w\-\.]*$`), "Bad branch tip name");

		if (!user)
			user = "dlang";

		if (isCommitHash(tip))
		{
			if (!offline)
			{
				// We don't know which branch the commit will be in, so just grab everything.
				auto remote = "https://github.com/%s/%s".format(user, name);
				log("Fetching everything from %s ...".format(remote));
				git.run("fetch", remote, "+refs/heads/*:refs/forks/%s/*".format(user));
			}
			if (!base)
				base = git.query("rev-parse", tip ~ "^");
			return [
				base,
				tip,
			];
		}
		else
		{
			return [
				null,
				getRemoteRef(
					"https://github.com/%s/%s".format(user, name),
					"refs/heads/%s".format(tip),
					"refs/digger/fork/%s/%s".format(user, tip),
				),
			];
		}
	}

	/// Find the child of a commit, and, if the commit was a merge,
	/// the mainline index of said commit for the child.
	void getChild(string branch, string commit, out string child, out int mainline)
	{
		needCommit(branch);

		log("Querying history for commit children...");
		auto history = git.getHistory([branch]);

		bool[Git.CommitID] seen;
		void visit(Git.History.Commit* commit)
		{
			if (commit.oid !in seen)
			{
				seen[commit.oid] = true;
				foreach (parent; commit.parents)
					visit(parent);
			}
		}
		auto branchHash = Git.CommitID(branch);
		auto pBranchCommit = branchHash in history.commits;
		enforce(pBranchCommit, "Can't find commit " ~ branch ~" in history");
		visit(*pBranchCommit);

		auto commitHash = Git.CommitID(commit);
		auto pCommit = commitHash in history.commits;
		enforce(pCommit, "Can't find commit in history");
		auto children = (*pCommit).children;
		enforce(children.length, "Commit has no children");
		children = children.filter!(child => child.oid in seen).array();
		enforce(children.length, "Commit has no children under specified branch");
		enforce(children.length == 1, "Commit has more than one child");
		auto childCommit = children[0];
		child = childCommit.oid.toString();

		if (childCommit.parents.length == 1)
			mainline = 0;
		else
		{
			enforce(childCommit.parents.length == 2, "Can't get mainline of multiple-branch merges");
			if (childCommit.parents[0] is *pCommit)
				mainline = 2;
			else
				mainline = 1;

			auto mergeInfo = MergeInfo(
				MergeSpec(
					childCommit.parents[0].oid.toString(),
					childCommit.parents[1].oid.toString(),
					MergeMode.merge,
					true),
				commit, mainline);
			if (!mergeCache.canFind(mergeInfo))
			{
				mergeCache ~= mergeInfo;
				saveMergeCache();
			}
		}
	}

	// State saving and checking

	struct FileState
	{
		bool isLink;
		ulong size;
		StdTime modificationTime;
	}

	FileState getFileState(string file)
	{
		assert(verify);
		auto path = git.path.buildPath(file);
		auto de = DirEntry(path);
		return FileState(de.isSymlink, de.size, de.timeLastModified.stdTime);
	}

	alias RepositoryState = FileState[string];

	/// Return the working tree "state".
	/// This returns a file list, along with size and modification time.
	RepositoryState getState()
	{
		assert(verify);
		auto files = git.query(["ls-files"]).splitLines();
		RepositoryState state;
		foreach (file; files)
			try
				state[file] = getFileState(file);
			catch (Exception e) {}
		return state;
	}

	private @property string workTreeStatePath()
	{
		assert(verify);
		return buildPath(git.gitDir, "ae-sys-d-worktree.json");
	}

	/// Save the state of the working tree for versioned files
	/// to a .json file, which can later be verified with checkState.
	/// This should be called after any git command which mutates the git state.
	void saveState()
	{
		if (!verify)
			return;
		std.file.write(workTreeStatePath, getState().toJson());
	}

	/// Save the state of just one file.
	/// This should be called after automatic edits to repository files during a build.
	/// The file parameter should be relative to the directory root, and use forward slashes.
	void saveFileState(string file)
	{
		if (!verify)
			return;
		if (!workTreeStatePath.exists)
			return;
		auto state = workTreeStatePath.readText.jsonParse!RepositoryState();
		state[file] = getFileState(file);
		std.file.write(workTreeStatePath, state.toJson());
	}

	/// Verify that the state of the working tree matches the one
	/// when saveState was last called. Throw an exception otherwise.
	/// This and clearState should be called before any git command
	/// which destroys working directory changes.
	void checkState()
	{
		if (!verify)
			return;
		if (!workTreeStatePath.exists)
			return;
		auto savedState = workTreeStatePath.readText.jsonParse!RepositoryState();
		auto currentState = getState();
		try
		{
			foreach (file, fileState; currentState)
			{
				enforce(file in savedState, "New file: " ~ file);
				enforce(savedState[file].isLink == fileState.isLink,
					"File modified: %s (is link changed, before: %s, after: %s)".format(file, savedState[file].isLink, fileState.isLink));
				if (fileState.isLink)
					continue; // Correct lstat is too hard, just skip symlinks
				enforce(savedState[file].size == fileState.size,
					"File modified: %s (size changed, before: %s, after: %s)".format(file, savedState[file].size, fileState.size));
				enforce(savedState[file].modificationTime == fileState.modificationTime,
					"File modified: %s (modification time changed, before: %s, after: %s)".format(file, SysTime(savedState[file].modificationTime), SysTime(fileState.modificationTime)));
				assert(savedState[file] == fileState);
			}
		}
		catch (Exception e)
			throw new Exception(
				"The worktree has changed since the last time this software updated it.\n" ~
				"Specifically:\n" ~
				"    " ~ e.msg ~ "\n\n" ~
				"Aborting to avoid overwriting your changes.\n" ~
				"To continue:\n" ~
				" 1. Commit / stash / back up your changes, if you wish to keep them\n" ~
				" 2. Delete " ~ workTreeStatePath ~ "\n" ~
				" 3. Try this operation again."
			);
	}

	/// Delete the saved working tree state, if any.
	void clearState()
	{
		if (!verify)
			return;
		if (workTreeStatePath.exists)
			workTreeStatePath.remove();
	}

	// Misc

	/// Reset internal state.
	protected void reset()
	{
		currentHead = null;
		clean = false;
		haveMergeCache = false;
		mergeCacheData = null;
	}

	/// Override to add logging.
	protected abstract void log(string line);
}

/// Used to communicate that a "reset --hard" failed.
/// Generally this indicates git repository corruption.
mixin DeclareException!q{RepositoryCleanException};
