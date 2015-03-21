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
import std.conv;
import std.datetime;
import std.exception;
import std.file;
import std.parallelism : parallel;
import std.path;
import std.process;
import std.range;
import std.string;
import std.typecons;

import ae.sys.cmd;
import ae.sys.d.builder;
import ae.sys.file;
import ae.sys.git;
import ae.utils.array;
import ae.utils.json;

version(Windows)
{
	import ae.sys.install.dmc;
	import ae.sys.install.vs;
}

import ae.sys.install.dmd;
import ae.sys.install.git;

/// Base class for a managed repository.
class ManagedRepository
{
	/// Git repository we manage.
	Repository repo;

	/// Should we fetch the latest stuff?
	bool offline;

	/// Ensure we have a repository.
	void needRepo()
	{
		assert(repo.path, "No repository");
	}

	@property string name() { needRepo(); return repo.path.baseName; }

	// Head

	/// Ensure the repository's HEAD is as indicated.
	void needHead(string hash)
	{
		needClean();
		if (getHead() == hash)
			return;

		try
		{
			performCheckout(hash);
			currentHead = hash;
		}
		catch (Exception e)
		{
			log("Error checking out %s: %s".format(hash, e));

			// Might be a GC-ed merge. Try to recreate the merge
			auto hit = mergeCache.find!(entry => entry.result == hash)();
			enforce(!hit.empty, "Unknown hash %s".format(hash));
			performMerge(hit.front.base, hit.front.branch);
			enforce(getHead() == hash, "Unexpected merge result: expected %s, got %s".format(hash, getHead()));
		}
	}

	string currentHead = null;

	/// Return the commit the repository HEAD is pointing at.
	/// Cache the result.
	string getHead()
	{
		if (!currentHead)
			currentHead = repo.query("rev-parse", "HEAD");

		return currentHead;
	}

	void performCheckout(string hash)
	{
		needClean();

		log("Checking out %s...".format(hash));
		repo.run("checkout", hash);
	}

	// Clean

	bool clean = false;

	/// Ensure the repository's working copy is clean.
	void needClean()
	{
		if (clean)
			return;

		needRepo();

		log("Cleaning up...");
		performCleanup();

		clean = true;
	}

	void performCleanup()
	{
		repo.run("reset", "--hard");
		repo.run("clean", "--force", "-x", "-d", "--quiet");
	}

	// Merge cache

	static struct MergeCacheEntry
	{
		string base, branch, result;
	}
	alias MergeCache = MergeCacheEntry[];
	MergeCache mergeCache;

	void needMergeCache()
	{
		if (mergeCache !is null)
			return;

		auto path = mergeCachePath();
		if (path.exists)
			mergeCache = path.readText().jsonParse!(MergeCacheEntry[]);
	}

	void saveMergeCache()
	{
		std.file.write(mergeCachePath(), toJson(mergeCache));
	}

	@property string mergeCachePath()
	{
		needRepo();
		return buildPath(repo.path, ".git",  "ae-sys-d-mergecache.json");
	}

	// Merge

	string needMerge(string base, string branch)
	{
		needMergeCache();

		auto hit = mergeCache.find!(entry => entry.base == base && entry.branch == branch)();
		if (!hit.empty)
			return hit.front.result;

		performMerge(base, branch);

		auto head = getHead();
		mergeCache ~= MergeCacheEntry(base, branch, head);
		saveMergeCache();
		return head;
	}

	void performMerge(string base, string branch, string mergeCommitMessage = "ae.sys.d merge")
	{
		needHead(base);
		currentHead = null;

		log("Merging %s into %s.".format(branch, base));

		scope(failure)
		{
			log("Aborting merge...");
			repo.run("merge", "--abort");
			clean = false;
		}

		void doMerge()
		{
			string[string] mergeEnv;
			foreach (person; ["AUTHOR", "COMMITTER"])
			{
				mergeEnv["GIT_%s_DATE".format(person)] = "Thu, 01 Jan 1970 00:00:00 +0000";
				mergeEnv["GIT_%s_NAME".format(person)] = "ae.sys.d";
				mergeEnv["GIT_%s_EMAIL".format(person)] = "ae.sys.d@thecybershadow.net";
			}
			foreach (k, v; mergeEnv)
				environment[k] = v;
			// TODO: restore environment
			repo.run("merge", "--no-ff", "-m", mergeCommitMessage, branch);
		}

		if (repo.path.baseName() == "dmd")
		{
			try
				doMerge();
			catch (Exception)
			{
				log("Merge failed. Attempting conflict resolution...");
				repo.run("checkout", "--theirs", "test");
				repo.run("add", "test");
				repo.run("-c", "rerere.enabled=false", "commit", "-m", mergeCommitMessage);
			}
		}
		else
			doMerge();

		log("Merge successful.");
	}

	// Misc

	/// Override to add logging.
	void log(string line)
	{
	}

	// Merges

	bool haveLatestPulls;

	void needLatestPulls()
	{
		if (haveLatestPulls || offline)
			return;

		needRepo();

		log("Fetching %s pull requests...".format(name));
		repo.run("fetch", "origin", "+refs/pull/*/head:refs/remotes/origin/pr/*");

		haveLatestPulls = true;
	}

	string[int] pullCache;

	string[int] needPulls()
	{
		if (!pullCache)
			pullCache = readPulls();

		return pullCache;
	}

	string[int] readPulls()
	{
		return repo.query("show-ref")
			.splitLines()
			.filter!(line => line[41..$].startsWith("refs/remotes/origin/pr/"))
			.map!(line => tuple(line[64..$].to!int, line[0..40]))
			.toAA();
	}
}

/// Class which manages a D checkout and its dependencies.
class DManager : ManagedRepository
{
	// **************************** Configuration ****************************

	/// DManager configuration.
	struct Config
	{
		/// URL of D git repository hosting D components.
		/// Defaults to (and must have the layout of) D.git:
		/// https://github.com/CyberShadow/D-dot-git
		string repoUrl = "https://bitbucket.org/cybershadow/d.git";

		/// Location for the checkout, temporary files, etc.
		string workDir;

		/// Build configuration.
		DBuilder.Config.Build build;
	}
	Config config; /// ditto

	// ******************************* Fields ********************************

	/// Get a specific subdirectory of the work directory.
	@property string subDir(string name)() { return buildPath(config.workDir, name); }

	alias repoDir    = subDir!"repo";        /// The git repository location.
	alias buildDir   = subDir!"build";       /// The build directory.
	alias dlDir      = subDir!"dl" ;         /// The directory for downloaded software.

	version(Windows) string dmcDir, vsDir, sdkDir;
	string dmd; /// For DDMD bootstrapping
	string[] paths;

	/// Environment used when building D.
	string[string] dEnv;

	/// Our custom D builder.
	class Builder : DBuilder
	{
		override void log(string s)
		{
			this.outer.log(s);
		}
	}
	Builder builder; /// ditto

	/// Sub-project repository status.
	ManagedRepository[string] repos;

	// **************************** Main methods *****************************

	// ************************** Auxiliary methods **************************

	ManagedRepository needComponentRepo(string name)
	{
		if (name !in repos)
		{
			needRepo();
			repos[name] = new ManagedRepository();
			repos[name].repo = Repository(buildPath(repo.path, name));
		}

		return repos[name];
	}

	string[string] queryComponents()
	{
		string[string] result;
		foreach (line; repo.query("ls-tree", "HEAD").splitLines())
		{
			auto parts = line.split();
			if (parts.length == 4 && parts[1] == "commit")
				result[parts[3]] = parts[2];
		}
		assert(result.length, "No submodules found");
		return result;
	}

	void needInstaller()
	{
		Installer.logger = &log;
		Installer.installationDirectory = dlDir;
	}

	/// Obtains prerequisites necessary for building D with the current configuration.
	void needBuildPrerequisites()
	{
		version(Windows)
		{
			needInstaller();

			if (config.build.model == "64")
			{
				auto vs = vs2013community;
				vs.requirePackages(
					[
						"vcRuntimeMinimum_x86",
						"vc_compilercore86",
						"vc_compilercore86res",
						"vc_compilerx64nat",
						"vc_compilerx64natres",
						"vc_librarycore86",
						"vc_libraryDesktop_x64",
						"win_xpsupport",
					],
				);
				vs.requireLocal(false);
				vsDir  = vs.directory.buildPath("Program Files (x86)", "Microsoft Visual Studio 12.0").absolutePath();
				sdkDir = vs.directory.buildPath("Program Files", "Microsoft SDKs", "Windows", "v7.1A").absolutePath();
				paths ~= vs.directory.buildPath("Windows", "system32").absolutePath();
			}

			// We need DMC even for 64-bit builds (for DM make)
			dmcInstaller.requireLocal(false);
			dmcDir = dmcInstaller.directory;
			log("dmcDir=" ~ dmcDir);
		}
	}

	/// Obtains prerequisites necessary for managing the D repository.
	void needRepoPrerequisites()
	{
		needInstaller();
		gitInstaller.require();
	}

	/// Prepare the build environment (dEnv).
	void prepareEnv()
	{
		if (dEnv)
			return;

		needBuildPrerequisites();

		auto oldPaths = environment["PATH"].split(pathSeparator);

		// Build a new environment from scratch, to avoid tainting the build with the current environment.
		string[] newPaths;

		version(Windows)
		{
			import std.utf;
			import win32.winbase;
			import win32.winnt;

			TCHAR[1024] buf;
			auto winDir = buf[0..GetWindowsDirectory(buf.ptr, buf.length)].toUTF8();
			auto sysDir = buf[0..GetSystemDirectory (buf.ptr, buf.length)].toUTF8();
			auto tmpDir = buf[0..GetTempPath(buf.length, buf.ptr)].toUTF8()[0..$-1];
			newPaths ~= [sysDir, winDir];
		}
		else
			newPaths = ["/bin", "/usr/bin"];

		// Add component paths, if any
		newPaths ~= paths;

		// Add the DMD we built
		newPaths ~= buildPath(buildDir, "bin").absolutePath();   // For Phobos/Druntime/Tools

		if (!dmd)
			prepareBuildPrerequisites();

		// Add the DM tools
		version (Windows)
		{
			auto dmc = buildPath(dmcDir, `bin`).absolutePath();
			log("DMC=" ~ dmc);
			dEnv["DMC"] = dmc;
			newPaths ~= dmc;
		}

		dEnv["PATH"] = newPaths.join(pathSeparator);

		version(Windows)
		{
			dEnv["TEMP"] = dEnv["TMP"] = tmpDir;
			dEnv["SystemRoot"] = winDir;
		}
	}

	/// Create the Builder.
	void prepareBuilder()
	{
		builder = new Builder();
		builder.config.build = config.build;
		builder.config.local.repoDir = repoDir;
		builder.config.local.buildDir = buildDir;
		version(Windows)
		{
			builder.config.local.dmcDir = dmcDir;
			builder.config.local.vsDir  = vsDir ;
			builder.config.local.sdkDir = sdkDir;
		}
		builder.config.local.hostDC = dmd;
		builder.config.local.env = dEnv;
	}

	// ********************* ManagedRepository overrides *********************

	override void performCleanup()
	{
		if (buildDir.exists)
			buildDir.removeRecurse();
		enforce(!buildDir.exists);
	}

	override void performCheckout(string hash)
	{
		super.performCheckout(hash);
		repos = null;
	}

	bool repoUpdated;

	/// Prepare the checkout and initialize the repository.
	/// Clone if necessary, checkout master, optionally update.
	override void needRepo()
	{
		needRepoPrerequisites();

		if (!repoDir.exists)
		{
			log("Cloning initial repository...");
			atomic!performClone(config.repoUrl, repoDir);
			return;
		}

		if (!repo.path)
			repo = Repository(repoDir);

		if (!offline && !repoUpdated)
		{
			log("Updating repositories...");
			auto allRepos = queryComponents()
				.keys
				.map!(r => buildPath(repoDir, r))
				.chain(repoDir.only)
				.array();
			foreach (r; allRepos.parallel)
				Repository(r).run("-c", "fetch.recurseSubmodules=false", "remote", "update");
			repoUpdated = true;
		}

		auto dmdInstaller = new DMD("2.066.1");
		dmdInstaller.requireLocal(false);
		dmd = dmdInstaller.exePath("dmd");
	}

	static void performClone(string url, string target)
	{
		run(["git", "clone", "--recursive", url, target]);
	}

// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################
// ##########################################################################################################################################################

version(none)
{
	// **************************** Main methods *****************************

	/// Initialize the repository and prerequisites.
	void initialize(bool update)
	{
		log("Preparing prerequisites...");
		prepareRepoPrerequisites();

		log("Preparing repository...");
		prepareRepo(update);
	}

	void incrementalBuild()
	{
		prepareEnv();
		prepareBuilder();
		builder.build();
	}

	/// Build D.
	void build()
	{
		log("Preparing build prerequisites...");
		prepareBuildPrerequisites();

		log("Preparing to build...");
		prepareEnv();
		prepareBuilder();

		log("Building...");
		mkdir(buildDir);
		builder.build();
	}

	/// Go to a specific revision.
	/// Assumes a clean state (call reset first).
	void checkout(string rev)
	{
		if (!rev)
			rev = "origin/master";

		log("Checking out %s...".format(rev));
		repo.run("checkout", rev);

		log("Updating submodules...");
		repo.run("submodule", "update");
	}

	struct LogEntry
	{
		string message, hash;
		SysTime time;
	}

	/// Gets the D merge log (newest first).
	LogEntry[] getLog()
	{
		auto history = repo.getHistory();
		LogEntry[] logs;
		auto master = history.commits[history.refs["refs/remotes/origin/master"]];
		for (auto c = master; c; c = c.parents.length ? c.parents[0] : null)
		{
			auto title = c.message.length ? c.message[0] : null;
			auto time = SysTime(c.time.unixTimeToStdTime);
			logs ~= LogEntry(title, c.hash.toString(), time);
		}
		return logs;
	}

	/// Clean up (delete all built and intermediary files).
	void reset()
	{
		log("Cleaning up...");

		if (buildDir.exists)
			buildDir.removeRecurse();
		enforce(!buildDir.exists);

		repo.run("submodule", "foreach", "git", "reset", "--hard");
		repo.run("submodule", "foreach", "git", "clean", "--force", "-x", "-d", "--quiet");
		repo.run("submodule", "update");
	}

	// ************************** Auxiliary methods **************************

	/// The repository.
	@property Repository repo() { return Repository(repoDir); }

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
			run(["git", "clone", "--recursive", config.repoUrl, repoDir]);
			return;
		}

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

	void logProgress(string s)
	{
		log((" " ~ s ~ " ").center(70, '-'));
	}
}
}

// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################

version(none)
{
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
	void initialize(bool update = true)
	{
		d.initialize(update);

		log("Preparing component repositories...");
		foreach (component; d.listComponents().parallel)
		{
			auto crepo = d.componentRepo(component);

			if (update)
			{
				log(component ~ ": Fetching pull requests...");
				crepo.run("fetch", "origin", "+refs/pull/*/head:refs/remotes/origin/pr/*");
			}
		}
	}

	/// Begin customization, starting at the specified revision
	/// (master by default).
	void begin(string rev = null)
	{
		d.reset();
		d.checkout(rev);

		foreach (component; d.listComponents())
		{
			auto crepo = d.componentRepo(component);

			log(component ~ ": Creating work branch...");
			crepo.run("checkout", "-B", "custom");
		}
	}

	private enum mergeMessagePrefix = "ae-custom-merge-";
	private enum pullMessageTemplate = mergeMessagePrefix ~ "pr-%s";
	private enum remoteMessageTemplate = mergeMessagePrefix ~ "remote-%s-%s";

	void setupGitEnv()
	{
		string[string] mergeEnv;
		foreach (person; ["AUTHOR", "COMMITTER"])
		{
			mergeEnv["GIT_%s_DATE".format(person)] = "Thu, 01 Jan 1970 00:00:00 +0000";
			mergeEnv["GIT_%s_NAME".format(person)] = "ae.sys.d.customizer";
			mergeEnv["GIT_%s_EMAIL".format(person)] = "ae.sys.d.customizer@thecybershadow.net";
		}
		foreach (k, v; mergeEnv)
			environment[k] = v;
		// TODO: restore environment
	}

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
			setupGitEnv();
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
		setupGitEnv();
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
		enforce(branch.match(re!`^\w[\w\-\.]*$`), "Bad branch name");

		auto crepo = d.componentRepo(component);

		void rm()
		{
			try
				crepo.run("remote", "rm", remoteName);
			catch (Exception e) {}
		}
		rm();
		scope(exit) rm();
		crepo.run("remote", "add", "-f", remoteName, repoUrl);

		mergeRef(component,
			"%s/%s".format(remoteName, branch),
			remoteMessageTemplate.format(remoteName, branch));
	}

	/// Undo a mergeRemoteBranch call.
	void unmergeRemoteBranch(string component, string remoteName, string branch)
	{
		enforce(component.match(re!`^[a-z]+$`), "Bad component");
		enforce(remoteName.match(re!`^\w[\w\-]*$`), "Bad remote name");
		enforce(branch.match(re!`^\w[\w\-\.]*$`), "Bad branch name");

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
}
