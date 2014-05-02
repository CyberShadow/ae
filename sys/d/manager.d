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
import std.exception;
import std.file;
import std.parallelism : parallel;
import std.path;
import std.process;
import std.range;
import std.string;

import ae.sys.cmd;
import ae.sys.file;
import ae.sys.git;

// http://d.puremagic.com/issues/show_bug.cgi?id=7016
static import ae.net.http.client;

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

		/// Additional environment strings used when building D.
		/// Can refer to existing environment variables using %NAME% syntax.
		/// Examples:
		/// ---
		/// // Add something to PATH
		/// config.environment["PATH"] = `%PATH%;C:\Tools`;
		///
		/// // Import PATHEXT from the original environment
		/// config.environment["PATHEXT"] = "%PATHEXT%";
		/// ---
		string[string] environment;
	}
	Config config; /// ditto

	// ******************************* Fields ********************************

	/// The repository.
	/// Call prepare() to initialize.
	Repository repo;

	/// Get a specific subdirectory of the work directory.
	@property string subDir(string name)() { return buildPath(config.workDir, name); }

	alias repoDir    = subDir!"repo";        /// The git repository location.
	version(Windows)
	alias dmcDir     = subDir!"dm" ;         /// The Digital Mars C compiler location.
	alias buildDir   = subDir!"build";       /// The build directory.

	/// Environment used when building D.
	string[string] dEnv;

	// ******************************* Methods *******************************

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

		applyEnv(config.environment);
	}

	/// Apply user-specified environment settings over the calculated environment.
	void applyEnv(in string[string] env)
	{
		auto oldEnv = environment.toAA();
		foreach (name, value; dEnv)
			oldEnv[name] = value;
		foreach (name, value; env)
		{
			string newValue = value;
			foreach (oldName, oldValue; oldEnv)
				newValue = newValue.replace("%" ~ oldName ~ "%", oldValue);
			dEnv[name] = oldEnv[name] = newValue;
		}
	}

	/// Obtains prerequisites necessary for building D.
	void preparePrerequisites()
	{
		version(Windows)
		{
			void prepareDMC(string dmc)
			{
				auto workDir = config.workDir;

				void downloadFile(string url, string target)
				{
					log("Downloading " ~ url);

					import std.stdio : File;
					import ae.net.http.client;
					import ae.net.asockets;
					import ae.sys.data;

					httpGet(url,
						(Data data) { std.file.write(target, data.contents); },
						(string error) { throw new Exception(error); }
					);

					socketManager.loop();
				}

				alias obtainUsing!downloadFile cachedDownload;
				cachedDownload("http://ftp.digitalmars.com/dmc.zip", buildPath(workDir, "dmc.zip"));
				cachedDownload("http://ftp.digitalmars.com/optlink.zip", buildPath(workDir, "optlink.zip"));

				void unzip(string zip, string target)
				{
					log("Unzipping " ~ zip);
					import std.zip;
					auto archive = new ZipArchive(zip.read);
					foreach (name, entry; archive.directory)
					{
						auto path = buildPath(target, name);
						ensurePathExists(path);
						if (name.endsWith(`/`))
							path.mkdirRecurse();
						else
							std.file.write(path, archive.expand(entry));
					}
				}

				alias safeUpdate!unzip safeUnzip;

				safeUnzip(buildPath(workDir, "dmc.zip"), buildPath(workDir, "dmc"));
				enforce(buildPath(workDir, "dmc", "dm", "bin", "dmc.exe").exists);
				rename(buildPath(workDir, "dmc", "dm"), dmc);
				rmdir(buildPath(workDir, "dmc"));
				remove(buildPath(workDir, "dmc.zip"));

				safeUnzip(buildPath(workDir, "optlink.zip"), buildPath(workDir, "optlink"));
				rename(buildPath(workDir, "optlink", "link.exe"), buildPath(dmc, "bin", "link.exe"));
				rmdir(buildPath(workDir, "optlink"));
				remove(buildPath(workDir, "optlink.zip"));
			}

			obtainUsing!(prepareDMC, q{dmc})(dmcDir);
		}
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
