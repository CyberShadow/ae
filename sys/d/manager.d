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
import std.datetime;
import std.exception;
import std.file;
import std.parallelism : parallel;
import std.path;
import std.process;
import std.range;
import std.string;

import ae.sys.cmd;
import ae.sys.d.builder;
import ae.sys.file;
import ae.sys.git;
import ae.sys.install.dmc;
import ae.sys.install.git;

/// Class which manages a D checkout and its dependencies.
class DManager
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
	version(Windows)
	alias dmcDir     = subDir!"dm" ;         /// The Digital Mars C compiler location.
	alias buildDir   = subDir!"build";       /// The build directory.

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

	// **************************** Main methods *****************************

	/// Initialize the repository and prerequisites.
	void initialize(bool update)
	{
		log("Preparing prerequisites...");
		preparePrerequisites();

		log("Preparing repository...");
		prepareRepo(update);
	}

	/// Build D.
	void build()
	{
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
			buildDir.rmdirRecurse();
		enforce(!buildDir.exists);

		repo.run("submodule", "update");
		repo.run("submodule", "foreach", "git", "reset", "--hard");
		repo.run("submodule", "foreach", "git", "clean", "--force", "-x", "-d", "--quiet");
	}

	// ************************** Auxiliary methods **************************

	/// The repository.
	@property Repository repo() { return Repository(repoDir); }

	/// Prepare the build environment (dEnv).
	void prepareEnv()
	{
		if (dEnv)
			return;

		auto oldPaths = environment["PATH"].split(pathSeparator);

		// Build a new environment from scratch, to avoid tainting the build with the current environment.
		string[] newPaths;

		version(Windows)
		{
			import std.utf;
			import win32.winbase;
			import win32.winnt;

			TCHAR buf[1024];
			auto winDir = buf[0..GetWindowsDirectory(buf.ptr, buf.length)].toUTF8();
			auto sysDir = buf[0..GetSystemDirectory (buf.ptr, buf.length)].toUTF8();
			auto tmpDir = buf[0..GetTempPath(buf.length, buf.ptr)].toUTF8()[0..$-1];
			newPaths ~= [sysDir, winDir];
		}
		else
			newPaths = ["/bin", "/usr/bin"];

		// Add the DMD we built
		newPaths ~= buildPath(buildDir, "bin").absolutePath();   // For Phobos/Druntime/Tools

		// Add the DM tools
		version (Windows)
		{
			auto dmc = buildPath(dmcDir, `bin`).absolutePath();
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
		builder.config.local.dmcDir = dmcDir;
		builder.config.local.env = dEnv;
	}

	/// Obtains prerequisites necessary for building D.
	void preparePrerequisites()
	{
		Installer.logger = &log;

		gitInstaller.require();

		version(Windows)
			dmcInstaller.requireLocal(false);
	}

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

	/// Override to add logging.
	void log(string line)
	{
	}

	void logProgress(string s)
	{
		log((" " ~ s ~ " ").center(70, '-'));
	}
}
