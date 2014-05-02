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
	}
	Config config; /// ditto

	// ******************************* Fields ********************************

	/// The repository.
	/// Call prepare() to initialize.
	Repository repo;

	/// Get a specific subdirectory of the work directory.
	@property string subDir(string name)() { return buildPath(config.workDir, name); }

	/// The git repository location.
	alias subDir!"repo" repoDir;

	/// The Digital Mars C compiler location.
	version(Windows)
	alias subDir!"dm" dmcDir;

	// ******************************* Methods *******************************

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
